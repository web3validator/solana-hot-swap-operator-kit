#!/usr/bin/env bash
set -euo pipefail

mode="dry-run"
target_ip="${TARGET_IP:-}"
target_host="${TARGET_HOST:-}"
target_user="${TARGET_KEYDROP_USER:-solana-keydrop}"

usage() {
  printf '%s\n' \
    'Usage: scripts/solana-source-upload-keys.sh [--dry-run] [--execute] [--target-ip IP|--target-host USER@HOST] [TARGET_IP]' \
    '' \
    'Run manually on the current source/main-sol validator host.' \
    'Uploads validator keypairs directly to a Cherry target restricted keydrop user.' \
    'The operator/OpenClaw host should not run this script and should never handle these key files.' \
    '' \
    'Default local files:' \
    '  STAKED_IDENTITY_FILE=/mnt/ramdisk/staked-identity.json' \
    '  SECONDARY_UNSTAKED_IDENTITY_FILE=/mnt/ramdisk/secondary-unstaked-identity.json' \
    '  VOTE_KEYPAIR_FILE=/mnt/ramdisk/vote-account-keypair.json' \
    '' \
    'Target:' \
    '  TARGET_IP=target-ip creates TARGET_HOST=solana-keydrop@target-ip' \
    '  TARGET_HOST=solana-keydrop@target-ip can be used instead' \
    '  TARGET_KEYDROP_USER=solana-keydrop' \
    '' \
    'Execute gate:' \
    '  CONFIRM_SOLANA_KEY_UPLOAD=I_CONFIRM_SOLANA_KEY_UPLOAD scripts/solana-source-upload-keys.sh --execute --target-ip IP' \
    '' \
    'No key contents are printed. Public target IPs must be passed at runtime, not committed to git.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      mode="dry-run"
      ;;
    --execute)
      mode="execute"
      ;;
    --target-ip)
      shift
      target_ip="${1:?missing value for --target-ip}"
      ;;
    --target-host)
      shift
      target_host="${1:?missing value for --target-host}"
      ;;
    --target-user)
      shift
      target_user="${1:?missing value for --target-user}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$target_ip" ]; then
        echo "BLOCKER: target IP provided more than once" >&2
        exit 2
      fi
      target_ip="$1"
      ;;
  esac
  shift
done

if [ -z "$target_host" ]; then
  if [ -z "$target_ip" ]; then
    echo "BLOCKER: TARGET_IP, TARGET_HOST, --target-ip, --target-host, or positional TARGET_IP is required" >&2
    exit 2
  fi
  target_host="$target_user@$target_ip"
fi

staked_identity_file="${STAKED_IDENTITY_FILE:-/mnt/ramdisk/staked-identity.json}"
secondary_unstaked_identity_file="${SECONDARY_UNSTAKED_IDENTITY_FILE:-/mnt/ramdisk/secondary-unstaked-identity.json}"
vote_keypair_file="${VOTE_KEYPAIR_FILE:-/mnt/ramdisk/vote-account-keypair.json}"
connect_timeout="${SSH_CONNECT_TIMEOUT:-8}"
known_hosts="${TARGET_KEYDROP_KNOWN_HOSTS:-${SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}}"
ssh_key="${TARGET_KEYDROP_SSH_KEY:-${SSH_KEY:-}}"

ssh_args=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$known_hosts"
  -o ConnectTimeout="$connect_timeout"
)
if [ -n "$ssh_key" ]; then
  ssh_args=(-i "$ssh_key" "${ssh_args[@]}")
fi

require_file() {
  if [ ! -s "$1" ]; then
    echo "BLOCKER: missing or empty keypair file: $1" >&2
    exit 3
  fi
}

validate_keypair_json() {
  python3 -c 'import json, sys
path = sys.argv[1]
with open(path) as handle:
    data = json.load(handle)
if not isinstance(data, list) or len(data) not in (32, 64):
    raise SystemExit(f"BLOCKER: {path} does not look like a Solana keypair JSON array")
if any(not isinstance(item, int) or item < 0 or item > 255 for item in data):
    raise SystemExit(f"BLOCKER: {path} has non-byte values")' "$1"
}

warn_if_broad_permissions() {
  path="$1"
  if mode_bits="$(stat -c '%a' "$path" 2>/dev/null)"; then
    if [ $((8#$mode_bits & 077)) -ne 0 ]; then
      printf 'WARN: broad permissions on %s: %s\n' "$path" "$mode_bits" >&2
    fi
  fi
}

for file in "$staked_identity_file" "$secondary_unstaked_identity_file" "$vote_keypair_file"; do
  require_file "$file"
  validate_keypair_json "$file"
  warn_if_broad_permissions "$file"
done

printf 'upload_mode=%s\n' "$mode"
printf 'target_host=%s\n' "$target_host"
printf 'staked_identity_file=%s\n' "$staked_identity_file"
printf 'secondary_unstaked_identity_file=%s\n' "$secondary_unstaked_identity_file"
printf 'vote_keypair_file=%s\n' "$vote_keypair_file"
printf 'known_hosts=%s\n' "$known_hosts"
printf 'execute=%s\n' "$([ "$mode" = "execute" ] && printf 1 || printf 0)"

printf '\n== planned upload ==\n'
printf 'scp -p %q %q %q %q:\n' \
  "$staked_identity_file" \
  "$secondary_unstaked_identity_file" \
  "$vote_keypair_file" \
  "$target_host"

if [ "$mode" != "execute" ]; then
  echo "dry_run=true"
  echo "No keypairs uploaded."
  exit 0
fi

if [ "${CONFIRM_SOLANA_KEY_UPLOAD:-}" != "I_CONFIRM_SOLANA_KEY_UPLOAD" ]; then
  echo "BLOCKER: set CONFIRM_SOLANA_KEY_UPLOAD=I_CONFIRM_SOLANA_KEY_UPLOAD before --execute" >&2
  exit 4
fi

mkdir -p "$(dirname "$known_hosts")"
touch "$known_hosts"
chmod 0600 "$known_hosts" 2>/dev/null || true

echo "== upload keypairs to restricted keydrop target =="
scp -p "${ssh_args[@]}" \
  "$staked_identity_file" \
  "$secondary_unstaked_identity_file" \
  "$vote_keypair_file" \
  "$target_host:"

echo "solana_key_upload=ok"
