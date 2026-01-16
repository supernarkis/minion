#!/usr/bin/env bash
# install_gemini_cli_ubuntu22.sh
# Purpose: Deterministic-ish install of nvm + Node LTS + @google/gemini-cli on Ubuntu 22.04
# Behavior: verbose step logs; fails fast; prints actionable diagnostics.

set -Eeuo pipefail

###############################################################################
# Config (pin versions for repeatability)
###############################################################################
NVM_VERSION_DEFAULT="v0.39.7"
NODE_CHANNEL_DEFAULT="--lts"     # or use "20" / "22" etc if you want hard pin
GEMINI_PKG_DEFAULT="@google/gemini-cli"

# Allow overriding via env
NVM_VERSION="${NVM_VERSION:-$NVM_VERSION_DEFAULT}"
NODE_CHANNEL="${NODE_CHANNEL:-$NODE_CHANNEL_DEFAULT}"
GEMINI_PKG="${GEMINI_PKG:-$GEMINI_PKG_DEFAULT}"

# If running as root is not desired (nvm is per-user)
ALLOW_ROOT="${ALLOW_ROOT:-0}"

###############################################################################
# Logging helpers (agent-friendly)
###############################################################################
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log()  { echo "[$(ts)] [INFO]  $*"; }
warn() { echo "[$(ts)] [WARN]  $*" >&2; }
err()  { echo "[$(ts)] [ERROR] $*" >&2; }

STEP_NO=0
STEP_NAME=""

step() {
  STEP_NO=$((STEP_NO+1))
  STEP_NAME="$*"
  echo
  echo "[$(ts)] [STEP $STEP_NO] >>> $STEP_NAME"
}

ok() {
  echo "[$(ts)] [STEP $STEP_NO] OK  <<< $STEP_NAME"
}

die() {
  err "$*"
  exit 1
}

on_err() {
  local exit_code=$?
  local line_no="${1:-unknown}"
  local cmd="${2:-unknown}"
  err "FAILED at STEP $STEP_NO: $STEP_NAME"
  err "Line: $line_no"
  err "Command: $cmd"
  err "Exit code: $exit_code"
  err "Context:"
  err "  USER=$(id -un) UID=$(id -u) HOME=${HOME:-unset} SHELL=${SHELL:-unset}"
  err "  PATH=$PATH"
  err "Suggested next actions:"
  err "  - Re-run with: bash -x ./install_gemini_cli_ubuntu22.sh 2>&1 | tee install.debug.log"
  err "  - Check if sudo is available/non-interactive (if not root)"
  err "  - Verify network/DNS access to github.com and registry.npmjs.org"
  exit "$exit_code"
}
trap 'on_err ${LINENO} "$BASH_COMMAND"' ERR

###############################################################################
# Preconditions
###############################################################################
step "Preflight checks (OS / shell / permissions)"

if [[ -z "${BASH_VERSION:-}" ]]; then
  die "This script must be run with bash (not sh). Use: bash ./install_gemini_cli_ubuntu22.sh"
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  log "Detected OS: ${PRETTY_NAME:-unknown}"
  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "This script is intended for Ubuntu. Detected ID=${ID:-unknown}. Proceeding anyway."
  fi
  if [[ "${VERSION_ID:-}" != "22.04" ]]; then
    warn "Target is Ubuntu 22.04. Detected VERSION_ID=${VERSION_ID:-unknown}. Proceeding anyway."
  fi
else
  warn "/etc/os-release not readable; cannot verify OS."
fi

if [[ "$(id -u)" -eq 0 ]]; then
  if [[ "$ALLOW_ROOT" != "1" ]]; then
    die "Running as root is disabled by default (nvm is per-user). Re-run with: ALLOW_ROOT=1 bash ./install_gemini_cli_ubuntu22.sh  (or run as a non-root user)."
  else
    warn "Running as root (ALLOW_ROOT=1). nvm will be installed under /root by default."
  fi
fi

ok

###############################################################################
# Determine sudo strategy
###############################################################################
step "Determine privilege escalation method (sudo/non-interactive)"

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    # -n = non-interactive; if password required, it fails immediately (good for agents)
    if sudo -n true >/dev/null 2>&1; then
      SUDO="sudo -n"
      log "Using sudo (non-interactive)."
    else
      die "sudo exists but requires a password (non-interactive sudo failed). Either: (1) run as root (ALLOW_ROOT=1) or (2) configure passwordless sudo for this user."
    fi
  else
    die "Not root and sudo is not installed. Install sudo or run as root (ALLOW_ROOT=1)."
  fi
else
  log "Running as root; sudo not needed."
fi

ok

###############################################################################
# Install apt dependencies
###############################################################################
step "Install required packages via apt (curl, ca-certificates, git, build essentials)"

# Keep apt output visible but structured
$SUDO apt-get update -y

# ca-certificates for TLS, curl to fetch nvm, git sometimes used by nvm installer,
# build-essential helps if node needs compilation (rare but safer).
$SUDO apt-get install -y --no-install-recommends \
  ca-certificates curl git build-essential

# Ensure certs are up to date
$SUDO update-ca-certificates >/dev/null 2>&1 || true

log "Versions:"
log "  curl: $({ curl --version 2>/dev/null | head -n1; } || echo 'not found')"
log "  git:  $({ git --version 2>/dev/null; } || echo 'not found')"

ok

###############################################################################
# Install/Verify nvm
###############################################################################
step "Install or verify nvm ($NVM_VERSION)"

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  log "nvm already present at: $NVM_DIR"
else
  log "Installing nvm to: $NVM_DIR"
  # Official installer from nvm-sh repo (pinned version tag)
  # NOTE: This pulls remote code; pinning to tag reduces drift.
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi

# Load nvm into current shell (critical for non-interactive session)
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"
else
  die "nvm.sh not found after installation. Expected at: $NVM_DIR/nvm.sh"
fi

log "nvm version: $(nvm --version)"

ok

###############################################################################
# Install Node.js LTS
###############################################################################
step "Install Node.js via nvm (${NODE_CHANNEL}) and set as default"

# NODE_CHANNEL is either "--lts" or a version like "20" / "22"
# shellcheck disable=SC2086
nvm install ${NODE_CHANNEL}

# Set default so future shells get it (nvm uses alias)
if [[ "$NODE_CHANNEL" == "--lts" ]]; then
  nvm alias default "lts/*" >/dev/null
else
  nvm alias default "${NODE_CHANNEL}" >/dev/null
fi

# Use default in this shell too
nvm use default >/dev/null

log "Node: $(node -v)"
log "npm:  $(npm -v)"
log "node path: $(command -v node)"
log "npm path:  $(command -v npm)"

ok

###############################################################################
# Install gemini-cli
###############################################################################
step "Install ${GEMINI_PKG} globally with npm"

# For agent-safety: show where global installs go
log "npm prefix: $(npm config get prefix)"
log "npm global bin: $(npm bin -g)"

# Install
npm install -g "${GEMINI_PKG}"

# Verify executable
if command -v gemini >/dev/null 2>&1; then
  log "gemini path: $(command -v gemini)"
  # Some CLIs print to stderr; capture both
  gemini --version 2>&1 | sed 's/^/[GEMINI] /' || warn "gemini --version returned non-zero (may be normal depending on cli behavior)."
else
  die "gemini executable not found in PATH after install. Check npm global bin and PATH."
fi

ok

###############################################################################
# Final summary
###############################################################################
step "Final summary / next steps"

cat <<EOF
[$(ts)] [INFO] Installation completed.

What was installed:
  - nvm:   $(nvm --version)   (dir: $NVM_DIR)
  - node:  $(node -v)
  - npm:   $(npm -v)
  - gemini: $(command -v gemini)

Notes:
  - This script only installs the CLI. Authentication/config (if required) happens when running 'gemini' interactively.
  - For non-interactive SSH agents, plan how you provide credentials/tokens in your runtime environment.

EOF

ok
