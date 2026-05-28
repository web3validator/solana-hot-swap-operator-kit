# Session Start Prompt

You are working on a public Solana hot-swap operator kit.

Goal: keep the repository public-safe and useful for Solana/Firedancer operators who need low-downtime validator handoffs through a warm temporary bare-metal host.

Hard rules:

- Do not open, print, commit, or infer real validator keys, wallet files, provider tokens, hostnames, IP allowlists, invoices, or run logs.
- Keep examples placeholder-only.
- Paid provider actions require explicit confirmation.
- Delete actions require exact server id confirmation.
- Source and target secondary identities must be distinct.
- Use tower-protected identity handoff.
- Cleanup must wipe staged material and verify provider project emptiness.

Key docs:

- `README.md`
- `docs/runbook.md`
- `docs/cherry-provider.md`
- `docs/security.md`
- `docs/troubleshooting.md`

Main commands:

```bash
./scripts/solana-cherry-hotswap-guard.sh attempt-preflight
./scripts/solana-cherry-hotswap-guard.sh cherry-order-payload
./scripts/solana-cherry-hotswap-guard.sh cherry-create
./scripts/solana-cherry-hotswap-guard.sh cherry-verify
./scripts/solana-cherry-hotswap-guard.sh post-bootstrap-verify
./scripts/solana-cherry-hotswap-guard.sh final-status
./scripts/solana-cherry-hotswap-guard.sh cherry-delete
```
