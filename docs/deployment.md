# Deployment

This kit is designed to run as a standalone operator tool. It does not require any external gateway or Telegram runtime.

## Clean server install

Clone the public repository:

```bash
git clone https://github.com/YOUR_ORG/solana-hot-swap-operator-kit.git
cd solana-hot-swap-operator-kit
```

Run the installer in dry-run mode first:

```bash
./scripts/install.sh --dry-run
```

Apply only after reviewing the printed commands:

```bash
sudo ./scripts/install.sh --apply
```

The installer copies repository files to `/opt/solana-hot-swap-operator-kit`, installs the systemd unit template, creates a config example under `/etc/solana-hotswap`, and reloads systemd. It does not start a production action.

## Private config

Create a private env file from the example:

```bash
sudo install -m 0600 /etc/solana-hotswap/hotswap.env.example /etc/solana-hotswap/hotswap.env
sudo editor /etc/solana-hotswap/hotswap.env
```

Keep real provider tokens, SSH key paths, validator identity paths, and operator-specific values private.

## Systemd worker

The unit is a one-shot worker. The default command in `hotswap.env` is:

```bash
HOTSWAP_COMMAND=show-config
```

Start it with:

```bash
sudo systemctl start solana-hotswap.service
sudo systemctl status solana-hotswap.service --no-pager
```

Inspect logs:

```bash
sudo journalctl -u solana-hotswap.service --no-pager -n 200
```

To run a different guard command, update `HOTSWAP_COMMAND` in the private env file and start the service again.

Recommended first commands:

```bash
HOTSWAP_COMMAND=show-config
HOTSWAP_COMMAND=attempt-preflight
HOTSWAP_COMMAND=cherry-order-payload
```

Paid actions still require explicit confirmation variables.

## Direct CLI mode

You can run the kit directly without systemd:

```bash
set -a
. ./.env
set +a

./scripts/solana-cherry-hotswap-guard.sh show-config
./scripts/solana-cherry-hotswap-guard.sh attempt-preflight
```

## What the installer does not do

- It does not create a Cherry server.
- It does not copy validator keys.
- It does not switch validator identities.
- It does not start or restart Solana services.
- It does not push logs or secrets anywhere.
