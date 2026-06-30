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

install_admin_authorized_keys() {
  target_user="${TARGET_AUTHORIZED_KEYS_USER:-${FD_USER:-ubuntu}}"
  for user in root "$target_user"; do
    if ! id "$user" >/dev/null 2>&1; then
      echo "WARN: cannot install authorized_keys for missing user: $user" >&2
      continue
    fi
    home_dir="$(getent passwd "$user" | cut -d: -f6)"
    if [ -z "$home_dir" ] || [ ! -d "$home_dir" ]; then
      echo "WARN: cannot determine home dir for user: $user" >&2
      continue
    fi
    install -d -m 0700 "$home_dir/.ssh"
    touch "$home_dir/.ssh/authorized_keys"
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      case "$key" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *) ;;
        *)
          echo "WARN: skipping non-OpenSSH public key line for $user" >&2
          continue
          ;;
      esac
      grep -qxF "$key" "$home_dir/.ssh/authorized_keys" || printf '%s\n' "$key" >> "$home_dir/.ssh/authorized_keys"
    done < "$TARGET_AUTHORIZED_KEYS_FILE"
    chown -R "$user:$user" "$home_dir/.ssh"
    chmod 0700 "$home_dir/.ssh"
    chmod 0600 "$home_dir/.ssh/authorized_keys"
  done
  echo "target_admin_authorized_keys_installed=true"
}

install_extra_authorized_keys() {
  if [ -z "${TARGET_AUTHORIZED_KEYS_FILE:-}" ]; then
    return 0
  fi
  if [ ! -s "$TARGET_AUTHORIZED_KEYS_FILE" ]; then
    echo "BLOCKER: TARGET_AUTHORIZED_KEYS_FILE is missing or empty: $TARGET_AUTHORIZED_KEYS_FILE" >&2
    exit 20
  fi

  mode="${TARGET_AUTHORIZED_KEYS_MODE:-keydrop}"
  case "$mode" in
    keydrop)
      TARGET_KEYDROP_AUTHORIZED_KEYS_FILE="$TARGET_AUTHORIZED_KEYS_FILE" bash /root/solana-target-keydrop-setup.sh
      ;;
    admin)
      install_admin_authorized_keys
      ;;
    both)
      TARGET_KEYDROP_AUTHORIZED_KEYS_FILE="$TARGET_AUTHORIZED_KEYS_FILE" bash /root/solana-target-keydrop-setup.sh
      install_admin_authorized_keys
      ;;
    *)
      echo "BLOCKER: unknown TARGET_AUTHORIZED_KEYS_MODE: $mode" >&2
      exit 21
      ;;
  esac
}

disable_fire_until_keys() {
  if [ "${TARGET_DISABLE_FIRE_UNTIL_KEYS:-true}" != "true" ]; then
    return 0
  fi
  systemctl disable --now fire sync-monitor >/dev/null 2>&1 || true
  echo "target_fire_disabled_until_keys=true"
}

bash fire-full-setup.sh "$FD_VERSION" "$FD_NETWORK" 2>&1 | tee "$log_path"
install_extra_authorized_keys | tee -a "$log_path"
disable_fire_until_keys | tee -a "$log_path"
printf 'bootstrap_log=%s\n' "$log_path"
