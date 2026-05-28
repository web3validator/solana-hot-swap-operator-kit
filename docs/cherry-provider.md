# Cherry Provider

## API endpoints

The guard uses Cherry Servers API v1:

- `GET /v1/projects/{projectId}/servers`
- `POST /v1/projects/{projectId}/servers`
- `GET /v1/servers/{serverId}`
- `GET /v1/servers/{serverId}/actions`
- `POST /v1/servers/{serverId}/actions`
- `DELETE /v1/servers/{serverId}`

Authentication uses a bearer token. The kit accepts `CHERRY_KEY`, `CHERRY_AUTH_TOKEN`, or `CHERRY_API_TOKEN`; prefer `CHERRY_KEY` in `.env`.

## Required environment

```bash
CHERRY_PROJECT_ID=REPLACE_WITH_PROJECT_ID
CHERRY_SSH_KEY_ID=REPLACE_WITH_SSH_KEY_ID
CHERRY_KEY=REPLACE_WITH_CHERRY_API_TOKEN
CHERRY_PLAN=amd-ryzen-9950x
CHERRY_REGION=LT-Siauliai
CHERRY_IMAGE=ubuntu_24_04_64bit
CHERRY_HOSTNAME=solana-hotswap
```

## Empty project gate

Before creating a server:

```bash
./scripts/solana-cherry-hotswap-guard.sh cherry-list
```

If any active server is present, stop. Use a dedicated project for hot-swap attempts.

## Order payload

Print payload only:

```bash
./scripts/solana-cherry-hotswap-guard.sh cherry-order-payload
```

Example payload is in `examples/cherry-order-payload.example.json`.

Provider-specific variants can be supplied with:

```bash
CHERRY_VARIANT_IDS="REPLACE_WITH_VARIANT_ID"
```

Treat variant ids as operator-confirmed inputs and verify actual deployed disk layout after creation.

## Paid create gate

The guard refuses create unless the confirmation value is exact:

```bash
CONFIRM_PAID_CHERRY_CREATE=I_CONFIRM_ONE_HOURLY_SERVER \
  ./scripts/solana-cherry-hotswap-guard.sh cherry-create
```

The command writes local attempt state under `runs/cherry-attempts/`. This directory must not be committed.

## Disk layout gate

The hot-swap flow expects No RAID and at least one clean NVMe data disk.

```bash
SERVER_ID=REPLACE_WITH_SERVER_ID \
SERVER_IP=REPLACE_WITH_SERVER_IP \
./scripts/solana-cherry-hotswap-guard.sh cherry-verify
```

Blockers:

- active mdraid device;
- `linux_raid_member` disks;
- no free unformatted NVMe data disk;
- SSH unavailable through the configured key.

## Rebuild gate

If the provider created the wrong disk layout, inspect available actions:

```bash
./scripts/solana-cherry-hotswap-guard.sh cherry-actions
./scripts/solana-cherry-hotswap-guard.sh cherry-rebuild-payload
```

Rebuild only while the server is empty. Never rebuild after validator key material or tower files are staged.

## Rental checkpoints

```bash
./scripts/solana-cherry-hotswap-guard.sh deadline
```

Default checkpoints:

- T+10m: SSH and RAID verification complete.
- T+30m: bootstrap running or finished.
- T+60m: snapshot or catchup clearly progressing.
- T+90m: continue vs abort decision.
- T+110m: cleanup starts.
- T+120m: delete unless explicitly extended.

The deadline command is a decision aid, not an automatic delete switch.

## Delete gate

Deletion requires the exact server id:

```bash
CONFIRM_DELETE_SERVER_ID=REPLACE_WITH_SERVER_ID \
  ./scripts/solana-cherry-hotswap-guard.sh cherry-delete
```

The guard checks Cherry state and attempts a temporary-host safety scan before delete.
