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

## OpenClaw relay is installed but inference fails

Check services first:

```bash
systemctl status openclaw-gateway.service openclaw-codex-relay.service --no-pager
curl -fsS http://127.0.0.1:20129/health
openclaw models status
```

Common causes:

- OpenClaw is not authenticated with ChatGPT/OpenAI Codex yet;
- the service is using an old system Node instead of the Node binary used by OpenClaw;
- `OPENCLAW_BIN` or `OPENCLAW_WORKSPACE` in `/etc/solana-hotswap/openclaw/relay.env` points to the wrong path;
- the client IP is missing from `OPENCLAW_CODEX_RELAY_ALLOWLIST`;
- the client omitted the bearer token from `OPENCLAW_CODEX_RELAY_TOKEN`.

Re-run the installer with explicit paths if needed:

```bash
sudo env \
  OPENCLAW_BIN=/home/sol/.nvm/versions/node/v24.11.0/bin/openclaw \
  OPENCLAW_NODE_BIN=/home/sol/.nvm/versions/node/v24.11.0/bin/node \
  ./scripts/install-openclaw-chatgpt.sh --apply --restart
```

## Stale OmniRoute routing remains

The ChatGPT relay path does not use OmniRoute. Re-run:

```bash
sudo ./scripts/install-openclaw-chatgpt.sh --apply --restart
```

Then confirm there is no `omniroute.service` and no OpenClaw provider route to `localhost:20128`.

## Cleanup blocked

The delete safety gate blocks if validator-like processes, keypair-like files, or tower-like files are detected.

Stop validator processes, wipe staged material, rerun final status, then delete with exact server id confirmation.
