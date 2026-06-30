# OpenClaw Agent Playbook

This is the short operational contract for an OpenClaw/Telegram agent controlling the Solana Cherry hot-swap kit.

The agent must treat this as a safety playbook, not as generic chat advice.

## Golden rules

- Never print Cherry tokens, OpenAI/OpenClaw relay tokens, SSH private keys, validator keypairs, vote keypairs, tower files, or raw private env files.
- Never create or delete a paid Cherry server without explicit operator confirmation.
- Never run validator identity handoff without explicit operator confirmation and a successful dry-run.
- Never stage or move production validator key material before target bootstrap, disk, SSH, and catchup gates pass.
- Before any Cherry create/bootstrap run, ask the operator which Firedancer version/tag to use.

## Required version confirmation

Before running any of these commands:

- `cherry-mainnet-one-shot.sh --create-and-bootstrap`
- `cherry-mainnet-one-shot.sh --bootstrap`
- `cherry-mainnet-one-shot.sh --create` when it is intended to be followed by bootstrap

The agent must ask:

```text
Какую версию Firedancer ставим? Сейчас в приватном env указано FD_VERSION=<current>. Подтверди эту версию или дай новый tag.
```

The agent may check the current value without printing the full env:

```bash
sudo -n sh -c "grep '^FD_VERSION=' /etc/solana-hotswap/hotswap.env"
```

If the operator provides a new tag, update only `FD_VERSION` in the private env and create a timestamped backup first. Do not print the full env.

Example command shape, replacing the tag literally:

```bash
sudo -n cp /etc/solana-hotswap/hotswap.env /etc/solana-hotswap/hotswap.env.bak-before-fd-version-change-REPLACE_WITH_UTC_TIMESTAMP
sudo -n sed -i 's/^FD_VERSION=.*/FD_VERSION=REPLACE_WITH_FD_VERSION/' /etc/solana-hotswap/hotswap.env
```

After updating, verify only this key:

```bash
sudo -n sh -c "grep '^FD_VERSION=' /etc/solana-hotswap/hotswap.env"
```

## If the operator says “Запускай Cherry”

Do not immediately create a server unless the same message already contains both:

1. the exact `FD_VERSION` confirmation;
2. explicit paid-server confirmation.

Default response should be:

```text
Перед запуском подтверди:
1. Версия Firedancer: оставить текущую FD_VERSION=<current> или поставить другой tag?
2. Разрешаешь создать один paid hourly Cherry server?
```

Only after confirmation proceed.

## Standard safe launch sequence

1. Verify OpenClaw model path:

```bash
systemctl is-active openclaw-gateway.service openclaw-codex-relay.service
systemctl is-active omniroute.service || true
curl -fsS http://127.0.0.1:20129/health
```

Expected:

- gateway active;
- relay active;
- OmniRoute inactive;
- relay reports OpenAI/ChatGPT model.

2. Check current Firedancer version setting:

```bash
sudo -n sh -c "grep '^FD_VERSION=' /etc/solana-hotswap/hotswap.env"
```

3. Run plan only:

```bash
sudo -n env HOTSWAP_ENV_FILE=/etc/solana-hotswap/hotswap.env \
  /opt/solana-hot-swap-operator-kit/scripts/cherry-mainnet-one-shot.sh --plan
```

Required plan gates:

- credit summary is visible;
- Cherry project is empty;
- payload uses the current approved Cherry SSH key;
- payload is hourly and tagged for mainnet hot-swap.

4. If and only if operator confirmed paid create, run:

```bash
sudo -n env HOTSWAP_ENV_FILE=/etc/solana-hotswap/hotswap.env \
  /opt/solana-hot-swap-operator-kit/scripts/cherry-mainnet-one-shot.sh --create-and-bootstrap
```

The wrapper should:

- create one hourly server;
- wait for IP;
- wait 15 minutes from create before SSH polling;
- poll SSH every 2 minutes;
- verify disk/no-RAID gate;
- wait until minimum bootstrap age;
- bootstrap inside target tmux;
- run post-bootstrap verification;
- reboot the target by default;
- wait for SSH after reboot;
- leave `fire`/`sync-monitor` disabled until key staging;
- send Telegram notification that the target is ready for key staging.

## Target bootstrap tmux

By default bootstrap runs on the Cherry target inside tmux.

Target attach command:

```bash
tmux attach -t solana-bootstrap
```

Target files:

```text
/root/solana-cherry-bootstrap.tmux.log
/root/solana-cherry-bootstrap.status
```

Operator host follows status through `cherry-mainnet-one-shot.sh` when `CHERRY_BOOTSTRAP_FOLLOW=true`.

## Current private key policy

The Cherry SSH key is managed through private env:

- `CHERRY_SSH_KEY_ID`
- `CHERRY_SSH_KEY`
- `CHERRY_TARGET_AUTHORIZED_KEYS_FILE`

`CHERRY_TARGET_AUTHORIZED_KEYS_FILE` is a private local file containing OpenSSH public keys that should be allowed into every Cherry target, for example the source mainnet host public key. The agent may print the file path and line count, but should not dump operator infrastructure keys unless the operator explicitly asks.

The agent may verify these keys exist by printing only key names/paths or order payload, but must not print private key contents.

To list Cherry SSH key metadata without public key material:

```bash
sudo -n /opt/solana-hot-swap-operator-kit/scripts/solana-cherry-hotswap-guard.sh \
  --env-file /etc/solana-hotswap/hotswap.env \
  cherry-ssh-keys
```

## Identity handoff

Do not handoff identity automatically after bootstrap.

After bootstrap/reboot, key staging and start/sync are a separate explicit operation:

```bash
sudo -n env HOTSWAP_ENV_FILE=/etc/solana-hotswap/hotswap.env \
  TARGET_HOST=ubuntu@REPLACE_WITH_TARGET_IP \
  STAKED_IDENTITY_FILE=/path/to/staked-identity.json \
  SECONDARY_UNSTAKED_IDENTITY_FILE=/path/to/secondary-unstaked-identity.json \
  VOTE_KEYPAIR_FILE=/path/to/vote-account-keypair.json \
  CONFIRM_TARGET_STAGE_START=I_CONFIRM_TARGET_STAGE_START \
  /opt/solana-hot-swap-operator-kit/scripts/solana-target-stage-start-sync.sh --execute --all
```

This operation stages keypairs, enables and starts `fire.service`, waits for sync/catchup, and sends Telegram notification when the target is ready for identity handoff.

For identity handoff use:

- `docs/identity-handoff.md`
- `scripts/solana-identity-handoff.sh`

The script defaults to dry-run and requires:

```text
CONFIRM_SOLANA_IDENTITY_HANDOFF=I_CONFIRM_IDENTITY_HANDOFF
```

for execution.

## Delete / cleanup

If the run is only a rehearsal or bootstrap test, remind the operator that the Cherry server is paid and should be deleted when no longer needed.

Deletion requires exact server id confirmation:

```bash
sudo -n env HOTSWAP_ENV_FILE=/etc/solana-hotswap/hotswap.env \
  SERVER_ID=REPLACE_WITH_SERVER_ID \
  SERVER_IP=REPLACE_WITH_SERVER_IP \
  CREATED_AT_EPOCH=REPLACE_WITH_CREATED_AT_EPOCH \
  CONFIRM_DELETE_SERVER_ID=REPLACE_WITH_SERVER_ID \
  /opt/solana-hot-swap-operator-kit/scripts/solana-cherry-hotswap-guard.sh cherry-delete
```
