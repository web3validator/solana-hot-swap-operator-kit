#!/usr/bin/env bash
set -euo pipefail

env_file="${1:-/root/solana-cherry-bootstrap.env}"
status_file="${BOOTSTRAP_STATUS_FILE:-/root/solana-cherry-bootstrap.status}"
log_file="${BOOTSTRAP_TMUX_LOG:-/root/solana-cherry-bootstrap.tmux.log}"

if [ ! -r "$env_file" ]; then
  echo "BLOCKER: cannot read bootstrap env file: $env_file" >&2
  exit 2
fi

install -d -m 0700 "$(dirname "$status_file")" "$(dirname "$log_file")"
rm -f "$status_file"
: > "$log_file"
chmod 0600 "$log_file"

set -a
. "$env_file"
set +a

printf 'bootstrap_started_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$log_file"
set +e
bash /root/solana-cherry-target-bootstrap.sh 2>&1 | tee -a "$log_file"
rc="${PIPESTATUS[0]}"
set -e
{
  printf 'exit_code=%s\n' "$rc"
  printf 'bootstrap_finished_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'bootstrap_log=%s\n' "$log_file"
} > "$status_file"
chmod 0600 "$status_file"
exit "$rc"
