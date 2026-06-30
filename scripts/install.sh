#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install_root="${INSTALL_ROOT:-/opt/solana-hot-swap-operator-kit}"
config_dir="${CONFIG_DIR:-/etc/solana-hotswap}"
run_user="${RUN_USER:-solana-hotswap}"
run_group="${RUN_GROUP:-solana-hotswap}"
service_name="${SERVICE_NAME:-solana-hotswap.service}"
apply=0
enable_service=0
create_env=0

usage() {
  printf '%s\n' \
    'Usage: scripts/install.sh [--dry-run] [--apply] [--enable] [--create-env]' \
    '' \
    'Installs the operator kit files, config example, and systemd unit template.' \
    'Default mode is --dry-run. No production service is started by this script.' \
    '' \
    'Environment overrides:' \
    '  INSTALL_ROOT=/opt/solana-hot-swap-operator-kit' \
    '  CONFIG_DIR=/etc/solana-hotswap' \
    '  RUN_USER=solana-hotswap' \
    '  RUN_GROUP=solana-hotswap' \
    '  SERVICE_NAME=solana-hotswap.service'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      apply=0
      ;;
    --apply)
      apply=1
      ;;
    --enable)
      enable_service=1
      ;;
    --create-env)
      create_env=1
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
  printf '+'
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

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 3
  fi
}

require_command rsync
require_command install
require_command systemctl

sudo_cmd=()
if [ "$(id -u)" -ne 0 ]; then
  require_command sudo
  sudo_cmd=(sudo)
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

if [ "$apply" -eq 0 ]; then
  echo "dry_run=true"
else
  echo "dry_run=false"
fi

if ! getent group "$run_group" >/dev/null 2>&1; then
  run "${sudo_cmd[@]}" groupadd --system "$run_group"
fi

if ! id "$run_user" >/dev/null 2>&1; then
  run "${sudo_cmd[@]}" useradd --system --gid "$run_group" --home-dir "$install_root" --shell /usr/sbin/nologin "$run_user"
fi

run "${sudo_cmd[@]}" install -d -m 0755 "$install_root"
run "${sudo_cmd[@]}" install -d -m 0700 "$config_dir"
run "${sudo_cmd[@]}" install -d -m 0750 -o "$run_user" -g "$run_group" "$install_root/runs"

run "${sudo_cmd[@]}" rsync -a --delete \
  --exclude .git \
  --exclude .env \
  --exclude '.env.*' \
  --exclude runs \
  --exclude __pycache__ \
  --exclude .pytest_cache \
  "$repo_root"/ "$install_root"/

run "${sudo_cmd[@]}" install -m 0600 "$repo_root/examples/env.example" "$config_dir/hotswap.env.example"
if [ "$create_env" -eq 1 ] && ! path_exists "$config_dir/hotswap.env"; then
  run "${sudo_cmd[@]}" install -m 0600 "$repo_root/examples/env.example" "$config_dir/hotswap.env"
fi
run "${sudo_cmd[@]}" install -m 0644 "$repo_root/systemd/solana-hotswap.service.example" "/etc/systemd/system/$service_name"
run "${sudo_cmd[@]}" systemctl daemon-reload

if [ "$enable_service" -eq 1 ]; then
  run "${sudo_cmd[@]}" systemctl enable "$service_name"
fi

echo "install_root=$install_root"
echo "config_example=$config_dir/hotswap.env.example"
echo "config=$config_dir/hotswap.env"
echo "service=/etc/systemd/system/$service_name"
echo "next=fill real values privately in $config_dir/hotswap.env, then run systemctl start $service_name"
