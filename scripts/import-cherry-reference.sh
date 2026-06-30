#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
reference_host="${REFERENCE_HOST:-}"
reference_hotswap_env="${REFERENCE_HOTSWAP_ENV:-/home/ubuntu/solana-validator-hotswap/.env}"
reference_cherry_env="${REFERENCE_CHERRY_ENV:-/home/ubuntu/.config/cherry/provider.env}"
reference_cherry_ssh_key="${REFERENCE_CHERRY_SSH_KEY:-/home/ubuntu/.ssh/cherry_solana_fd_20260524}"
reference_attempts_dir="${REFERENCE_ATTEMPTS_DIR:-/home/ubuntu/.openclaw/workspace/memory/runlogs/cherry-attempts}"
local_env="${LOCAL_HOTSWAP_ENV:-/etc/solana-hotswap/hotswap.env}"
local_cherry_ssh_key="${LOCAL_CHERRY_SSH_KEY:-/home/sol/.ssh/cherry_solana_fd_20260524}"
local_user="${LOCAL_RUN_USER:-sol}"
local_group="${LOCAL_RUN_GROUP:-sol}"
run_dir="${HOTSWAP_RUN_DIR:-/opt/solana-hot-swap-operator-kit/runs/cherry-attempts}"
known_hosts="${CHERRY_KNOWN_HOSTS:-/opt/solana-hot-swap-operator-kit/runs/known_hosts}"
apply=0

usage() {
  printf '%s\n' \
    'Usage: REFERENCE_HOST=user@host scripts/import-cherry-reference.sh [--dry-run] [--apply]' \
    '' \
    'Imports private Cherry provider config, latest Cherry order metadata, and the matching Cherry SSH key from a reference host.' \
    'Secrets are written only to /etc/solana-hotswap/hotswap.env and the local SSH key path.' \
    '' \
    'Environment overrides:' \
    '  REFERENCE_HOST=user@host              required' \
    '  REFERENCE_HOTSWAP_ENV=/home/ubuntu/solana-validator-hotswap/.env' \
    '  REFERENCE_CHERRY_ENV=/home/ubuntu/.config/cherry/provider.env' \
    '  REFERENCE_CHERRY_SSH_KEY=/home/ubuntu/.ssh/cherry_solana_fd_20260524' \
    '  REFERENCE_ATTEMPTS_DIR=/home/ubuntu/.openclaw/workspace/memory/runlogs/cherry-attempts' \
    '  LOCAL_HOTSWAP_ENV=/etc/solana-hotswap/hotswap.env' \
    '  LOCAL_CHERRY_SSH_KEY=/home/sol/.ssh/cherry_solana_fd_20260524'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      apply=0
      ;;
    --apply)
      apply=1
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

if [ -z "$reference_host" ]; then
  echo "BLOCKER: REFERENCE_HOST is required" >&2
  usage >&2
  exit 2
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "BLOCKER: missing required command: $1" >&2
    exit 3
  fi
}

require_command ssh
require_command python3
require_command install
require_command tar

sudo_cmd=()
if [ "$(id -u)" -ne 0 ]; then
  require_command sudo
  sudo_cmd=(sudo -n)
fi

if ! id "$local_user" >/dev/null 2>&1; then
  echo "BLOCKER: local user does not exist: $local_user" >&2
  exit 3
fi
if ! getent group "$local_group" >/dev/null 2>&1; then
  echo "BLOCKER: local group does not exist: $local_group" >&2
  exit 3
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

ssh_retry() {
  attempt=1
  while [ "$attempt" -le 6 ]; do
    if ssh -o BatchMode=yes -o ConnectTimeout=8 "$reference_host" "$@"; then
      return 0
    fi
    echo "WARN: SSH attempt $attempt failed for $reference_host; retrying..." >&2
    sleep 5
    attempt=$((attempt + 1))
  done
  return 1
}

ssh_capture_retry() {
  command_text="$1"
  output_path="$2"
  attempt=1
  while [ "$attempt" -le 6 ]; do
    attempt_path="$output_path.attempt"
    rm -f "$attempt_path"
    if ssh -o BatchMode=yes -o ConnectTimeout=8 "$reference_host" "$command_text" > "$attempt_path"; then
      mv "$attempt_path" "$output_path"
      return 0
    fi
    rm -f "$attempt_path"
    echo "WARN: SSH capture attempt $attempt failed for $reference_host; retrying..." >&2
    sleep 5
    attempt=$((attempt + 1))
  done
  return 1
}

if ! ssh_retry true; then
  echo "BLOCKER: cannot reach reference host over SSH: $reference_host" >&2
  exit 4
fi

latest_response="$(ssh_retry "find '$reference_attempts_dir' -maxdepth 1 -type f -name 'cherry-create-*.response.json' -size +0c -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d ' ' -f 2-")"
if [ -z "$latest_response" ]; then
  echo "BLOCKER: no non-empty Cherry create response found in $reference_attempts_dir on $reference_host" >&2
  exit 4
fi
latest_payload="${latest_response%.response.json}.json"

bundle_command="set -eu; tmp=\$(mktemp -d); cleanup() { rm -rf \"\$tmp\"; }; trap cleanup EXIT; cp '$reference_hotswap_env' \"\$tmp/reference.env\"; cp '$reference_cherry_env' \"\$tmp/provider.env\"; cp '$reference_cherry_ssh_key' \"\$tmp/cherry_ssh_key\"; if [ -f '$reference_cherry_ssh_key.pub' ]; then cp '$reference_cherry_ssh_key.pub' \"\$tmp/cherry_ssh_key.pub\"; fi; cp '$latest_payload' \"\$tmp/payload.json\"; cp '$latest_response' \"\$tmp/response.json\"; tar -C \"\$tmp\" -cf - ."
if ! ssh_capture_retry "$bundle_command" "$tmp_dir/reference-bundle.tar"; then
  echo "BLOCKER: failed to stream reference bundle from $reference_host" >&2
  exit 4
fi
tar -C "$tmp_dir" -xf "$tmp_dir/reference-bundle.tar"
chmod 0600 "$tmp_dir/reference.env" "$tmp_dir/provider.env" "$tmp_dir/cherry_ssh_key" "$tmp_dir/payload.json" "$tmp_dir/response.json"
if [ -f "$tmp_dir/cherry_ssh_key.pub" ]; then
  chmod 0644 "$tmp_dir/cherry_ssh_key.pub"
fi

existing_env_arg=()
if [ -e "$local_env" ]; then
  existing_env_arg=(--existing-env "$local_env")
elif [ "${#sudo_cmd[@]}" -gt 0 ] && "${sudo_cmd[@]}" test -e "$local_env" >/dev/null 2>&1; then
  "${sudo_cmd[@]}" cp "$local_env" "$tmp_dir/existing.env"
  "${sudo_cmd[@]}" chown "$(id -un)":"$(id -gn)" "$tmp_dir/existing.env"
  chmod 0600 "$tmp_dir/existing.env"
  existing_env_arg=(--existing-env "$tmp_dir/existing.env")
fi

python3 "$repo_root/scripts/import_cherry_reference.py" \
  --reference-env "$tmp_dir/reference.env" \
  --provider-env "$tmp_dir/provider.env" \
  --payload-json "$tmp_dir/payload.json" \
  --response-json "$tmp_dir/response.json" \
  "${existing_env_arg[@]}" \
  --output "$tmp_dir/hotswap.env" \
  --local-cherry-ssh-key "$local_cherry_ssh_key" \
  --run-dir "$run_dir" \
  --known-hosts "$known_hosts"

printf '%s\n' "reference_payload=$latest_payload" "reference_response=$latest_response" "local_env=$local_env" "local_cherry_ssh_key=$local_cherry_ssh_key"

if [ "$apply" -eq 0 ]; then
  echo "dry_run=true"
  echo "next=rerun with --apply to install private env and SSH key"
  exit 0
fi

backup=""
if [ -e "$local_env" ] || { [ "${#sudo_cmd[@]}" -gt 0 ] && "${sudo_cmd[@]}" test -e "$local_env" >/dev/null 2>&1; }; then
  backup="$local_env.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  "${sudo_cmd[@]}" cp "$local_env" "$backup"
fi

"${sudo_cmd[@]}" install -d -m 0700 "$(dirname "$local_env")"
"${sudo_cmd[@]}" install -d -m 0700 -o "$local_user" -g "$local_group" "$(dirname "$local_cherry_ssh_key")"
"${sudo_cmd[@]}" install -d -m 0750 -o "$local_user" -g "$local_group" "$run_dir"
"${sudo_cmd[@]}" install -m 0600 "$tmp_dir/hotswap.env" "$local_env"
"${sudo_cmd[@]}" install -m 0600 -o "$local_user" -g "$local_group" "$tmp_dir/cherry_ssh_key" "$local_cherry_ssh_key"
if [ -f "$tmp_dir/cherry_ssh_key.pub" ]; then
  "${sudo_cmd[@]}" install -m 0644 -o "$local_user" -g "$local_group" "$tmp_dir/cherry_ssh_key.pub" "$local_cherry_ssh_key.pub"
fi

if [ -n "$backup" ]; then
  echo "backup=$backup"
fi
echo "installed_private_env=$local_env"
echo "installed_cherry_ssh_key=$local_cherry_ssh_key"
echo "next=scripts/cherry-mainnet-one-shot.sh --plan"
