# Runbook

## Goal

Move a staked Solana validator identity to a warmed temporary host, upgrade or restart the source, then move the identity back with minimal voting interruption.

This is a checklist for experienced Solana operators. It is not blind production automation.

## Roles

- **Source**: current validator host that owns the staked identity.
- **Target**: temporary bare-metal host that catches up as a non-voting secondary.
- **Staked identity**: production identity tied to the vote account.
- **Source secondary**: source-only unstaked identity.
- **Target secondary**: target-only unstaked identity.

All three identities must be distinct.

## Preconditions

- Source validator is healthy and not delinquent.
- Cluster delinquent stake is below the operator threshold.
- A leader-safe handoff window is available.
- Source has a dedicated source-only secondary identity.
- Target will use a different target-only secondary identity.
- Source and target use the same cluster, genesis, expected shred version, and compatible validator family.
- Target can catch up before it receives the staked identity.
- SSH source-to-target and target-to-source is verified before handoff.
- Ledger and tower paths are known on both hosts.

## Hard blockers

Stop if any of these are true:

- Cherry project is not empty before ordering.
- Temporary host has RAID1 or unknown disk layout when No RAID is expected.
- No clean data NVMe is available for validator data.
- Source secondary equals the staked identity or vote account.
- Target secondary equals source secondary, staked identity, or vote account.
- Target is not caught up enough to take over.
- `set-identity --require-tower` fails.
- Source config points to the staked identity while target is voting.
- Temporary host still has keypair or tower material during cleanup.

## 1. Source preflight

Load environment and run:

```bash
set -a
. ./.env
set +a

./scripts/solana-cherry-hotswap-guard.sh attempt-preflight
```

Required result:

- source secondary gate passes;
- RPC health is ok;
- validator service is active;
- own validator is present and not delinquent;
- leader schedule is known;
- disk, snapshot, DNS, and shred-version assumptions are visible;
- Cherry project is empty;
- order payload is printed but no server is created.

## 2. Provider and billing gate

Check provider account and project state:

```bash
./scripts/solana-cherry-hotswap-guard.sh cherry-balance
./scripts/solana-cherry-hotswap-guard.sh cherry-list
./scripts/solana-cherry-hotswap-guard.sh cherry-order-payload
```

Continue only after explicit operator approval for one paid hourly server.

## 3. Create temporary host

```bash
CONFIRM_PAID_CHERRY_CREATE=I_CONFIRM_ONE_HOURLY_SERVER \
  ./scripts/solana-cherry-hotswap-guard.sh cherry-create
```

Save the printed state:

```bash
export SERVER_ID=REPLACE_WITH_SERVER_ID
export SERVER_IP=REPLACE_WITH_SERVER_IP
export CREATED_AT_EPOCH=REPLACE_WITH_CREATED_AT_EPOCH
```

## 4. Verify host before bootstrap

```bash
./scripts/solana-cherry-hotswap-guard.sh attempt-after-create
```

Required result:

- SSH works as `ubuntu` or `root`;
- no active mdraid device;
- no `linux_raid_member` disks;
- at least one clean unformatted NVMe data disk exists;
- billing checkpoints are visible.

If disk layout is wrong, inspect provider actions and rebuild only while the server is empty:

```bash
./scripts/solana-cherry-hotswap-guard.sh cherry-actions
./scripts/solana-cherry-hotswap-guard.sh cherry-rebuild-payload
```

## 5. Bootstrap target

Install the validator stack on the temporary host using your audited installer or manual baseline. Keep target on a target-only secondary identity until live handoff.

Required result:

- service files are valid;
- validator binary version is expected;
- local RPC comes up;
- target catches up as a non-voting node;
- logs do not show disk, snapshot, XDP, tower, or startup blockers.

Then run:

```bash
./scripts/solana-cherry-hotswap-guard.sh post-bootstrap-verify
```

## 6. Stage production material only after gates pass

Stage production identity material only after provider, disk, bootstrap, catchup, and SSH gates pass.

Use volatile storage where possible and strict file permissions. Do not pass key material through environment variables, chat, issue trackers, logs, or shell history.

## 7. Prepare SSH control sessions

Open persistent SSH sessions before the handoff so final commands do not pay connection latency.

```bash
mkdir -p .ssh-control
ssh -fnMN -o ControlMaster=yes -o ControlPersist=10m \
  -S .ssh-control/source-%h-%p-%r "$SOLANA_SOURCE"
ssh -fnMN -o ControlMaster=yes -o ControlPersist=10m \
  -S .ssh-control/target-%h-%p-%r -i "$CHERRY_SSH_KEY" "ubuntu@$SERVER_IP"
```

Verify final `true` probes return immediately.

## 8. Forward handoff

In a leader-safe window:

1. Switch source to source-only secondary identity.
2. Copy the latest tower from source ledger to target ledger.
3. Switch target to staked identity with `--require-tower`.
4. Verify target owns the staked identity and source is secondary.

If target identity switch fails, recover source first. Do not start a second validator process with the same staked identity while source can still appear in gossip.

## 9. Update source while target votes

Update or restart source only after target verification.

Expected while source is secondary:

- vote-account node-pubkey mismatch warnings can be normal;
- source should not vote;
- source should continue catching up.

## 10. Reverse handoff

When source is healthy on the new version:

1. Switch target to target-only secondary identity.
2. Copy the latest tower back to source ledger.
3. Switch source to staked identity with `--require-tower`.
4. Verify source owns the staked identity and target is secondary.

Final gate:

- source service is active;
- source RPC health is ok;
- gossip shows the staked identity on source;
- source config points back to the staked identity;
- target no longer owns the staked identity.

## 11. Cleanup

Stop validator processes on the temporary host, wipe staged keypair and tower material, delete the server, then verify project emptiness.

```bash
./scripts/solana-cherry-hotswap-guard.sh final-status

CONFIRM_DELETE_SERVER_ID=REPLACE_WITH_SERVER_ID \
  ./scripts/solana-cherry-hotswap-guard.sh cherry-delete

./scripts/solana-cherry-hotswap-guard.sh cherry-list
```

Do not leave an idle paid server running without an explicit operator decision and checkpoint.
