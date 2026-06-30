#!/usr/bin/env bash
set -euo pipefail

env_file="${HOTSWAP_ENV_FILE:-/etc/solana-hotswap/hotswap.env}"
do_stage=0
do_start=0
do_wait_sync=0
execute=0

usage() {
  printf '%s\n' \
    'Usage: scripts/solana-target-stage-start-sync.sh [--dry-run] [--execute] [--stage-keys] [--start] [--wait-sync] [--all]' \
    '' \
    'Stages validator keypairs on a bootstrapped Cherry target, starts fire.service, and optionally waits for sync.' \
    'Default is dry-run. --execute requires CONFIRM_TARGET_STAGE_START=I_CONFIRM_TARGET_STAGE_START.' \
    '' \
    'Target env:' \
    '  TARGET_HOST=ubuntu@target or SERVER_IP=target-ip' \
    '  CHERRY_SSH_KEY=/path/to/private-key' \
    '' \
    'Required for --stage-keys:' \
    '  STAKED_IDENTITY_FILE=/path/to/staked-identity.json' \
    '  SECONDARY_UNSTAKED_IDENTITY_FILE=/path/to/secondary-unstaked-identity.json' \
    '  VOTE_KEYPAIR_FILE=/path/to/vote-account-keypair.json' \
    '' \
    'Defaults:' \
    '  TARGET_KEYS_DIR=/home/ubuntu/keys' \
    '  TARGET_SERVICE=fire' \
    '  TARGET_SYNC_CHECK_COMMAND="solana catchup --our-localhost --url https://api.mainnet-beta.solana.com"'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      execute=0
      ;;
    --execute)
      execute=1
      ;;
    --stage-keys)
      do_stage=1
      ;;
    --start)
      do_start=1
      ;;
    --wait-sync)
      do_wait_sync=1
      ;;
    --all)
      do_stage=1
      do_start=1
      do_wait_sync=1
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

if [ -r "$env_file" ]; then
  set -a
  . "$env_file"
  set +a
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

target_host="${TARGET_HOST:-}"
if [ -z "$target_host" ] && [ -n "${SERVER_IP:-}" ]; then
  target_host="ubuntu@$SERVER_IP"
fi
if [ -z "$target_host" ]; then
  echo "BLOCKER: TARGET_HOST or SERVER_IP is required" >&2
  exit 2
fi

ssh_key="${TARGET_SSH_KEY:-${CHERRY_SSH_KEY:-}}"
known_hosts="${CHERRY_KNOWN_HOSTS:-runs/known_hosts}"
connect_timeout="${SSH_CONNECT_TIMEOUT:-8}"
target_keys_dir="${TARGET_KEYS_DIR:-/home/ubuntu/keys}"
target_service="${TARGET_SERVICE:-fire}"
sync_timeout="${TARGET_SYNC_TIMEOUT_SECONDS:-21600}"
sync_interval="${TARGET_SYNC_INTERVAL_SECONDS:-120}"
sync_cmd="${TARGET_SYNC_CHECK_COMMAND:-/home/ubuntu/.local/share/solana/install/active_release/bin/solana catchup --our-localhost --url https://api.mainnet-beta.solana.com}"

ssh_args=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts" -o ConnectTimeout="$connect_timeout")
if [ -n "$ssh_key" ]; then
  ssh_args=(-i "$ssh_key" "${ssh_args[@]}")
fi

notify() {
  HOTSWAP_ENV_FILE="$env_file" "$repo_root/scripts/notify-telegram.sh" --message "$1" || true
}

remote_quote() {
  printf '%q' "$1"
}

require_file() {
  if [ ! -s "$1" ]; then
    echo "BLOCKER: missing or empty file: $1" >&2
    exit 3
  fi
}

if [ "$do_stage" -eq 1 ] && [ "$execute" -eq 1 ]; then
  : "${STAKED_IDENTITY_FILE:?missing STAKED_IDENTITY_FILE}"
  : "${SECONDARY_UNSTAKED_IDENTITY_FILE:?missing SECONDARY_UNSTAKED_IDENTITY_FILE}"
  : "${VOTE_KEYPAIR_FILE:?missing VOTE_KEYPAIR_FILE}"
  require_file "$STAKED_IDENTITY_FILE"
  require_file "$SECONDARY_UNSTAKED_IDENTITY_FILE"
  require_file "$VOTE_KEYPAIR_FILE"
fi

printf 'target_host=%s\n' "$target_host"
printf 'target_keys_dir=%s\n' "$target_keys_dir"
printf 'target_service=%s\n' "$target_service"
printf 'staked_identity_file=%s\n' "${STAKED_IDENTITY_FILE:-<unset>}"
printf 'secondary_unstaked_identity_file=%s\n' "${SECONDARY_UNSTAKED_IDENTITY_FILE:-<unset>}"
printf 'vote_keypair_file=%s\n' "${VOTE_KEYPAIR_FILE:-<unset>}"
printf 'stage_keys=%s\n' "$do_stage"
printf 'start_service=%s\n' "$do_start"
printf 'wait_sync=%s\n' "$do_wait_sync"
printf 'execute=%s\n' "$execute"

if [ "$execute" -eq 0 ]; then
  echo "dry_run=true"
  echo "No keypairs copied and no service started."
  exit 0
fi

if [ "${CONFIRM_TARGET_STAGE_START:-}" != "I_CONFIRM_TARGET_STAGE_START" ]; then
  echo "BLOCKER: set CONFIRM_TARGET_STAGE_START=I_CONFIRM_TARGET_STAGE_START before --execute" >&2
  exit 4
fi

if [ "$do_stage" -eq 1 ]; then
  echo "== stage keypairs on target =="
  ssh "${ssh_args[@]}" "$target_host" "install -d -m 0700 $(remote_quote "$target_keys_dir")"
  scp "${ssh_args[@]}" "$STAKED_IDENTITY_FILE" "$target_host:$target_keys_dir/staked-identity.json"
  scp "${ssh_args[@]}" "$SECONDARY_UNSTAKED_IDENTITY_FILE" "$target_host:$target_keys_dir/secondary-unstaked-identity.json"
  scp "${ssh_args[@]}" "$VOTE_KEYPAIR_FILE" "$target_host:$target_keys_dir/vote-account-keypair.json"
  ssh "${ssh_args[@]}" "$target_host" "chmod 0600 $(remote_quote "$target_keys_dir")/*.json && /home/ubuntu/setup-ramdisk-keys.sh && find /mnt/ramdisk -maxdepth 1 -type f -name '*.json' -printf '%f staged\\n'"
  notify "Cherry target keypairs staged on $target_host. Ready to start ${target_service}."
fi

if [ "$do_start" -eq 1 ]; then
  echo "== start target service =="
  ssh "${ssh_args[@]}" "$target_host" "sudo -n systemctl enable $(remote_quote "$target_service") sync-monitor >/dev/null 2>&1 || true; sudo -n systemctl start $(remote_quote "$target_service") && sudo -n systemctl is-active $(remote_quote "$target_service")"
  notify "Cherry target ${target_service} started on $target_host. Waiting for sync if requested."
fi

if [ "$do_wait_sync" -eq 1 ]; then
  echo "== wait target sync =="
  deadline=$(( $(date +%s) + sync_timeout ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    if ssh "${ssh_args[@]}" "$target_host" "sudo -n systemctl is-active $(remote_quote "$target_service") >/dev/null && bash -lc $(remote_quote "$sync_cmd")"; then
      echo "target_sync=ok"
      notify "Cherry target appears synced/caught up on $target_host. Ready for identity handoff dry-run."
      exit 0
    fi
    echo "target_sync=pending"
    sleep "$sync_interval"
  done
  notify "Cherry target sync wait timed out on $target_host. Inspect service logs before handoff."
  echo "BLOCKER: target did not pass sync check within ${sync_timeout}s" >&2
  exit 5
fi

notify "Cherry target stage/start operation complete on $target_host."
