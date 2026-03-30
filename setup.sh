#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------------------------------
# setup.sh — Automated setup for OpenClaw in a Docker Sandbox with a local LLM
# --------------------------------------------------------------------------

# Defaults
LM_URL="http://localhost:1234/v1"
MODEL_ID="zai-org/glm-4.7-flash"
NODE_VERSION="24"
TEMPLATE=""
SKIP_VERIFY=false
INSTALL_DAEMON=false
NAME=""
WORKSPACE=""

# Colors (disabled if not a terminal)
if [ -t 1 ]; then
  BOLD="\033[1m"
  GREEN="\033[0;32m"
  RED="\033[0;31m"
  YELLOW="\033[0;33m"
  CYAN="\033[0;36m"
  RESET="\033[0m"
else
  BOLD="" GREEN="" RED="" YELLOW="" CYAN="" RESET=""
fi

info()  { printf "${CYAN}${BOLD}[INFO]${RESET}  %s\n" "$*"; }
ok()    { printf "${GREEN}${BOLD}[OK]${RESET}    %s\n" "$*"; }
warn()  { printf "${YELLOW}${BOLD}[WARN]${RESET}  %s\n" "$*"; }
fail()  { printf "${RED}${BOLD}[FAIL]${RESET}  %s\n" "$*" >&2; exit 1; }
step()  { printf "\n${BOLD}── Step %s ──${RESET}\n" "$*"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") --name <sandbox-name> --workspace <path> [options]

Required:
  --name <name>           Sandbox name (e.g. openclaw-local)
  --workspace <path>      Host directory to mount as the sandbox workspace

Options:
  --lm-url <url>          LM Studio API base URL    (default: $LM_URL)
  --model <id>            Model ID                   (default: $MODEL_ID)
  --node-version <ver>    Node.js version to install (default: $NODE_VERSION)
  --template <name>       Save sandbox as a reusable template after setup
  --install-daemon        Install the OpenClaw gateway as a background service
  --skip-verify           Skip connectivity and smoke tests
  -h, --help              Show this help message

Example:
  $(basename "$0") --name openclaw-local --workspace ~/Temp/docker-sandbox-openclaw
EOF
  exit 0
}

# --------------------------------------------------------------------------
# Parse arguments
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)         NAME="$2"; shift 2 ;;
    --workspace)    WORKSPACE="$2"; shift 2 ;;
    --lm-url)       LM_URL="$2"; shift 2 ;;
    --model)        MODEL_ID="$2"; shift 2 ;;
    --node-version) NODE_VERSION="$2"; shift 2 ;;
    --template)     TEMPLATE="$2"; shift 2 ;;
    --install-daemon) INSTALL_DAEMON=true; shift ;;
    --skip-verify)  SKIP_VERIFY=true; shift ;;
    -h|--help)      usage ;;
    *) fail "Unknown option: $1 (use --help for usage)" ;;
  esac
done

[[ -z "$NAME" ]]      && fail "Missing required parameter: --name (use --help for usage)"
[[ -z "$WORKSPACE" ]] && fail "Missing required parameter: --workspace (use --help for usage)"

# Expand ~ in workspace path
WORKSPACE="${WORKSPACE/#\~/$HOME}"

# --------------------------------------------------------------------------
# Step 0 — Preflight checks
# --------------------------------------------------------------------------
step "0: Preflight checks"

command -v docker >/dev/null 2>&1 || fail "docker CLI not found. Install Docker Desktop first."
docker sandbox ls >/dev/null 2>&1 || fail "'docker sandbox' not available. Enable Sandbox CLI in Docker Desktop (nightly/beta)."
ok "Docker + Sandbox CLI available"

info "Checking LM Studio at ${LM_URL}/models ..."
if ! curl --silent --fail --max-time 5 "${LM_URL}/models" >/dev/null 2>&1; then
  fail "Cannot reach LM Studio at ${LM_URL}/models. Is LM Studio running with the server started?"
fi
ok "LM Studio reachable"

# Verify the model is loaded
if ! curl --silent --fail "${LM_URL}/models" | grep -q "$MODEL_ID"; then
  warn "Model '$MODEL_ID' not found in LM Studio response."
  info "Available models:"
  curl --silent "${LM_URL}/models" | grep '"id"' || true
  fail "Load the model in LM Studio or use --model <id> with the correct ID."
fi
ok "Model '$MODEL_ID' found in LM Studio"

# --------------------------------------------------------------------------
# Step 1 — Create workspace and sandbox
# --------------------------------------------------------------------------
step "1: Create sandbox '${NAME}'"

mkdir -p "$WORKSPACE"
ok "Workspace directory: ${WORKSPACE}"

info "Creating sandbox ..."
docker sandbox create --name "$NAME" shell "$WORKSPACE"
ok "Sandbox '${NAME}' created"

info "Configuring network proxy (--allow-host localhost) ..."
docker sandbox network proxy "$NAME" --allow-host localhost
ok "Network proxy configured"

# --------------------------------------------------------------------------
# Step 2 — Install system packages, Node.js, OpenClaw, undici (as root)
# --------------------------------------------------------------------------
step "2: Install packages inside sandbox (as root)"

info "Installing system deps, Node.js ${NODE_VERSION}, OpenClaw, and undici ..."
docker sandbox exec --user root "$NAME" bash -c "
  set -e
  apt-get update -qq && apt-get install -y -qq curl vim-tiny >/dev/null 2>&1
  npm install -g n >/dev/null 2>&1
  n ${NODE_VERSION} >/dev/null 2>&1
  hash -r
  npm install -g openclaw@latest undici >/dev/null 2>&1
  echo \"Node.js: \$(node --version)\"
  echo \"OpenClaw: \$(openclaw --version)\"
"
ok "Packages installed"

# --------------------------------------------------------------------------
# Step 3 — Configure proxy bootstrap (as root)
# --------------------------------------------------------------------------
step "3: Configure proxy bootstrap"

info "Writing proxy-bootstrap.js and NODE_OPTIONS ..."
docker sandbox exec --user root "$NAME" bash -c '
  set -e
  NPM_GLOBAL="$(npm root -g)"
  cat > /usr/local/bin/proxy-bootstrap.js <<EOF
const undici = require("${NPM_GLOBAL}/undici");
undici.setGlobalDispatcher(new undici.ProxyAgent({ uri: "http://192.168.65.254:3128", proxyTunnel: false }));
globalThis.fetch = undici.fetch;
EOF

  PROXY_LINE="export NODE_OPTIONS=\"--require /usr/local/bin/proxy-bootstrap.js\""
  grep -q "proxy-bootstrap.js" /home/agent/.bashrc 2>/dev/null || echo "$PROXY_LINE" >> /home/agent/.bashrc
  grep -q "proxy-bootstrap.js" /root/.bashrc 2>/dev/null || echo "$PROXY_LINE" >> /root/.bashrc

  export NODE_OPTIONS="--require /usr/local/bin/proxy-bootstrap.js"
  node -e "console.log(\"proxy-bootstrap loaded OK\")"
'
ok "Proxy bootstrap configured"

# --------------------------------------------------------------------------
# Step 4 — Configure OpenClaw (as agent — not root!)
# --------------------------------------------------------------------------
step "4: Configure OpenClaw for LM Studio (as agent)"

info "Writing openclaw config ..."
docker sandbox exec "$NAME" bash -c "
  set -e
  export NODE_OPTIONS='--require /usr/local/bin/proxy-bootstrap.js'
  openclaw config set models.providers.lm-studio '{\"baseUrl\":\"${LM_URL}\",\"apiKey\":\"lm-studio\",\"models\":[{\"id\":\"${MODEL_ID}\",\"name\":\"LM Studio Local\",\"api\":\"openai-completions\"}]}'
  openclaw models set lm-studio/${MODEL_ID}
  openclaw models status
"
ok "OpenClaw configured with model: ${MODEL_ID}"

# --------------------------------------------------------------------------
# Step 4b — Install gateway daemon (optional)
# --------------------------------------------------------------------------
if [[ "$INSTALL_DAEMON" == true ]]; then
  info "Configuring OpenClaw gateway ..."
  docker sandbox exec "$NAME" bash -c "
    set -e
    export NODE_OPTIONS='--require /usr/local/bin/proxy-bootstrap.js'
    openclaw onboard --non-interactive --accept-risk \
      --auth-choice custom-api-key \
      --custom-base-url '${LM_URL}' \
      --custom-api-key lm-studio \
      --custom-compatibility openai \
      --custom-model-id '${MODEL_ID}' \
      --skip-skills \
      --skip-channels \
      --skip-search \
      --skip-ui \
      --skip-health
  "
  info "Adding gateway auto-start to agent's .bashrc ..."
  docker sandbox exec "$NAME" bash -c '
    GATEWAY_LINE="# Auto-start OpenClaw gateway in the background"
    if ! grep -q "openclaw gateway run" /home/agent/.bashrc 2>/dev/null; then
      cat >> /home/agent/.bashrc <<GWEOF

$GATEWAY_LINE
if ! pgrep -f "openclaw gateway run" >/dev/null 2>&1; then
  nohup openclaw gateway run >/dev/null 2>&1 &
fi
GWEOF
    fi
  '
  ok "Gateway will auto-start when the sandbox launches"
fi

# --------------------------------------------------------------------------
# Step 5 — Verify connectivity
# --------------------------------------------------------------------------
if [[ "$SKIP_VERIFY" == false ]]; then
  step "5: Verify connectivity"

  info "Testing curl through proxy ..."
  docker sandbox exec "$NAME" bash -c "
    curl --silent --fail --noproxy '' -x http://host.docker.internal:3128 ${LM_URL}/models >/dev/null
  "
  ok "curl proxy test passed"

  info "Testing Node.js fetch() through proxy ..."
  docker sandbox exec "$NAME" bash -c "
    export NODE_OPTIONS='--require /usr/local/bin/proxy-bootstrap.js'
    node -e \"fetch('${LM_URL}/models').then(r=>r.json()).then(d=>console.log('SUCCESS')).catch(e=>{console.log('FAIL',e.message);process.exit(1)})\"
  "
  ok "Node.js fetch() proxy test passed"

  info "Smoke-testing OpenClaw ..."
  docker sandbox exec "$NAME" bash -c "
    set -e
    export NODE_OPTIONS='--require /usr/local/bin/proxy-bootstrap.js'
    openclaw agent --local --session-id setup-test -m 'Reply with exactly: setup OK'
  "
  ok "OpenClaw smoke test passed"
else
  info "Skipping verification (--skip-verify)"
fi

# --------------------------------------------------------------------------
# Step 6 — Save template (optional)
# --------------------------------------------------------------------------
if [[ -n "$TEMPLATE" ]]; then
  step "6: Save template '${TEMPLATE}'"

  if ! docker sandbox save "$NAME" "$TEMPLATE" 2>/dev/null; then
    TEMPLATE_FILE="${HOME}/${TEMPLATE//[:\/]/-}.tar"
    warn "Host Docker not available for image save. Exporting to file ..."
    docker sandbox save "$NAME" "$TEMPLATE" --output "$TEMPLATE_FILE"
    ok "Template saved to: ${TEMPLATE_FILE}"
  else
    ok "Template saved as: ${TEMPLATE}"
  fi
fi

# --------------------------------------------------------------------------
# Done
# --------------------------------------------------------------------------
printf "\n${GREEN}${BOLD}Setup complete!${RESET}\n"
printf "Launch the sandbox with:\n"
printf "  ${CYAN}docker sandbox run %s${RESET}\n\n" "$NAME"
