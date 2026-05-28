# Troubleshooting

## Cherry project is not empty

Stop before create. The kit expects a dedicated temporary project. Delete or move unrelated active servers only after separate operator review.

## Wrong disk layout

Symptoms:

- `/proc/mdstat` shows active mdraid;
- `lsblk` shows `linux_raid_member`;
- no clean NVMe data disk is available.

Action:

```bash
./scripts/solana-cherry-hotswap-guard.sh cherry-actions
./scripts/solana-cherry-hotswap-guard.sh cherry-rebuild-payload
```

Rebuild only while the server is empty. If the layout cannot be made safe, delete the server and stop the attempt.

## SSH does not work after create

Check:

- provider action state;
- public IP assignment;
- selected SSH key id;
- local private key path;
- whether login user is `ubuntu` or `root`.

The guard tries both `ubuntu` and `root` for Cherry verification.

## Source secondary gate fails

Stop. The source secondary must be distinct from the staked identity and vote account.

Do not use the same secondary identity on source and target.

## Source validator missing or delinquent

Stop. Do not start a hot-swap from an unhealthy source. Fix source health first or rehearse on testnet.

## Delinquent cluster stake is too high

Stop or raise the threshold only after explicit operator review. A hot-swap during elevated cluster delinquency can make diagnosis harder.

## Target is not caught up

Do not move the staked identity. Continue bootstrap/catchup or abort and delete before the rental checkpoint.

## `set-identity --require-tower` fails

Recover source first. Do not start a second validator with the staked identity while source may still be visible in gossip.

Common causes:

- wrong tower path;
- stale tower;
- tower not copied to target ledger;
- wrong identity path;
- source still owns the staked identity.

## Snapshot discovery stalls

Verify snapshot directory, expected shred version, entrypoints, and disk mounts. Prefer guarded fallback behavior over deleting or rebuilding live data blindly.

## Firedancer or Frankendancer XDP issues

Do not force driver mode from NIC name alone. Probe live route and driver capability. If unsure, leave provider defaults and keep the target as secondary until stable.

## Cleanup blocked

The delete safety gate blocks if validator-like processes, keypair-like files, or tower-like files are detected.

Stop validator processes, wipe staged material, rerun final status, then delete with exact server id confirmation.
