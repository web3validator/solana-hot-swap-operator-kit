#!/usr/bin/env bash
set -euo pipefail

mode="dry-run"

usage() {
  printf '%s\n' \
    'Usage: scripts/solana-identity-handoff.sh [--dry-run] [--execute]' \
    '' \
    'Run on the validator host that currently owns the staked identity.' \
    'It switches the local validator to a secondary identity, copies tower files to a remote host,' \
    'then switches the remote validator to the staked identity with --require-tower.' \
    '' \
    'Required environment:' \
    '  REMOTE_HOST=ubuntu@target-host' \
    '' \
    'Default paths:' \
    '  LOCAL_FDCTL=/home/ubuntu/firedancer/build/native/gcc/bin/fdctl' \
    '  LOCAL_CONFIG=/home/ubuntu/solana/config.toml' \
    '  LOCAL_SECONDARY_IDENTITY=/mnt/ramdisk/secondary-unstaked-identity.json' \
    '  LOCAL_LEDGER_DIR=/mnt/ledger' \
    '  REMOTE_FDCTL=/home/ubuntu/firedancer/build/native/gcc/bin/fdctl' \
    '  REMOTE_CONFIG=/home/ubuntu/solana/config.toml' \
    '  REMOTE_STAKED_IDENTITY=/mnt/ramdisk/staked-identity.json' \
    '  REMOTE_LEDGER_DIR=/mnt/ledger' \
    '' \
    'Execute gate:' \
    '  CONFIRM_SOLANA_IDENTITY_HANDOFF=I_CONFIRM_IDENTITY_HANDOFF scripts/solana-identity-handoff.sh --execute'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      mode="dry-run"
      ;;
    --execute)
      mode="execute"
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

require() {
  if [ -z "${!1:-}" ]; then
    echo "BLOCKER: missing required environment: $1" >&2
    exit 2
  fi
}

quote() {
  printf '%q' "$1"
}

LOCAL_FDCTL="${LOCAL_FDCTL:-/home/ubuntu/firedancer/build/native/gcc/bin/fdctl}"
LOCAL_CONFIG="${LOCAL_CONFIG:-/home/ubuntu/solana/config.toml}"
LOCAL_SECONDARY_IDENTITY="${LOCAL_SECONDARY_IDENTITY:-/mnt/ramdisk/secondary-unstaked-identity.json}"
LOCAL_LEDGER_DIR="${LOCAL_LEDGER_DIR:-/mnt/ledger}"
REMOTE_FDCTL="${REMOTE_FDCTL:-/home/ubuntu/firedancer/build/native/gcc/bin/fdctl}"
REMOTE_CONFIG="${REMOTE_CONFIG:-/home/ubuntu/solana/config.toml}"
REMOTE_STAKED_IDENTITY="${REMOTE_STAKED_IDENTITY:-/mnt/ramdisk/staked-identity.json}"
REMOTE_LEDGER_DIR="${REMOTE_LEDGER_DIR:-/mnt/ledger}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-8}"

require REMOTE_HOST

if [ ! -x "$LOCAL_FDCTL" ]; then
  echo "BLOCKER: local fdctl is not executable: $LOCAL_FDCTL" >&2
  exit 3
fi
if [ ! -r "$LOCAL_CONFIG" ]; then
  echo "BLOCKER: local config is not readable: $LOCAL_CONFIG" >&2
  exit 3
fi
if [ ! -s "$LOCAL_SECONDARY_IDENTITY" ]; then
  echo "BLOCKER: local secondary identity is missing or empty: $LOCAL_SECONDARY_IDENTITY" >&2
  exit 3
fi
if [ ! -d "$LOCAL_LEDGER_DIR" ]; then
  echo "BLOCKER: local ledger dir is missing: $LOCAL_LEDGER_DIR" >&2
  exit 3
fi

shopt -s nullglob
tower_files=("$LOCAL_LEDGER_DIR"/tower*)
shopt -u nullglob
if [ "${#tower_files[@]}" -lt 1 ]; then
  echo "BLOCKER: no tower files found in $LOCAL_LEDGER_DIR" >&2
  exit 3
fi

remote_check="test -x $(quote "$REMOTE_FDCTL") && test -r $(quote "$REMOTE_CONFIG") && test -s $(quote "$REMOTE_STAKED_IDENTITY") && test -d $(quote "$REMOTE_LEDGER_DIR")"
if ! ssh -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" "$REMOTE_HOST" "$remote_check"; then
  echo "BLOCKER: remote preflight failed on $REMOTE_HOST" >&2
  echo "Required remote paths:" >&2
  printf '  REMOTE_FDCTL=%s\n' "$REMOTE_FDCTL" >&2
  printf '  REMOTE_CONFIG=%s\n' "$REMOTE_CONFIG" >&2
  printf '  REMOTE_STAKED_IDENTITY=%s\n' "$REMOTE_STAKED_IDENTITY" >&2
  printf '  REMOTE_LEDGER_DIR=%s\n' "$REMOTE_LEDGER_DIR" >&2
  exit 4
fi

printf 'handoff_mode=%s\n' "$mode"
printf 'remote_host=%s\n' "$REMOTE_HOST"
printf 'local_fdctl=%s\n' "$LOCAL_FDCTL"
printf 'local_config=%s\n' "$LOCAL_CONFIG"
printf 'local_secondary_identity=%s\n' "$LOCAL_SECONDARY_IDENTITY"
printf 'local_tower_count=%s\n' "${#tower_files[@]}"
printf 'remote_fdctl=%s\n' "$REMOTE_FDCTL"
printf 'remote_config=%s\n' "$REMOTE_CONFIG"
printf 'remote_staked_identity=%s\n' "$REMOTE_STAKED_IDENTITY"
printf 'remote_ledger_dir=%s\n' "$REMOTE_LEDGER_DIR"

printf '\n== planned commands ==\n'
printf '%q set-identity --config %q %q\n' "$LOCAL_FDCTL" "$LOCAL_CONFIG" "$LOCAL_SECONDARY_IDENTITY"
printf 'scp -p %s %q:%q/\n' "${tower_files[*]}" "$REMOTE_HOST" "$REMOTE_LEDGER_DIR"
remote_set_identity="$(quote "$REMOTE_FDCTL") set-identity --config $(quote "$REMOTE_CONFIG") $(quote "$REMOTE_STAKED_IDENTITY") --require-tower"
printf 'ssh %q %q\n' "$REMOTE_HOST" "$remote_set_identity"

if [ "$mode" != "execute" ]; then
  echo "dry_run=true"
  echo "No identities changed and no tower files copied."
  exit 0
fi

if [ "${CONFIRM_SOLANA_IDENTITY_HANDOFF:-}" != "I_CONFIRM_IDENTITY_HANDOFF" ]; then
  echo "BLOCKER: set CONFIRM_SOLANA_IDENTITY_HANDOFF=I_CONFIRM_IDENTITY_HANDOFF before --execute" >&2
  exit 5
fi

echo "== local set-identity to secondary =="
"$LOCAL_FDCTL" set-identity --config "$LOCAL_CONFIG" "$LOCAL_SECONDARY_IDENTITY"

echo "== copy tower files to remote =="
scp -p "${tower_files[@]}" "$REMOTE_HOST:$REMOTE_LEDGER_DIR/"

echo "== remote set-identity to staked with --require-tower =="
ssh -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" "$REMOTE_HOST" "$remote_set_identity"

echo "identity_handoff_complete=true"
