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
    '  CHERRY_BOOTSTRAP_DELAY_SECONDS=1200' \
    '  CHERRY_BOOTSTRAP_TMUX=true' \
    '  CHERRY_BOOTSTRAP_SESSION=solana-bootstrap'
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

notify_telegram() {
  message="$1"
  HOTSWAP_ENV_FILE="$env_file" "$repo_root/scripts/notify-telegram.sh" --message "$message" || true
}

post_bootstrap_reboot_and_notify() {
  target="$1"
  root_cmd="$2"
  if [ "${CHERRY_REBOOT_AFTER_BOOTSTRAP:-true}" != "true" ]; then
    notify_telegram "Cherry target bootstrap complete: ${SERVER_IP:-unknown}. Reboot disabled. Ready for key staging after operator verification."
    return 0
  fi

  notify_telegram "Cherry target bootstrap complete: ${SERVER_IP:-unknown}. Rebooting now; I will notify when SSH is back."
  echo "== reboot target after bootstrap =="
  ssh "${ssh_args[@]}" "$target" "${root_cmd}reboot" >/dev/null 2>&1 || true
  sleep "${CHERRY_REBOOT_INITIAL_WAIT_SECONDS:-30}"
  ./scripts/solana-cherry-hotswap-guard.sh cherry-wait-ssh --timeout-seconds "${CHERRY_REBOOT_WAIT_SSH_TIMEOUT_SECONDS:-1800}" --interval-seconds "${CHERRY_REBOOT_WAIT_SSH_INTERVAL_SECONDS:-30}" --initial-delay-seconds 0
  echo "== post-reboot verify =="
  ./scripts/solana-cherry-hotswap-guard.sh post-bootstrap-verify
  notify_telegram "Cherry target is ready after reboot: ${SERVER_IP:-unknown}. Firedancer bootstrap passed. Пересылай ключи на target, затем запускаем fire/sync stage."
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

  if [ "$target_user" = "root" ]; then
    root_cmd=""
    root_env_cmd="env"
  else
    root_cmd="sudo -n "
    root_env_cmd="sudo -n env"
  fi

  extra_authorized_keys_file="${CHERRY_TARGET_AUTHORIZED_KEYS_FILE:-}"
  if [ -n "$extra_authorized_keys_file" ] && [ ! -r "$extra_authorized_keys_file" ]; then
    echo "BLOCKER: CHERRY_TARGET_AUTHORIZED_KEYS_FILE is not readable: $extra_authorized_keys_file" >&2
    exit 6
  fi

  bootstrap_env_file="$(mktemp)"
  {
    printf 'SOLANA_SETUP_REPO=%q\n' "$SOLANA_SETUP_REPO"
    printf 'SOLANA_SETUP_BRANCH=%q\n' "$SOLANA_SETUP_BRANCH"
    printf 'FD_VERSION=%q\n' "$FD_VERSION"
    printf 'FD_NETWORK=%q\n' "$FD_NETWORK"
    printf 'SSH_ALLOW_CIDR=%q\n' "$SSH_ALLOW_CIDR"
    printf 'FD_USER=%q\n' "${FD_USER:-ubuntu}"
    printf 'BAM_REGION=%q\n' "${BAM_REGION:-dallas}"
    printf 'SSH_PRIVATE_KEY_SHRED_AFTER_INSTALL=%q\n' "${SSH_PRIVATE_KEY_SHRED_AFTER_INSTALL:-false}"
    printf 'SSH_PRIVATE_KEY_FILE=%q\n' "/root/.ssh-secrets/cherry-bootstrap-key"
    printf 'TARGET_DISABLE_FIRE_UNTIL_KEYS=%q\n' "${TARGET_DISABLE_FIRE_UNTIL_KEYS:-true}"
    if [ -n "$extra_authorized_keys_file" ]; then
      printf 'TARGET_AUTHORIZED_KEYS_FILE=%q\n' "/root/.ssh-secrets/target-authorized-keys"
      printf 'TARGET_AUTHORIZED_KEYS_MODE=%q\n' "${CHERRY_TARGET_AUTHORIZED_KEYS_MODE:-keydrop}"
      printf 'TARGET_AUTHORIZED_KEYS_USER=%q\n' "${FD_USER:-ubuntu}"
      printf 'TARGET_KEYDROP_USER=%q\n' "${CHERRY_TARGET_KEYDROP_USER:-solana-keydrop}"
    fi
  } > "$bootstrap_env_file"

  echo "== upload bootstrap assets to $target =="
  ssh "${ssh_args[@]}" "$target" "${root_cmd}install -d -m 0700 /root/.ssh-secrets"
  scp "${ssh_args[@]}" "$repo_root/scripts/solana-cherry-target-bootstrap.sh" "$target:/tmp/solana-cherry-target-bootstrap.sh"
  scp "${ssh_args[@]}" "$repo_root/scripts/solana-cherry-target-tmux-runner.sh" "$target:/tmp/solana-cherry-target-tmux-runner.sh"
  scp "${ssh_args[@]}" "$repo_root/scripts/solana-cherry-target-tmux-start.sh" "$target:/tmp/solana-cherry-target-tmux-start.sh"
  scp "${ssh_args[@]}" "$repo_root/scripts/solana-target-keydrop-setup.sh" "$target:/tmp/solana-target-keydrop-setup.sh"
  scp "${ssh_args[@]}" "$bootstrap_env_file" "$target:/tmp/solana-cherry-bootstrap.env"
  scp "${ssh_args[@]}" "${CHERRY_SSH_KEY:?missing CHERRY_SSH_KEY}" "$target:/tmp/cherry-bootstrap-key"
  if [ -n "$extra_authorized_keys_file" ]; then
    scp "${ssh_args[@]}" "$extra_authorized_keys_file" "$target:/tmp/target-authorized-keys"
    extra_install=" && ${root_cmd}install -m 0600 /tmp/target-authorized-keys /root/.ssh-secrets/target-authorized-keys"
    extra_cleanup=" /tmp/target-authorized-keys"
  else
    extra_install=""
    extra_cleanup=""
  fi
  rm -f "$bootstrap_env_file"
  ssh "${ssh_args[@]}" "$target" "${root_cmd}install -m 0700 /tmp/solana-cherry-target-bootstrap.sh /root/solana-cherry-target-bootstrap.sh && ${root_cmd}install -m 0700 /tmp/solana-cherry-target-tmux-runner.sh /root/solana-cherry-target-tmux-runner.sh && ${root_cmd}install -m 0700 /tmp/solana-cherry-target-tmux-start.sh /root/solana-cherry-target-tmux-start.sh && ${root_cmd}install -m 0700 /tmp/solana-target-keydrop-setup.sh /root/solana-target-keydrop-setup.sh && ${root_cmd}install -m 0600 /tmp/solana-cherry-bootstrap.env /root/solana-cherry-bootstrap.env && ${root_cmd}install -m 0600 /tmp/cherry-bootstrap-key /root/.ssh-secrets/cherry-bootstrap-key${extra_install} && rm -f /tmp/solana-cherry-target-bootstrap.sh /tmp/solana-cherry-target-tmux-runner.sh /tmp/solana-cherry-target-tmux-start.sh /tmp/solana-target-keydrop-setup.sh /tmp/solana-cherry-bootstrap.env /tmp/cherry-bootstrap-key${extra_cleanup}"

  if [ "${CHERRY_BOOTSTRAP_TMUX:-true}" = "true" ]; then
    session="${CHERRY_BOOTSTRAP_SESSION:-solana-bootstrap}"
    status_file="${CHERRY_BOOTSTRAP_STATUS_FILE:-/root/solana-cherry-bootstrap.status}"
    tmux_log="${CHERRY_BOOTSTRAP_TMUX_LOG:-/root/solana-cherry-bootstrap.tmux.log}"
    echo "== run target bootstrap in tmux =="
    ssh "${ssh_args[@]}" "$target" "$root_env_cmd BOOTSTRAP_SESSION=$(remote_quote "$session") BOOTSTRAP_ENV_FILE=/root/solana-cherry-bootstrap.env BOOTSTRAP_STATUS_FILE=$(remote_quote "$status_file") BOOTSTRAP_TMUX_LOG=$(remote_quote "$tmux_log") BOOTSTRAP_FOLLOW=$(remote_quote "${CHERRY_BOOTSTRAP_FOLLOW:-true}") BOOTSTRAP_TIMEOUT_SECONDS=$(remote_quote "${CHERRY_BOOTSTRAP_TIMEOUT_SECONDS:-14400}") BOOTSTRAP_MONITOR_INTERVAL_SECONDS=$(remote_quote "${CHERRY_BOOTSTRAP_MONITOR_INTERVAL_SECONDS:-120}") BOOTSTRAP_RESTART_TMUX=$(remote_quote "${CHERRY_BOOTSTRAP_RESTART_TMUX:-false}") bash /root/solana-cherry-target-tmux-start.sh"
  else
    direct_script="set -a; . /root/solana-cherry-bootstrap.env; set +a; bash /root/solana-cherry-target-bootstrap.sh"
    echo "== run target bootstrap directly =="
    ssh "${ssh_args[@]}" "$target" "$root_env_cmd bash -lc $(remote_quote "$direct_script")"
  fi

  echo "== post-bootstrap verify =="
  ./scripts/solana-cherry-hotswap-guard.sh post-bootstrap-verify
  post_bootstrap_reboot_and_notify "$target" "$root_cmd"
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
