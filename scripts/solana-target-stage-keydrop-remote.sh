#!/usr/bin/env bash
set -euo pipefail

incoming_dir="${TARGET_KEYDROP_INCOMING_DIR:-/var/lib/solana-keydrop/incoming}"
keys_dir="${TARGET_KEYS_DIR:-/home/ubuntu/keys}"
validator_user="${TARGET_VALIDATOR_USER:-ubuntu}"
shred_after="${TARGET_KEYDROP_SHRED_AFTER_STAGE:-true}"

required_files=(
  staked-identity.json
  secondary-unstaked-identity.json
  vote-account-keypair.json
)

if [ ! -d "$incoming_dir" ]; then
  echo "BLOCKER: keydrop incoming dir not found: $incoming_dir" >&2
  exit 2
fi
if ! id "$validator_user" >/dev/null 2>&1; then
  echo "BLOCKER: validator user not found: $validator_user" >&2
  exit 2
fi

for name in "${required_files[@]}"; do
  path="$incoming_dir/$name"
  if [ ! -s "$path" ]; then
    echo "BLOCKER: missing uploaded keypair: $path" >&2
    exit 3
  fi
  python3 -c 'import json, sys
path = sys.argv[1]
with open(path) as handle:
    data = json.load(handle)
if not isinstance(data, list) or len(data) not in (32, 64):
    raise SystemExit(f"BLOCKER: {path} does not look like a Solana keypair JSON array")
if any(not isinstance(item, int) or item < 0 or item > 255 for item in data):
    raise SystemExit(f"BLOCKER: {path} has non-byte values")' "$path"
done

install -d -m 0700 -o "$validator_user" -g "$validator_user" "$keys_dir"
for name in "${required_files[@]}"; do
  install -m 0600 -o "$validator_user" -g "$validator_user" "$incoming_dir/$name" "$keys_dir/$name"
done

sudo -u "$validator_user" /home/ubuntu/setup-ramdisk-keys.sh

if [ "$shred_after" = "true" ]; then
  for name in "${required_files[@]}"; do
    if command -v shred >/dev/null 2>&1; then
      shred -u "$incoming_dir/$name"
    else
      rm -f "$incoming_dir/$name"
    fi
  done
fi

find /mnt/ramdisk -maxdepth 1 -type f -name '*.json' -printf '%f staged\n'
printf 'keydrop_stage=ok\n'
