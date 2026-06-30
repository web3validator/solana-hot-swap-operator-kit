# Smoke Test

Run this on a clean VM before using the kit for an operator rehearsal.

## 1. Static checks

```bash
make check
python3 -m json.tool package.json >/dev/null
python3 -m json.tool examples/cherry-order-payload.example.json >/dev/null
```

Expected result:

```text
redaction_check=ok
```

## 2. CLI help

```bash
./scripts/solana-cherry-hotswap-guard.sh --help
```

Expected result: command list is printed.

## 3. Example config

```bash
./scripts/solana-cherry-hotswap-guard.sh --env-file examples/env.example show-config
```

Expected result: config is printed with `token_present=true` and no secret value.

## 4. Payload render

```bash
./scripts/solana-cherry-hotswap-guard.sh --env-file examples/env.example cherry-order-payload
```

Expected result: JSON payload with hourly billing, placeholder project values, and `ssh_keys` as an integer array.

## 5. Paid action guard

```bash
./scripts/solana-cherry-hotswap-guard.sh --env-file examples/env.example cherry-create
```

Expected result:

```text
BLOCKER: set CONFIRM_PAID_CHERRY_CREATE=I_CONFIRM_ONE_HOURLY_SERVER after explicit operator confirmation
```

No API call should be made.

## 6. Input validation

```bash
CHERRY_SSH_KEY_ID=not_an_integer \
  ./scripts/solana-cherry-hotswap-guard.sh --env-file examples/env.example cherry-order-payload
```

Expected result:

```text
BLOCKER: CHERRY_SSH_KEY_ID must be an integer
```

## 7. Installer dry-run

```bash
./scripts/install.sh --dry-run --create-env
```

Expected result: commands are printed but no files are installed.

## 8. OpenClaw installer help

```bash
./scripts/install-openclaw-chatgpt.sh --help
```

Expected result: usage is printed. Full dry-run requires an installed OpenClaw CLI and Node.js 18+.

## 9. Systemd syntax

On a systemd host:

```bash
cp systemd/solana-hotswap.service.example /tmp/solana-hotswap.service
systemd-analyze verify /tmp/solana-hotswap.service
```

Some hosts may print unrelated unit permission warnings. The template should not report syntax errors for `solana-hotswap.service`.

For OpenClaw service templates, run `scripts/install-openclaw-chatgpt.sh --dry-run` on a host that already has OpenClaw and Node.js 18+ installed; it renders concrete units during apply.
