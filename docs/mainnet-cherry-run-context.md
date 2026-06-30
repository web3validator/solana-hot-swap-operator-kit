# Mainnet Cherry Run Context

Commit-safe operator/agent context for the Cherry Servers Solana mainnet target bootstrap flow.

Do not put real Cherry tokens, SSH private keys, validator keypairs, tower files, public operator IPs, provider project IDs, provider SSH key IDs, or private account labels here. Keep live values in /etc/solana-hotswap/hotswap.env and ignored runs/*.private.md notes.

## Purpose

1. Confirm OpenClaw/Telegram uses the ChatGPT relay path, not OmniRoute.
2. Plan one hourly Cherry bare-metal server from the private hotswap env.
3. Create one server only after explicit operator approval.
4. Wait for the provider-assigned IP.
5. Verify SSH and disk layout before bootstrap.
6. Bootstrap Solana/Firedancer on the Cherry target.
7. Keep production validator identity and tower handoff blocked until all target gates pass.
8. Delete the temporary server unless an operator explicitly extends rental time.

## Active paths

- Repo: /home/sol/kit/solana-hot-swap-operator-kit
- Installed runtime copy: /opt/solana-hot-swap-operator-kit
- Private env: /etc/solana-hotswap/hotswap.env
- Cherry SSH key path: value of CHERRY_SSH_KEY
- Extra target authorized keys file: value of CHERRY_TARGET_AUTHORIZED_KEYS_FILE
- Run state dir: value of HOTSWAP_RUN_DIR
- Cherry known_hosts file: value of CHERRY_KNOWN_HOSTS
- Private live context: runs/mainnet-cherry-run-context.private.md or another ignored local note file

## OpenClaw / Telegram model path

- Gateway service: openclaw-gateway.service
- Relay service: openclaw-codex-relay.service
- Relay health endpoint: http://127.0.0.1:20129/health
- Expected model family: OpenAI/ChatGPT via the local relay
- OmniRoute should not be part of this flow.

Check:

systemctl is-active openclaw-gateway.service openclaw-codex-relay.service
systemctl is-active omniroute.service || true
curl -fsS http://127.0.0.1:20129/health

## OpenClaw agent playbook

OpenClaw/Telegram agents should first read `docs/openclaw-agent-playbook.md`.

Critical rule: before any create/bootstrap run, the agent must ask the operator to confirm the Firedancer `FD_VERSION` or provide a new tag. It must also ask for explicit paid Cherry server confirmation before create.

## Private env owns provider and bootstrap values

The real values live in /etc/solana-hotswap/hotswap.env, not in git.

Required Cherry/provider values:

- CHERRY_PROJECT_ID
- CHERRY_PLAN
- CHERRY_REGION
- CHERRY_IMAGE
- CHERRY_HOSTNAME
- CHERRY_SSH_KEY_ID
- CHERRY_VARIANT_IDS
- CHERRY_CYCLE
- CHERRY_SPOT_MARKET
- CHERRY_TAG_PURPOSE
- CHERRY_TAG_NETWORK
- CHERRY_TAG_OWNER
- CHERRY_TAG_CREATED_BY
- `CHERRY_RENTAL_CAP`
- `CHERRY_TARGET_AUTHORIZED_KEYS_FILE` optional private file containing OpenSSH public keys allowed into every Cherry target
- one of `CHERRY_KEY`, `CHERRY_AUTH_TOKEN`, `CHERRY_API_TOKEN`, or `JWT`

Required target bootstrap values:

- SOLANA_SETUP_REPO
- SOLANA_SETUP_BRANCH
- FD_VERSION
- FD_NETWORK
- FD_USER
- BAM_REGION
- SSH_ALLOW_CIDR
- SSH_PRIVATE_KEY_SHRED_AFTER_INSTALL
- CHERRY_BOOTSTRAP_DELAY_SECONDS
- CHERRY_BOOTSTRAP_TMUX, default true
- CHERRY_BOOTSTRAP_SESSION, default solana-bootstrap
- CHERRY_BOOTSTRAP_FOLLOW, default true
- `CHERRY_BOOTSTRAP_TIMEOUT_SECONDS`, default `14400`
- `CHERRY_BOOTSTRAP_MONITOR_INTERVAL_SECONDS`, default `120`
- `CHERRY_REBOOT_AFTER_BOOTSTRAP`, default `true`
- `TELEGRAM_CHAT_ID` plus `TELEGRAM_BOT_TOKEN` or `TELEGRAM_BOT_TOKEN_FILE` for notifications

Source-preflight values are not required for Cherry create/bootstrap, but are required before a real validator handoff:

- SOLANA_SOURCE
- SOLANA_VALIDATOR_IDENTITY

## SSH key rotation

Generate a dedicated local key outside git:

```bash
ssh-keygen -t ed25519 -f /home/sol/.ssh/cherry_solana_hotswap_YYYYMMDD -N "" -C "solana-hotswap-cherry-YYYYMMDD"
chmod 0600 /home/sol/.ssh/cherry_solana_hotswap_YYYYMMDD
chmod 0644 /home/sol/.ssh/cherry_solana_hotswap_YYYYMMDD.pub
```

Register its public key in Cherry through the API:

```bash
sudo -n /opt/solana-hot-swap-operator-kit/scripts/solana-cherry-hotswap-guard.sh \
  --env-file /etc/solana-hotswap/hotswap.env \
  cherry-create-ssh-key \
  --label solana-hotswap-cherry-YYYYMMDD \
  --public-key-file /home/sol/.ssh/cherry_solana_hotswap_YYYYMMDD.pub
```

Then update the private env only:

- `CHERRY_SSH_KEY_ID` to the returned Cherry key id
- `CHERRY_SSH_KEY` to the matching local private key path

Never commit the private key or the real provider key id.

## Main commands

Credit summary, no paid server and no full billing dump:

sudo -n /opt/solana-hot-swap-operator-kit/scripts/solana-cherry-hotswap-guard.sh --env-file /etc/solana-hotswap/hotswap.env cherry-credit-summary

Plan only, no paid server:

sudo -n env HOTSWAP_ENV_FILE=/etc/solana-hotswap/hotswap.env /opt/solana-hot-swap-operator-kit/scripts/cherry-mainnet-one-shot.sh --plan

Create one paid hourly Cherry server:

sudo -n env HOTSWAP_ENV_FILE=/etc/solana-hotswap/hotswap.env /opt/solana-hot-swap-operator-kit/scripts/cherry-mainnet-one-shot.sh --create

Continue bootstrap for the latest created state file:

sudo -n env HOTSWAP_ENV_FILE=/etc/solana-hotswap/hotswap.env /opt/solana-hot-swap-operator-kit/scripts/cherry-mainnet-one-shot.sh --bootstrap

Create and bootstrap in one command:

sudo -n env HOTSWAP_ENV_FILE=/etc/solana-hotswap/hotswap.env /opt/solana-hot-swap-operator-kit/scripts/cherry-mainnet-one-shot.sh --create-and-bootstrap

Delete server after final status and safety gate:

sudo -n env HOTSWAP_ENV_FILE=/etc/solana-hotswap/hotswap.env CONFIRM_DELETE_SERVER_ID=REPLACE_WITH_SERVER_ID /opt/solana-hot-swap-operator-kit/scripts/solana-cherry-hotswap-guard.sh cherry-delete

## Live state fields for private notes

- STATE_FILE=
- SERVER_ID=
- SERVER_IP=
- CREATED_AT_EPOCH=
- CREATE_RESULT=
- WAIT_IP_RESULT=
- VERIFY_RESULT=
- BOOTSTRAP_RESULT=
- POST_BOOTSTRAP_VERIFY_RESULT=
- DELETE_RESULT=

## Gates and meanings

- cherry-credit-summary: provider credit/resource snapshot before attempting paid create.
- cherry_project_empty=true: safe to create; no unexpected active Cherry hosts in project.
- state_file: local run state exists and should be used for later commands.
- SERVER_ID: provider billing object; use it for status/actions/delete.
- SERVER_IP: target SSH endpoint; wait for this before disk verification.
- cherry-wait-ssh: waits 15 minutes from create by default, then checks SSH every 2 minutes.
- Target bootstrap auto-detects root-capable SSH: it prefers root and uses ubuntu only if passwordless sudo works, unless CHERRY_TARGET_USER is set explicitly.
- Target bootstrap runs inside tmux by default. Attach on the target with `tmux attach -t solana-bootstrap`.
- If `CHERRY_TARGET_AUTHORIZED_KEYS_FILE` is set, bootstrap creates a restricted `solana-keydrop` SFTP-only chroot user by default. Uploaded validator keys land in `/var/lib/solana-keydrop/incoming`; they do not grant shell/root access.
- After successful bootstrap, the one-shot flow disables `fire`/`sync-monitor` until keys are staged, reboots the target by default, waits for SSH to return, verifies again, and sends Telegram notification that the target is ready for key staging.
- Bootstrap status file: `/root/solana-cherry-bootstrap.status`.
- Bootstrap tmux log: `/root/solana-cherry-bootstrap.tmux.log`.
- attempt-after-create: prints rental deadlines, provider actions, SSH/disk/no-RAID gate.
- cherry_disk_gate=ok: target disk layout is safe enough for bootstrap.
- post-bootstrap-verify: checks target after bootstrap and shows logs/service state.

## Hard stop rules

- Credit/billing is insufficient for provider create.
- Cherry project is not empty before create.
- Provider creates a server without a parseable SERVER_ID.
- No SERVER_IP appears before timeout.
- SSH does not become reachable after the 15-minute initial delay and polling timeout.
- SSH key is rejected by both ubuntu and root.
- mdraid is active or linux_raid_member disks are present.
- No clean unformatted NVMe data disk exists.
- Target bootstrap script cannot find required safety features in fire-full-setup.sh.
- Bootstrap tmux session exits without `/root/solana-cherry-bootstrap.status`.
- Bootstrap fails before post-bootstrap verification.
- Any production validator keypair/tower material is present on the temporary host before explicit handoff stage.

## Identity handoff

After target bootstrap and reboot pass, upload keypairs from the source/main-sol host through the restricted SFTP-only user. Live public target IPs must be supplied at runtime only, never committed to git.

Preferred manual source-side dry-run on main-sol:

```bash
TARGET_IP=REPLACE_WITH_TARGET_IP \
  /path/to/solana-hot-swap-operator-kit/scripts/solana-source-upload-keys.sh --dry-run
```

Then execute manually on main-sol:

```bash
TARGET_IP=REPLACE_WITH_TARGET_IP \
  CONFIRM_SOLANA_KEY_UPLOAD=I_CONFIRM_SOLANA_KEY_UPLOAD \
  /path/to/solana-hot-swap-operator-kit/scripts/solana-source-upload-keys.sh --execute
```

The operator/OpenClaw host should not run this source-side upload script and should never handle validator keypair contents.

Then key staging/start/sync is a separate confirmed operation from the operator host:

```bash
sudo -n env HOTSWAP_ENV_FILE=/etc/solana-hotswap/hotswap.env \
  TARGET_HOST=ubuntu@REPLACE_WITH_TARGET_IP \
  CONFIRM_TARGET_STAGE_START=I_CONFIRM_TARGET_STAGE_START \
  /opt/solana-hot-swap-operator-kit/scripts/solana-target-stage-start-sync.sh --execute --all-from-keydrop
```

This moves keypairs from keydrop incoming to `/home/ubuntu/keys`, runs `setup-ramdisk-keys.sh`, shreds/removes incoming copies by default, enables and starts `fire.service`, waits for sync/catchup, and sends Telegram notification when the target is ready for identity handoff.

After target bootstrap/catchup gates pass, use `docs/identity-handoff.md` and `scripts/solana-identity-handoff.sh` for the guarded `set-identity`, tower copy, and remote `set-identity --require-tower` flow.

The handoff script defaults to dry-run and requires `CONFIRM_SOLANA_IDENTITY_HANDOFF=I_CONFIRM_IDENTITY_HANDOFF` for execution.

## If create is blocked by payment

Expected symptom:

Cherry API POST projects/.../servers failed with HTTP 402
Payment Required / Insufficient balance

Action:

1. Do not retry in a loop.
2. Confirm the project is still empty with --plan or cherry-list.
3. Top up the Cherry account or switch to an approved provider/project with enough credit.
4. Re-run cherry-credit-summary and then --plan before the next --create.

## Reference host cleanup

After importing a reference host, move sensitive files to a root-only backup first, then delete the user-level copies only after confirming local import success.

Never delete broad .env files globally. Clean only the explicitly imported Cherry/Solana paths.
