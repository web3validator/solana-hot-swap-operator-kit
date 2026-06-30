#!/usr/bin/env bash
set -euo pipefail

: "${SOLANA_SETUP_REPO:?missing SOLANA_SETUP_REPO}"
: "${SOLANA_SETUP_BRANCH:?missing SOLANA_SETUP_BRANCH}"
: "${FD_VERSION:?missing FD_VERSION}"
: "${FD_NETWORK:?missing FD_NETWORK}"
: "${SSH_ALLOW_CIDR:?missing SSH_ALLOW_CIDR}"
: "${SSH_PRIVATE_KEY_FILE:?missing SSH_PRIVATE_KEY_FILE}"

setup_dir="${SOLANA_SETUP_DIR:-/root/solana-validator-setup}"
log_path="/root/fire-full-setup-$(date -u +%Y%m%dT%H%M%SZ).log"

rm -rf "$setup_dir"
git clone "$SOLANA_SETUP_REPO" "$setup_dir"
cd "$setup_dir"
git checkout "$SOLANA_SETUP_BRANCH"

for required in \
  FD_SKIP_APT_UPGRADE \
  FD_SKIP_SYSTEMD_DAEMON_REEXEC \
  SSH_ALLOW_CIDR \
  SSH_PRIVATE_KEY_FILE \
  is_candidate_data_disk; do
  grep -q "$required" fire-full-setup.sh
 done

export FD_SKIP_APT_UPGRADE="${FD_SKIP_APT_UPGRADE:-true}"
export FD_SKIP_SYSTEMD_DAEMON_REEXEC="${FD_SKIP_SYSTEMD_DAEMON_REEXEC:-true}"
export SSH_ALLOW_CIDR
export FD_USER="${FD_USER:-ubuntu}"
export BAM_REGION="${BAM_REGION:-dallas}"
export SSH_PRIVATE_KEY_FILE
export SSH_PRIVATE_KEY_SHRED_AFTER_INSTALL="${SSH_PRIVATE_KEY_SHRED_AFTER_INSTALL:-false}"

bash fire-full-setup.sh "$FD_VERSION" "$FD_NETWORK" 2>&1 | tee "$log_path"
printf 'bootstrap_log=%s\n' "$log_path"
