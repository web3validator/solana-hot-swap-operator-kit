# Solana Identity Handoff

This document describes the guarded identity handoff step after a Cherry target has already passed bootstrap and catchup gates.

Do not run these commands until the target is healthy, synced enough, has the required keypairs staged in volatile storage, and the operator has confirmed a leader-safe window.

## Core idea

The forward handoff is the safe version of this manual sequence:

```bash
/home/ubuntu/firedancer/build/native/gcc/bin/fdctl set-identity \
  --config /home/ubuntu/solana/config.toml \
  /mnt/ramdisk/secondary-unstaked-identity.json

scp /mnt/ledger/tower* TARGET_HOST:/mnt/ledger/

ssh TARGET_HOST \
  '/home/ubuntu/firedancer/build/native/gcc/bin/fdctl set-identity --config /home/ubuntu/solana/config.toml /mnt/ramdisk/staked-identity.json --require-tower'
```

The repository provides `scripts/solana-identity-handoff.sh` to wrap this in preflight checks, dry-run output, and an explicit execute confirmation.

## Where to run it

Run the script on the validator host that currently owns the staked identity.

For forward handoff, run it on the source/current staked machine.

For reverse handoff, run the same script on the temporary target/current staked machine, with `REMOTE_HOST` pointing back to the original source.

## Required preconditions

Stop if any of these are not true:

- Source and target are on the same network and compatible Firedancer/Solana versions.
- Target has completed bootstrap and disk gates.
- Target has the staked identity staged at `REMOTE_STAKED_IDENTITY`.
- Local host has a secondary unstaked identity staged at `LOCAL_SECONDARY_IDENTITY`.
- The staked identity, local secondary identity, and remote secondary identity are distinct.
- Tower files exist under `LOCAL_LEDGER_DIR`.
- SSH from local host to `REMOTE_HOST` works without an interactive password.
- The remote `fdctl`, config, staked identity, and ledger directory exist.
- A leader-safe operator window has been selected.

## Dry run

From the current staked machine:

```bash
REMOTE_HOST=ubuntu@TARGET_HOST \
  LOCAL_SECONDARY_IDENTITY=/mnt/ramdisk/secondary-unstaked-identity.json \
  REMOTE_STAKED_IDENTITY=/mnt/ramdisk/staked-identity.json \
  /path/to/solana-hot-swap-operator-kit/scripts/solana-identity-handoff.sh --dry-run
```

Expected result:

- local and remote paths are printed;
- tower file count is printed;
- planned `fdctl`, `scp`, and remote `fdctl --require-tower` commands are printed;
- no identities change;
- no tower files are copied.

## Execute forward handoff

Only after the dry-run is correct:

```bash
CONFIRM_SOLANA_IDENTITY_HANDOFF=I_CONFIRM_IDENTITY_HANDOFF \
  REMOTE_HOST=ubuntu@TARGET_HOST \
  LOCAL_SECONDARY_IDENTITY=/mnt/ramdisk/secondary-unstaked-identity.json \
  REMOTE_STAKED_IDENTITY=/mnt/ramdisk/staked-identity.json \
  /path/to/solana-hot-swap-operator-kit/scripts/solana-identity-handoff.sh --execute
```

Execution order:

1. local validator switches to local secondary identity;
2. local tower files are copied to the remote ledger directory;
3. remote validator switches to staked identity using `--require-tower`.

If step 3 fails, recover source first. Do not allow two validators to continue with the same staked identity.

## Reverse handoff

Run the same script on the temporary target/current staked machine, pointing `REMOTE_HOST` to the original source.

Example:

```bash
CONFIRM_SOLANA_IDENTITY_HANDOFF=I_CONFIRM_IDENTITY_HANDOFF \
  REMOTE_HOST=ubuntu@SOURCE_HOST \
  LOCAL_SECONDARY_IDENTITY=/mnt/ramdisk/secondary-unstaked-identity.json \
  REMOTE_STAKED_IDENTITY=/mnt/ramdisk/staked-identity.json \
  /path/to/solana-hot-swap-operator-kit/scripts/solana-identity-handoff.sh --execute
```

## Path overrides

Defaults:

```bash
LOCAL_FDCTL=/home/ubuntu/firedancer/build/native/gcc/bin/fdctl
LOCAL_CONFIG=/home/ubuntu/solana/config.toml
LOCAL_SECONDARY_IDENTITY=/mnt/ramdisk/secondary-unstaked-identity.json
LOCAL_LEDGER_DIR=/mnt/ledger
REMOTE_FDCTL=/home/ubuntu/firedancer/build/native/gcc/bin/fdctl
REMOTE_CONFIG=/home/ubuntu/solana/config.toml
REMOTE_STAKED_IDENTITY=/mnt/ramdisk/staked-identity.json
REMOTE_LEDGER_DIR=/mnt/ledger
```

Override them in the environment when the layout differs.

## Post-handoff checks

Immediately verify:

- source is no longer voting with the staked identity;
- target owns the staked identity;
- target does not fail `--require-tower`;
- gossip and logs show the expected identity;
- there is no duplicate staked identity on source and target.
