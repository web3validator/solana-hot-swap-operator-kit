# OpenClaw ChatGPT Gateway and Relay

This optional setup exposes the hot-swap operator host through OpenClaw and an OpenAI-compatible relay backed by ChatGPT/OpenAI Codex auth.

It intentionally does **not** install or use OmniRoute.

## What gets installed

`./scripts/install-openclaw-chatgpt.sh` installs or refreshes:

- `openclaw-gateway.service` on loopback port `18789`;
- `openclaw-codex-relay.service` on port `20129`;
- `/opt/solana-hot-swap-operator-kit/relay/openclaw-codex-relay.mjs`;
- private relay config at `/etc/solana-hotswap/openclaw/relay.env`.

The relay implements:

- `GET /health`;
- `GET /v1/models`;
- `POST /v1/chat/completions`.

## Prerequisites

Install and authenticate OpenClaw first. The model path should be ChatGPT/OpenAI Codex, for example:

```bash
openclaw models status
openclaw status
```

The installer validates that Node.js 18+ is available. If the system `node` is old, pass the Node binary that belongs to the OpenClaw install:

```bash
OPENCLAW_NODE_BIN=/home/sol/.nvm/versions/node/v24.11.0/bin/node \
OPENCLAW_BIN=/home/sol/.nvm/versions/node/v24.11.0/bin/openclaw \
  ./scripts/install-openclaw-chatgpt.sh --dry-run
```

## Install or reinstall

Dry-run first:

```bash
./scripts/install-openclaw-chatgpt.sh --dry-run
```

Apply and restart services:

```bash
sudo ./scripts/install-openclaw-chatgpt.sh --apply --restart
```

If OpenClaw is installed outside `PATH`, preserve environment explicitly:

```bash
sudo env \
  OPENCLAW_BIN=/home/sol/.nvm/versions/node/v24.11.0/bin/openclaw \
  OPENCLAW_NODE_BIN=/home/sol/.nvm/versions/node/v24.11.0/bin/node \
  ./scripts/install-openclaw-chatgpt.sh --apply --restart
```

By default the installer removes stale OmniRoute systemd units, local OmniRoute state, and OpenClaw provider entries that route to `localhost:20128`.

## Private relay config

The first apply creates `/etc/solana-hotswap/openclaw/relay.env` with mode `0600` and a generated bearer token. If a legacy `/home/sol/openclaw-codex-relay/relay.env` exists, it is migrated first so existing clients keep the same token and allowlist. Existing config is preserved on later runs.

Use `--force-env` only when you intentionally want a new relay token and default config.

Common variables:

```bash
PORT=20129
HOST=0.0.0.0
OPENCLAW_CODEX_RELAY_MODEL=openai/gpt-5.5
OPENCLAW_CODEX_RELAY_THINKING=low
OPENCLAW_CODEX_RELAY_ALLOWLIST=127.0.0.1,::1
```

Add only trusted client IPs to `OPENCLAW_CODEX_RELAY_ALLOWLIST`.

## Verify

```bash
systemctl status openclaw-gateway.service openclaw-codex-relay.service --no-pager
curl -fsS http://127.0.0.1:20129/health
openclaw status
openclaw models status
```

For authenticated relay calls, read the bearer token from the private env file and send it as `Authorization: Bearer ...`.

## Rollback

Stop and disable only the OpenClaw integration services:

```bash
sudo systemctl disable --now openclaw-codex-relay.service openclaw-gateway.service
```

The Solana hot-swap worker is separate and is not removed by this rollback.
