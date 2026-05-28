# Security

## Public repository boundary

Never commit or paste:

- validator identity keypairs;
- vote-account keypairs;
- authorized voter or withdrawer keypairs;
- wallet files;
- SSH private keys;
- provider API tokens;
- JWTs or bot tokens;
- `.env` files;
- tower files;
- production hostnames or IP allowlists;
- provider invoices or account ids;
- local run logs.

## Environment files

Use `examples/env.example` as the template and keep real values in `.env` or a private deployment secret store.

The repository `.gitignore` excludes local env files, run directories, logs, SSH keys, keypair-like JSON files, and tower files.

## Provider secrets

The scripts do not handle payment secrets or wallet payments. Cherry API access is only through a bearer token supplied by environment.

Accepted token variables:

- `CHERRY_KEY`
- `CHERRY_AUTH_TOKEN`
- `CHERRY_API_TOKEN`

Do not put tokens in shell history, systemd unit files, issue trackers, chat, screenshots, or committed examples.

## Validator key material

This kit does not automate production key transfer.

Only stage production material after:

- source preflight passes;
- provider project is empty before create;
- temporary host disk layout passes;
- target bootstrap is complete;
- target is caught up;
- SSH latency is tested;
- operator confirms the handoff window.

Prefer volatile storage on the temporary host and strict permissions. Wipe staged key material and tower files before deleting the server.

## Identity discipline

Required identities:

- staked identity;
- source-only secondary identity;
- target-only secondary identity.

Reusing the same secondary on source and target is a blocker.

## Tower discipline

Use `set-identity --require-tower` for production handoff. If the target cannot load the required tower, recover source first.

Do not run two validators with the same staked identity while the source can still appear in gossip.

## Systemd deployment

If using `systemd/solana-hotswap.service.example`:

- keep `/etc/solana-hotswap/hotswap.env` mode `0600`;
- run under a dedicated user;
- keep writable paths limited to the run directory;
- do not place secrets directly in the unit file;
- review `journalctl` output before sharing logs.

## Publishing checklist

Before pushing or publishing:

```bash
make check
git status --short
```

Inspect staged files only. Do not add ignored local artifacts with force.
