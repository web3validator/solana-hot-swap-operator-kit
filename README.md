# Solana Hot-Swap Operator Kit

A practical operator kit for low-downtime Solana/Firedancer validator hot-swaps using a warm temporary bare-metal host.

This project packages the runbook, guard scripts, provider checks, and deployment templates I wanted while rehearsing validator upgrades: verify the source, rent a temporary host only after explicit approval, keep the target on a secondary identity until it is caught up, move the staked identity with tower protection, then clean the temporary host immediately.

```text
preflight -> provider gates -> warm secondary -> tower-safe handoff -> source upgrade -> reverse handoff -> cleanup
```

## Why this exists

Validator upgrades are usually planned, but the risky part is still operational: disk layout surprises, provider billing mistakes, stale towers, duplicate identities, slow SSH, and unclear cleanup state can all turn a routine restart into missed votes.

This repository focuses on the parts that should be repeatable:

- source validator preflight before any paid action;
- provider project emptiness and billing gates;
- Cherry Servers order payload generation;
- No RAID / free NVMe verification before bootstrap;
- strict source-only and target-only secondary identity discipline;
- tower-safe handoff checklist;
- final status and cleanup guard before deleting the temporary host.

It is intentionally not a full validator installer and not a key management system.

## What it does not do

The kit does not silently:

- copy validator keys;
- switch validator identities;
- restart production validators;
- create paid servers without confirmation;
- delete temporary servers without exact server id confirmation;
- store payment secrets, wallet files, or provider tokens in the repository.

Production identity movement stays operator-reviewed at the final moment.

## Repository layout

```text
solana-hot-swap-operator-kit/
  README.md
  docs/
    runbook.md
    cherry-provider.md
    deployment.md
    openclaw-chatgpt.md
    security.md
    smoke-test.md
    troubleshooting.md
  examples/
    env.example
    cherry-order-payload.example.json
    openclaw/relay.env.example
  relay/
    openclaw-codex-relay.mjs
  scripts/
    install.sh
    install-openclaw-chatgpt.sh
    openclaw_config_cleanup.py
    solana-cherry-hotswap-guard.sh
    solana-testnet-upgrade-preflight.sh
  systemd/
    openclaw-codex-relay.service.example
    openclaw-gateway.service.example
    solana-hotswap.service.example
  templates/
    session-start-prompt.md
```

## Quick start

```bash
git clone https://github.com/web3validator/solana-hot-swap-operator-kit.git
cd solana-hot-swap-operator-kit
cp examples/env.example .env
```

Edit `.env` privately, then run read-only checks:

```bash
set -a
. ./.env
set +a

./scripts/solana-cherry-hotswap-guard.sh attempt-preflight
```

Print a Cherry create payload without creating a server:

```bash
./scripts/solana-cherry-hotswap-guard.sh cherry-order-payload
```

Create one paid hourly Cherry server only after explicit approval:

```bash
CONFIRM_PAID_CHERRY_CREATE=I_CONFIRM_ONE_HOURLY_SERVER \
  ./scripts/solana-cherry-hotswap-guard.sh cherry-create
```

Delete only with exact server id confirmation:

```bash
CONFIRM_DELETE_SERVER_ID=REPLACE_WITH_SERVER_ID \
  ./scripts/solana-cherry-hotswap-guard.sh cherry-delete
```

## Main guard commands

```bash
./scripts/solana-cherry-hotswap-guard.sh show-config
./scripts/solana-cherry-hotswap-guard.sh attempt-preflight
./scripts/solana-cherry-hotswap-guard.sh cherry-balance
./scripts/solana-cherry-hotswap-guard.sh cherry-list
./scripts/solana-cherry-hotswap-guard.sh cherry-order-payload
./scripts/solana-cherry-hotswap-guard.sh cherry-create
./scripts/solana-cherry-hotswap-guard.sh cherry-verify
./scripts/solana-cherry-hotswap-guard.sh post-bootstrap-verify
./scripts/solana-cherry-hotswap-guard.sh final-status
./scripts/solana-cherry-hotswap-guard.sh cherry-delete
```

## Standalone deployment

The kit can be installed as a standalone one-shot systemd worker:

```bash
./scripts/install.sh --dry-run
sudo ./scripts/install.sh --apply --create-env
```

See `docs/deployment.md` before installing on a production operator host.

## Optional OpenClaw + ChatGPT relay

If you want the host reachable through OpenClaw and an OpenAI-compatible relay backed by ChatGPT/OpenAI Codex auth, install the optional integration:

```bash
./scripts/install-openclaw-chatgpt.sh --dry-run
sudo ./scripts/install-openclaw-chatgpt.sh --apply --restart
```

This path explicitly removes stale OmniRoute service/config references and does not set `ANTHROPIC_BASE_URL`.

See `docs/openclaw-chatgpt.md` for prerequisites, env overrides, and verification.

## Safety rules

Stop the attempt if any of these are true:

- the temporary provider project is not empty before ordering;
- the temporary host has RAID1 or unknown disk layout when No RAID is expected;
- source and target secondary identities are not distinct;
- target is not caught up enough to take over;
- `set-identity --require-tower` fails;
- source config still points to the staked identity while target is voting;
- keypair or tower material remains on the temporary host during cleanup.

## Documentation

- `docs/runbook.md` — end-to-end hot-swap checklist.
- `docs/cherry-provider.md` — Cherry Servers API, payload, RAID, and billing gates.
- `docs/deployment.md` — clean server install and systemd worker usage.
- `docs/openclaw-chatgpt.md` — optional OpenClaw Gateway and ChatGPT/Codex relay setup without OmniRoute.
- `docs/security.md` — public repo boundary, secrets, keys, tower handling.
- `docs/smoke-test.md` — clean VM validation checklist.
- `docs/troubleshooting.md` — common blockers and recovery paths.

## Validation

```bash
make check
```

The check compiles Python files, validates shell syntax, optionally checks the relay JavaScript with Node, and runs a redaction scan for common private artifacts.

## Contribution value

The reusable part is not the provider choice. It is the operating pattern:

```text
source preflight
  -> provider and billing gate
  -> warm non-voting target
  -> tower-safe identity handoff
  -> source upgrade
  -> reverse handoff
  -> cleanup verification
```

That pattern is useful for Solana operators regardless of whether the temporary host is Cherry Servers or another bare-metal provider.

## License

MIT
