#!/usr/bin/env bash
set -euo pipefail

key_file="${TARGET_KEYDROP_AUTHORIZED_KEYS_FILE:-${TARGET_AUTHORIZED_KEYS_FILE:-}}"
user="${TARGET_KEYDROP_USER:-solana-keydrop}"
root_dir="${TARGET_KEYDROP_ROOT:-/var/lib/solana-keydrop}"
incoming_dir="$root_dir/incoming"
auth_dir="${TARGET_KEYDROP_AUTHORIZED_KEYS_DIR:-/etc/ssh/authorized_keys}"
sshd_config="${TARGET_KEYDROP_SSHD_CONFIG:-/etc/ssh/sshd_config.d/90-solana-keydrop.conf}"
sshd_config_dir="$(dirname "$sshd_config")"
if [ -n "${TARGET_KEYDROP_SHELL:-}" ]; then
  keydrop_shell="$TARGET_KEYDROP_SHELL"
elif [ -x /usr/sbin/nologin ]; then
  keydrop_shell=/usr/sbin/nologin
else
  keydrop_shell=/bin/false
fi

if [ -z "$key_file" ]; then
  echo "keydrop_setup=skipped_no_authorized_keys_file"
  exit 0
fi
if [ ! -s "$key_file" ]; then
  echo "BLOCKER: keydrop authorized keys file missing or empty: $key_file" >&2
  exit 2
fi

if ! getent group "$user" >/dev/null 2>&1; then
  groupadd --system "$user"
fi
if ! id "$user" >/dev/null 2>&1; then
  useradd --system --gid "$user" --home-dir "$root_dir" --shell "$keydrop_shell" --comment "Solana keydrop SFTP-only user" "$user"
else
  current_shell="$(getent passwd "$user" | cut -d: -f7)"
  if [ "$current_shell" != "$keydrop_shell" ]; then
    usermod --shell "$keydrop_shell" "$user"
  fi
fi

install -d -m 0755 -o root -g root "$root_dir"
install -d -m 0700 -o "$user" -g "$user" "$incoming_dir"
install -d -m 0755 -o root -g root "$auth_dir"
install -d -m 0755 -o root -g root "$sshd_config_dir"
install -m 0600 -o root -g root "$key_file" "$auth_dir/$user"

{
  printf '%s\n' '# Managed by solana-hot-swap-operator-kit.'
  printf '%s\n' '# Restricts validator key upload to an SFTP-only chroot user.'
  printf 'Match User %s\n' "$user"
  printf '    AuthorizedKeysFile %s/%%u\n' "$auth_dir"
  printf '    ChrootDirectory %s\n' "$root_dir"
  printf '%s\n' '    ForceCommand internal-sftp -d /incoming'
  printf '%s\n' '    PasswordAuthentication no'
  printf '%s\n' '    KbdInteractiveAuthentication no'
  printf '%s\n' '    PubkeyAuthentication yes'
  printf '%s\n' '    PermitTTY no'
  printf '%s\n' '    AllowTcpForwarding no'
  printf '%s\n' '    X11Forwarding no'
  printf '%s\n' '    AllowAgentForwarding no'
  printf '%s\n' '    PermitTunnel no'
} > "$sshd_config"
chmod 0644 "$sshd_config"

sshd -t
if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
  systemctl reload ssh || systemctl restart ssh
elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then
  systemctl reload sshd || systemctl restart sshd
fi

printf 'keydrop_user=%s\n' "$user"
printf 'keydrop_incoming_dir=%s\n' "$incoming_dir"
printf 'keydrop_chroot=%s\n' "$root_dir"
printf 'keydrop_authorized_keys=%s\n' "$auth_dir/$user"
printf 'keydrop_shell=%s\n' "$keydrop_shell"
printf 'keydrop_setup=ok\n'
