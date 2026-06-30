#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apply=0
enable_services=1
restart_services=0
remove_omniroute=1
force_env=0

usage() {
  printf '%s\n' \
    'Usage: scripts/install-openclaw-chatgpt.sh [--dry-run] [--apply] [--restart] [--no-enable] [--force-env] [--keep-omniroute]' \
    '' \
    'Installs or refreshes the OpenClaw Gateway + OpenAI-compatible Codex relay path.' \
    'OmniRoute is removed by default. No Anthropic/OmniRoute base URL is installed.' \
    '' \
    'Prerequisites:' \
    '  - OpenClaw CLI is already installed and authenticated with ChatGPT/OpenAI Codex.' \
    '  - Node.js 18+ is available, preferably next to the OpenClaw CLI.' \
    '' \
    'Environment overrides:' \
    '  OPENCLAW_RUN_USER=sol' \
    '  OPENCLAW_RUN_GROUP=sol' \
    '  OPENCLAW_RUN_HOME=/home/sol' \
    '  OPENCLAW_BIN=/usr/local/bin/openclaw' \
    '  OPENCLAW_NODE_BIN=/home/sol/.nvm/versions/node/v24.11.0/bin/node' \
    '  OPENCLAW_RELAY_ROOT=/opt/solana-hot-swap-operator-kit/relay' \
    '  OPENCLAW_RELAY_CONFIG_DIR=/etc/solana-hotswap/openclaw' \
    '  OPENCLAW_RELAY_ALLOWLIST=127.0.0.1,::1' \
    '  OPENCLAW_RELAY_MODEL=openai/gpt-5.5' \
    '  OPENCLAW_RELAY_THINKING=low'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      apply=0
      ;;
    --apply)
      apply=1
      ;;
    --restart)
      restart_services=1
      ;;
    --no-enable)
      enable_services=0
      ;;
    --force-env)
      force_env=1
      ;;
    --keep-omniroute)
      remove_omniroute=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

print_command() {
  printf '++'
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

run() {
  print_command "$@"
  if [ "$apply" -eq 1 ]; then
    "$@"
  fi
}

run_maybe() {
  print_command "$@"
  if [ "$apply" -eq 1 ]; then
    "$@" || true
  fi
}

fail() {
  echo "BLOCKER: $*" >&2
  exit 3
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing required command: $1"
  fi
}

require_command install
require_command python3
require_command sed
require_command systemctl

sudo_cmd=()
if [ "$(id -u)" -ne 0 ]; then
  require_command sudo
  sudo_cmd=(sudo)
fi

if [ -n "${OPENCLAW_RUN_USER:-}" ]; then
  run_user="$OPENCLAW_RUN_USER"
elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  run_user="$SUDO_USER"
else
  run_user="$(id -un)"
  if [ "$run_user" = "root" ] && id sol >/dev/null 2>&1; then
    run_user="sol"
  fi
fi

run_group="${OPENCLAW_RUN_GROUP:-$run_user}"
if ! id "$run_user" >/dev/null 2>&1; then
  fail "run user does not exist: $run_user"
fi
if ! getent group "$run_group" >/dev/null 2>&1; then
  fail "run group does not exist: $run_group"
fi

run_home="${OPENCLAW_RUN_HOME:-}"
if [ -z "$run_home" ]; then
  run_home="$(getent passwd "$run_user" | cut -d: -f6)"
fi
if [ -z "$run_home" ] || [ ! -d "$run_home" ]; then
  fail "cannot determine home directory for $run_user"
fi

openclaw_bin="${OPENCLAW_BIN:-}"
if [ -z "$openclaw_bin" ] && command -v openclaw >/dev/null 2>&1; then
  openclaw_bin="$(command -v openclaw)"
fi
if [ -z "$openclaw_bin" ] && [ -x "$run_home/.nvm/versions/node/v24.11.0/bin/openclaw" ]; then
  openclaw_bin="$run_home/.nvm/versions/node/v24.11.0/bin/openclaw"
fi
if [ -z "$openclaw_bin" ] || [ ! -x "$openclaw_bin" ]; then
  fail "OpenClaw CLI not found. Set OPENCLAW_BIN=/path/to/openclaw"
fi

node_bin="${OPENCLAW_NODE_BIN:-}"
if [ -z "$node_bin" ]; then
  sibling_node="$(dirname "$openclaw_bin")/node"
  if [ -x "$sibling_node" ]; then
    node_bin="$sibling_node"
  fi
fi
if [ -z "$node_bin" ] && command -v node >/dev/null 2>&1; then
  node_bin="$(command -v node)"
fi
if [ -z "$node_bin" ] || [ ! -x "$node_bin" ]; then
  fail "Node.js not found. Set OPENCLAW_NODE_BIN=/path/to/node"
fi

if ! "$node_bin" -e 'const major=Number(process.versions.node.split(".")[0]); if (major < 18) process.exit(1);' >/dev/null 2>&1; then
  fail "Node.js 18+ is required for OpenClaw services: $node_bin"
fi

path_exists() {
  if [ -e "$1" ]; then
    return 0
  fi
  if [ "${#sudo_cmd[@]}" -gt 0 ]; then
    sudo test -e "$1" >/dev/null 2>&1
    return $?
  fi
  return 1
}

node_dir="$(dirname "$node_bin")"
relay_root="${OPENCLAW_RELAY_ROOT:-/opt/solana-hot-swap-operator-kit/relay}"
relay_config_dir="${OPENCLAW_RELAY_CONFIG_DIR:-/etc/solana-hotswap/openclaw}"
relay_env="$relay_config_dir/relay.env"
legacy_relay_env="${OPENCLAW_LEGACY_RELAY_ENV:-$run_home/openclaw-codex-relay/relay.env}"
gateway_port="${OPENCLAW_GATEWAY_PORT:-18789}"
relay_port="${OPENCLAW_RELAY_PORT:-20129}"
relay_host="${OPENCLAW_RELAY_HOST:-0.0.0.0}"
relay_allowlist="${OPENCLAW_RELAY_ALLOWLIST:-127.0.0.1,::1}"
relay_model="${OPENCLAW_RELAY_MODEL:-openai/gpt-5.5}"
relay_thinking="${OPENCLAW_RELAY_THINKING:-low}"
relay_timeout_ms="${OPENCLAW_RELAY_TIMEOUT_MS:-180000}"
openclaw_workspace="${OPENCLAW_WORKSPACE:-$run_home/.openclaw/workspace}"
gateway_log="${OPENCLAW_GATEWAY_LOG:-/var/log/openclaw-gateway.log}"
relay_log="${OPENCLAW_RELAY_LOG:-/var/log/openclaw-codex-relay.log}"

echo "dry_run=$([ "$apply" -eq 1 ] && echo false || echo true)"
echo "run_user=$run_user"
echo "openclaw_bin=$openclaw_bin"
echo "node_bin=$node_bin"
echo "relay_root=$relay_root"
echo "relay_env=$relay_env"

if [ "$remove_omniroute" -eq 1 ]; then
  run_maybe "${sudo_cmd[@]}" systemctl stop omniroute.service
  run_maybe "${sudo_cmd[@]}" systemctl disable omniroute.service
  run_maybe "${sudo_cmd[@]}" rm -f /etc/systemd/system/omniroute.service
  run_maybe "${sudo_cmd[@]}" rm -f /etc/systemd/system/multi-user.target.wants/omniroute.service
  run_maybe "${sudo_cmd[@]}" rm -rf "$run_home/.omniroute"
  run_maybe "${sudo_cmd[@]}" rm -f /var/log/omniroute.log
  for path in "$run_home"/.nvm/versions/node/*/bin/omniroute; do
    if [ -e "$path" ]; then
      run_maybe "${sudo_cmd[@]}" rm -f "$path"
    fi
  done
  for path in "$run_home"/.nvm/versions/node/*/lib/node_modules/omniroute; do
    if [ -e "$path" ]; then
      run_maybe "${sudo_cmd[@]}" rm -rf "$path"
    fi
  done
fi

run "${sudo_cmd[@]}" install -d -m 0755 "$relay_root"
run "${sudo_cmd[@]}" install -d -m 0750 -o "$run_user" -g "$run_group" "$relay_config_dir"
run "${sudo_cmd[@]}" install -d -m 0755 "$(dirname "$gateway_log")"
run "${sudo_cmd[@]}" install -d -m 0755 "$(dirname "$relay_log")"
run "${sudo_cmd[@]}" install -m 0644 "$repo_root/relay/openclaw-codex-relay.mjs" "$relay_root/openclaw-codex-relay.mjs"

if ! path_exists "$relay_env" && [ "$force_env" -eq 0 ] && path_exists "$legacy_relay_env"; then
  echo "migrate_legacy_relay_env=$legacy_relay_env"
  run "${sudo_cmd[@]}" install -m 0600 -o "$run_user" -g "$run_group" "$legacy_relay_env" "$relay_env"
elif ! path_exists "$relay_env" || [ "$force_env" -eq 1 ]; then
  relay_token="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
  tmp_env="$(mktemp)"
  printf '%s\n' \
    "PORT=$relay_port" \
    "HOST=$relay_host" \
    "OPENCLAW_BIN=$openclaw_bin" \
    "OPENCLAW_WORKSPACE=$openclaw_workspace" \
    "OPENCLAW_CODEX_RELAY_MODEL=$relay_model" \
    "OPENCLAW_CODEX_RELAY_THINKING=$relay_thinking" \
    "OPENCLAW_CODEX_RELAY_TIMEOUT_MS=$relay_timeout_ms" \
    "OPENCLAW_CODEX_RELAY_ALLOWLIST=$relay_allowlist" \
    "OPENCLAW_CODEX_RELAY_TOKEN=$relay_token" > "$tmp_env"
  run "${sudo_cmd[@]}" install -m 0600 -o "$run_user" -g "$run_group" "$tmp_env" "$relay_env"
  rm -f "$tmp_env"
else
  echo "preserve_existing_relay_env=true"
fi

render_template() {
  src="$1"
  dst="$2"
  tmp_file="$(mktemp)"
  sed \
    -e "s|@RUN_USER@|$run_user|g" \
    -e "s|@RUN_GROUP@|$run_group|g" \
    -e "s|@RUN_HOME@|$run_home|g" \
    -e "s|@NODE_BIN@|$node_bin|g" \
    -e "s|@NODE_DIR@|$node_dir|g" \
    -e "s|@OPENCLAW_BIN@|$openclaw_bin|g" \
    -e "s|@OPENCLAW_WORKSPACE@|$openclaw_workspace|g" \
    -e "s|@GATEWAY_PORT@|$gateway_port|g" \
    -e "s|@GATEWAY_LOG@|$gateway_log|g" \
    -e "s|@RELAY_ROOT@|$relay_root|g" \
    -e "s|@RELAY_ENV@|$relay_env|g" \
    -e "s|@RELAY_LOG@|$relay_log|g" \
    "$src" > "$tmp_file"
  run "${sudo_cmd[@]}" install -m 0644 "$tmp_file" "$dst"
  rm -f "$tmp_file"
}

render_template "$repo_root/systemd/openclaw-gateway.service.example" /etc/systemd/system/openclaw-gateway.service
render_template "$repo_root/systemd/openclaw-codex-relay.service.example" /etc/systemd/system/openclaw-codex-relay.service

run "${sudo_cmd[@]}" systemctl daemon-reload

if [ -f "$run_home/.openclaw/openclaw.json" ]; then
  run "${sudo_cmd[@]}" python3 "$repo_root/scripts/openclaw_config_cleanup.py" \
    "$run_home/.openclaw/openclaw.json" \
    "$run_home/.openclaw/agents/main/agent/models.json" \
    "$run_home/.openclaw/agents/main/agent/auth-profiles.json"
fi

if [ "$enable_services" -eq 1 ]; then
  run "${sudo_cmd[@]}" systemctl enable openclaw-gateway.service
  run "${sudo_cmd[@]}" systemctl enable openclaw-codex-relay.service
fi

if [ "$restart_services" -eq 1 ]; then
  run "${sudo_cmd[@]}" systemctl restart openclaw-gateway.service
  run "${sudo_cmd[@]}" systemctl restart openclaw-codex-relay.service
fi

echo "gateway_service=/etc/systemd/system/openclaw-gateway.service"
echo "relay_service=/etc/systemd/system/openclaw-codex-relay.service"
echo "relay_env=$relay_env"
echo "next=systemctl status openclaw-gateway.service openclaw-codex-relay.service --no-pager"
