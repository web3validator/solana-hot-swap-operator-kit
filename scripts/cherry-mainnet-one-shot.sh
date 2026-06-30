#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${HOTSWAP_ENV_FILE:-/etc/solana-hotswap/hotswap.env}"
mode="plan"

usage() {
  printf '%s\n' \
    'Usage: scripts/cherry-mainnet-one-shot.sh [--plan] [--create] [--bootstrap] [--create-and-bootstrap]' \
    '' \
    'Runs the Cherry hot-swap server preparation path from the private hotswap env.' \
    '' \
    'Modes:' \
    '  --plan                  show config, verify project is empty, and print the exact order payload' \
    '  --create                do --plan, then create one paid hourly Cherry server' \
    '  --bootstrap             bootstrap an existing SERVER_ID/SERVER_IP from the latest state file or environment' \
    '  --create-and-bootstrap  create one paid hourly server, wait for IP, verify, wait, then run target bootstrap' \
    '' \
    'Environment overrides:' \
    '  HOTSWAP_ENV_FILE=/etc/solana-hotswap/hotswap.env' \
    '  CHERRY_BOOTSTRAP_DELAY_SECONDS=1200'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan)
      mode="plan"
      ;;
    --create)
      mode="create"
      ;;
    --bootstrap)
      mode="bootstrap"
      ;;
    --create-and-bootstrap)
      mode="create-and-bootstrap"
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

if [ ! -r "$env_file" ]; then
  echo "BLOCKER: cannot read env file: $env_file" >&2
  echo "Run scripts/import-cherry-reference.sh --apply first, or run this script with sudo." >&2
  exit 3
fi

set -a
. "$env_file"
set +a

cd "$repo_root"

run_plan() {
  echo "== hotswap config =="
  ./scripts/solana-cherry-hotswap-guard.sh show-config

  echo "== Cherry credit summary =="
  ./scripts/solana-cherry-hotswap-guard.sh cherry-credit-summary

  echo "== Cherry project empty gate =="
  ./scripts/solana-cherry-hotswap-guard.sh cherry-list

  echo "== Cherry order payload =="
  ./scripts/solana-cherry-hotswap-guard.sh cherry-order-payload
}

latest_state_file() {
  find "${HOTSWAP_RUN_DIR:-runs/cherry-attempts}" -maxdepth 1 -type f -name 'cherry-create-*.env' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d ' ' -f 2-
}

load_state_file() {
  state_file="${STATE_FILE:-}"
  if [ -z "$state_file" ]; then
    state_file="$(latest_state_file)"
  fi
  if [ -z "$state_file" ] || [ ! -r "$state_file" ]; then
    echo "BLOCKER: no readable Cherry state file found; set STATE_FILE or run --create first" >&2
    exit 4
  fi
  set -a
  . "$state_file"
  set +a
  printf 'state_file=%s\n' "$state_file"
}

wait_for_ip() {
  state_file="${STATE_FILE:-$(latest_state_file)}"
  if [ -z "${SERVER_ID:-}" ]; then
    load_state_file
  fi
  ./scripts/solana-cherry-hotswap-guard.sh cherry-wait-ip --timeout-seconds "${CHERRY_WAIT_IP_TIMEOUT_SECONDS:-1800}" --interval-seconds "${CHERRY_WAIT_IP_INTERVAL_SECONDS:-30}" --state-file "$state_file"
  set -a
  . "$state_file"
  set +a
}

wait_for_ssh() {
  if [ -z "${SERVER_IP:-}" ]; then
    wait_for_ip
  fi
  ./scripts/solana-cherry-hotswap-guard.sh cherry-wait-ssh --timeout-seconds "${CHERRY_WAIT_SSH_TIMEOUT_SECONDS:-1800}" --interval-seconds "${CHERRY_WAIT_SSH_INTERVAL_SECONDS:-120}" --initial-delay-seconds "${CHERRY_WAIT_SSH_INITIAL_DELAY_SECONDS:-900}"
}

wait_until_bootstrap_window() {
  delay="${CHERRY_BOOTSTRAP_DELAY_SECONDS:-1200}"
  if [ "$delay" -le 0 ]; then
    echo "bootstrap_min_age_disabled=true"
    return
  fi
  if [ -n "${CREATED_AT_EPOCH:-}" ]; then
    now="$(date +%s)"
    target=$((CREATED_AT_EPOCH + delay))
    remaining=$((target - now))
    if [ "$remaining" -gt 0 ]; then
      echo "== waiting ${remaining}s until target reaches minimum bootstrap age (${delay}s from create) =="
      sleep "$remaining"
    else
      echo "bootstrap_min_age_satisfied=true"
    fi
  else
    echo "== CREATED_AT_EPOCH missing; waiting fallback ${delay}s before bootstrap =="
    sleep "$delay"
  fi
}

ssh_base_args() {
  printf '%s\n' \
    -i "${CHERRY_SSH_KEY:?missing CHERRY_SSH_KEY}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${CHERRY_KNOWN_HOSTS:-runs/known_hosts}" \
    -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-8}"
}

remote_quote() {
  printf '%q' "$1"
}

bootstrap_target() {
  if [ -z "${SERVER_IP:-}" ]; then
    load_state_file
  fi
  if [ -z "${SERVER_IP:-}" ]; then
    wait_for_ip
  fi

  : "${SOLANA_SETUP_REPO:?missing SOLANA_SETUP_REPO in $env_file}"
  : "${SOLANA_SETUP_BRANCH:?missing SOLANA_SETUP_BRANCH in $env_file}"
  : "${FD_VERSION:?missing FD_VERSION in $env_file}"
  : "${FD_NETWORK:?missing FD_NETWORK in $env_file}"
  : "${SSH_ALLOW_CIDR:?missing SSH_ALLOW_CIDR in $env_file}"

  mapfile -t ssh_args < <(ssh_base_args)
  target_user="${CHERRY_TARGET_USER:-}"
  if [ -z "$target_user" ]; then
    for candidate in root ubuntu; do
      if ! ssh "${ssh_args[@]}" "$candidate@$SERVER_IP" true >/dev/null 2>&1; then
        continue
      fi
      if [ "$candidate" = "root" ] || ssh "${ssh_args[@]}" "$candidate@$SERVER_IP" "sudo -n true" >/dev/null 2>&1; then
        target_user="$candidate"
        break
      fi
    done
  fi
  if [ -z "$target_user" ]; then
    echo "BLOCKER: neither ubuntu nor root accepted the configured Cherry SSH key" >&2
    exit 5
  fi
  target="$target_user@$SERVER_IP"
  echo "cherry_bootstrap_ssh_user=$target_user"

  echo "== upload bootstrap assets to $target =="
  ssh "${ssh_args[@]}" "$target" "sudo install -d -m 0700 /root/.ssh-secrets"
  scp "${ssh_args[@]}" "$repo_root/scripts/solana-cherry-target-bootstrap.sh" "$target:/tmp/solana-cherry-target-bootstrap.sh"
  scp "${ssh_args[@]}" "${CHERRY_SSH_KEY:?missing CHERRY_SSH_KEY}" "$target:/tmp/cherry-bootstrap-key"
  ssh "${ssh_args[@]}" "$target" "sudo install -m 0700 /tmp/solana-cherry-target-bootstrap.sh /root/solana-cherry-target-bootstrap.sh && sudo install -m 0600 /tmp/cherry-bootstrap-key /root/.ssh-secrets/cherry-bootstrap-key && rm -f /tmp/solana-cherry-target-bootstrap.sh /tmp/cherry-bootstrap-key"

  remote_cmd="SOLANA_SETUP_REPO=$(remote_quote "$SOLANA_SETUP_REPO") SOLANA_SETUP_BRANCH=$(remote_quote "$SOLANA_SETUP_BRANCH") FD_VERSION=$(remote_quote "$FD_VERSION") FD_NETWORK=$(remote_quote "$FD_NETWORK") SSH_ALLOW_CIDR=$(remote_quote "$SSH_ALLOW_CIDR") FD_USER=$(remote_quote "${FD_USER:-ubuntu}") BAM_REGION=$(remote_quote "${BAM_REGION:-dallas}") SSH_PRIVATE_KEY_SHRED_AFTER_INSTALL=$(remote_quote "${SSH_PRIVATE_KEY_SHRED_AFTER_INSTALL:-false}") SSH_PRIVATE_KEY_FILE=/root/.ssh-secrets/cherry-bootstrap-key sudo -E bash /root/solana-cherry-target-bootstrap.sh"

  echo "== run target bootstrap =="
  ssh "${ssh_args[@]}" "$target" "$remote_cmd"

  echo "== post-bootstrap verify =="
  ./scripts/solana-cherry-hotswap-guard.sh post-bootstrap-verify
}

run_create() {
  run_plan
  echo "== creating one paid hourly Cherry server =="
  CONFIRM_PAID_CHERRY_CREATE=I_CONFIRM_ONE_HOURLY_SERVER ./scripts/solana-cherry-hotswap-guard.sh cherry-create
  load_state_file
}

case "$mode" in
  plan)
    run_plan
    echo "plan_complete=true"
    echo "next_create=sudo -n env HOTSWAP_ENV_FILE=$env_file $repo_root/scripts/cherry-mainnet-one-shot.sh --create"
    echo "next_create_and_bootstrap=sudo -n env HOTSWAP_ENV_FILE=$env_file $repo_root/scripts/cherry-mainnet-one-shot.sh --create-and-bootstrap"
    ;;
  create)
    run_create
    echo "create_complete=true"
    echo "next=sudo -n env HOTSWAP_ENV_FILE=$env_file $repo_root/scripts/cherry-mainnet-one-shot.sh --bootstrap"
    ;;
  bootstrap)
    load_state_file
    wait_for_ip
    wait_for_ssh
    echo "== attempt-after-create gate =="
    ./scripts/solana-cherry-hotswap-guard.sh attempt-after-create
    wait_until_bootstrap_window
    bootstrap_target
    echo "bootstrap_complete=true"
    ;;
  create-and-bootstrap)
    run_create
    wait_for_ip
    wait_for_ssh
    echo "== attempt-after-create gate =="
    ./scripts/solana-cherry-hotswap-guard.sh attempt-after-create
    wait_until_bootstrap_window
    bootstrap_target
    echo "create_and_bootstrap_complete=true"
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac
