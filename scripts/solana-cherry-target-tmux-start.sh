#!/usr/bin/env bash
set -euo pipefail

session="${BOOTSTRAP_SESSION:-solana-bootstrap}"
env_file="${BOOTSTRAP_ENV_FILE:-/root/solana-cherry-bootstrap.env}"
status_file="${BOOTSTRAP_STATUS_FILE:-/root/solana-cherry-bootstrap.status}"
log_file="${BOOTSTRAP_TMUX_LOG:-/root/solana-cherry-bootstrap.tmux.log}"
follow="${BOOTSTRAP_FOLLOW:-true}"
timeout_seconds="${BOOTSTRAP_TIMEOUT_SECONDS:-14400}"
interval_seconds="${BOOTSTRAP_MONITOR_INTERVAL_SECONDS:-120}"
restart_existing="${BOOTSTRAP_RESTART_TMUX:-false}"

if [ ! -r "$env_file" ]; then
  echo "BLOCKER: cannot read bootstrap env file: $env_file" >&2
  exit 2
fi

if ! command -v tmux >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y tmux
fi

if tmux has-session -t "$session" 2>/dev/null; then
  if [ "$restart_existing" = "true" ]; then
    tmux kill-session -t "$session"
  else
    echo "BLOCKER: tmux session already exists: $session" >&2
    echo "Attach: tmux attach -t $session" >&2
    exit 4
  fi
fi

rm -f "$status_file"
install -d -m 0700 "$(dirname "$status_file")" "$(dirname "$log_file")"
runner_cmd="$(printf 'BOOTSTRAP_STATUS_FILE=%q BOOTSTRAP_TMUX_LOG=%q bash /root/solana-cherry-target-tmux-runner.sh %q' "$status_file" "$log_file" "$env_file")"
tmux new-session -d -s "$session" "$runner_cmd"

printf 'bootstrap_tmux_session=%s\n' "$session"
printf 'bootstrap_status_file=%s\n' "$status_file"
printf 'bootstrap_tmux_log=%s\n' "$log_file"
printf 'bootstrap_attach_command=tmux attach -t %s\n' "$session"

if [ "$follow" != "true" ]; then
  echo "bootstrap_started_detached=true"
  exit 0
fi

deadline=$(( $(date +%s) + timeout_seconds ))
while [ "$(date +%s)" -le "$deadline" ]; do
  if [ -f "$status_file" ]; then
    cat "$status_file"
    if [ -f "$log_file" ]; then
      echo "== bootstrap log tail =="
      tail -120 "$log_file" || true
    fi
    rc="$(awk -F= '/^exit_code=/ {print $2; exit}' "$status_file")"
    if [ -z "$rc" ]; then
      echo "BLOCKER: bootstrap status file has no exit_code" >&2
      exit 6
    fi
    exit "$rc"
  fi

  if ! tmux has-session -t "$session" 2>/dev/null; then
    echo "BLOCKER: tmux session ended without status file: $session" >&2
    if [ -f "$log_file" ]; then
      echo "== bootstrap log tail =="
      tail -120 "$log_file" || true
    fi
    exit 7
  fi

  echo "bootstrap_session=running"
  if [ -f "$log_file" ]; then
    echo "== bootstrap log tail =="
    tail -80 "$log_file" || true
  fi
  sleep "$interval_seconds"
done

echo "BLOCKER: bootstrap tmux session did not finish within ${timeout_seconds}s" >&2
echo "Attach on target: tmux attach -t $session" >&2
exit 8
