#!/usr/bin/env bash
set -euo pipefail

env_file="${HOTSWAP_ENV_FILE:-/etc/solana-hotswap/hotswap.env}"
message=""

usage() {
  printf '%s\n' \
    'Usage: scripts/notify-telegram.sh --message TEXT' \
    '' \
    'Loads HOTSWAP_ENV_FILE and sends TEXT to Telegram if configured.' \
    'Required private env for sending:' \
    '  TELEGRAM_CHAT_ID=...' \
    '  TELEGRAM_BOT_TOKEN=... or TELEGRAM_BOT_TOKEN_FILE=...'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --message)
      message="${2:-}"
      shift
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

if [ -z "$message" ]; then
  echo "BLOCKER: --message is required" >&2
  exit 2
fi

if [ -r "$env_file" ]; then
  set -a
  . "$env_file"
  set +a
fi

if [ "${HOTSWAP_NOTIFY_TELEGRAM:-true}" != "true" ]; then
  echo "telegram_notify=disabled"
  exit 0
fi

chat_id="${TELEGRAM_CHAT_ID:-${TG_CHAT_ID:-}}"
token="${TELEGRAM_BOT_TOKEN:-${TG_BOT_TOKEN:-}}"
token_file="${TELEGRAM_BOT_TOKEN_FILE:-${TG_BOT_TOKEN_FILE:-}}"
if [ -z "$token" ] && [ -n "$token_file" ] && [ -r "$token_file" ]; then
  token="$(tr -d '\n\r' < "$token_file")"
fi

if [ -z "$chat_id" ] || [ -z "$token" ]; then
  echo "telegram_notify=skipped_missing_config" >&2
  if [ "${HOTSWAP_NOTIFY_REQUIRED:-false}" = "true" ]; then
    exit 3
  fi
  exit 0
fi

curl -fsS \
  --data-urlencode "chat_id=$chat_id" \
  --data-urlencode "text=$message" \
  "https://api.telegram.org/bot${token}/sendMessage" >/dev/null

echo "telegram_notify=sent"
