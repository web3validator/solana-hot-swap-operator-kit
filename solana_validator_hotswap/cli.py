from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path
from urllib import error, request

VERSION = "0.1.0"


SOURCE_PREFLIGHT_REMOTE = r"""
set -euo pipefail
section() { printf "\n== %s ==\n" "$1"; }
RPC="${SOLANA_RPC_URL:-https://api.testnet.solana.com}"
IDENTITY="${SOLANA_VALIDATOR_IDENTITY:?missing SOLANA_VALIDATOR_IDENTITY}"
MAX_DELINQUENT="${SOLANA_MAX_DELINQUENT_PERCENT:-10}"
SERVICE=""
if systemctl is-active --quiet fire.service; then
  SERVICE="fire.service"
elif systemctl list-unit-files solana.service >/dev/null 2>&1; then
  SERVICE="solana.service"
else
  echo "BLOCKER: no supported Solana validator service found" >&2
  exit 10
fi
SOLANA_BIN="${SOLANA_BIN:-}"
if [ -z "$SOLANA_BIN" ]; then
  SOLANA_BIN="$(command -v solana || true)"
fi
GOSSIP_BIN="${SOLANA_GOSSIP_BIN:-}"
if [ -z "$GOSSIP_BIN" ]; then
  GOSSIP_BIN="$(command -v solana-gossip || true)"
fi
VALIDATOR_BIN="${SOLANA_VALIDATOR_BIN:-}"
if [ -z "$VALIDATOR_BIN" ]; then
  VALIDATOR_BIN="$(command -v agave-validator || command -v solana-validator || true)"
fi
if [ "$SERVICE" = "fire.service" ] && [ -z "$VALIDATOR_BIN" ]; then
  VALIDATOR_BIN="$(systemctl cat fire.service | grep -oE '/[^[:space:]]+/fdctl' | head -n1 || true)"
fi
LEDGER="${SOLANA_LEDGER_PATH:-/mnt/ledger}"
SNAPSHOTS="${SOLANA_SNAPSHOT_PATH:-/mnt/snapshots}"
section "Host"
hostname
date -u +"utc=%Y-%m-%dT%H:%M:%SZ"
section "Service"
printf 'service=%s\n' "$SERVICE"
systemctl is-active "$SERVICE"
systemctl is-enabled "$SERVICE" || true
systemctl cat "$SERVICE" | grep -E "active_release|expected-shred-version|experimental-retransmit-xdp|maximum-local-snapshot-age|require-tower|entrypoint|fdctl|config.toml" || true
if [ -n "$VALIDATOR_BIN" ] && [ -x "$VALIDATOR_BIN" ]; then
  "$VALIDATOR_BIN" --version || true
fi
section "RPC Health"
curl -fsS -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' "$RPC"
printf '\n'
section "Cluster Delinquency"
if [ -z "$SOLANA_BIN" ] || [ ! -x "$SOLANA_BIN" ]; then
  echo "BLOCKER: solana CLI not found" >&2
  exit 11
fi
export SOLANA_BIN RPC IDENTITY MAX_DELINQUENT
python3 -c '
import json, os, subprocess, sys
solana=os.environ["SOLANA_BIN"]
rpc=os.environ["RPC"]
identity=os.environ["IDENTITY"]
max_delinquent=float(os.environ["MAX_DELINQUENT"])
data=json.loads(subprocess.check_output([solana,"--url",rpc,"validators","--output","json"], timeout=45))
current=int(data.get("totalCurrentStake") or 0)
delinquent=int(data.get("totalDelinquentStake") or 0)
pct=(delinquent/current*100.0) if current else 100.0
ours=[v for v in data.get("validators",[]) if v.get("identityPubkey")==identity]
print(f"total_current_stake={current}")
print(f"total_delinquent_stake={delinquent}")
print(f"delinquent_percent={pct:.4f}")
if ours:
    v=ours[0]
    print("our_identity=%s" % v.get("identityPubkey"))
    print("our_vote=%s" % v.get("voteAccountPubkey"))
    print("our_version=%s client=%s" % (v.get("version"), v.get("clientId")))
    print("our_delinquent=%s" % v.get("delinquent"))
    print("our_last_vote=%s root_slot=%s" % (v.get("lastVote"), v.get("rootSlot")))
else:
    print("our_validator=NOT_FOUND")
if pct >= max_delinquent:
    sys.exit("BLOCKER: delinquent stake is above threshold")
if not ours or ours[0].get("delinquent"):
    sys.exit("BLOCKER: own validator missing or delinquent")
'
section "Entrypoint DNS"
for ep in entrypoint.testnet.solana.com entrypoint2.testnet.solana.com entrypoint3.testnet.solana.com; do
  printf '%s ' "$ep"
  getent ahosts "$ep" | awk 'NR==1 {print $1}' || true
done
section "Gossip Shred Version"
if [ -n "$GOSSIP_BIN" ] && [ -x "$GOSSIP_BIN" ]; then
  timeout 25 "$GOSSIP_BIN" spy --entrypoint entrypoint.testnet.solana.com:8001 --entrypoint entrypoint2.testnet.solana.com:8001 --entrypoint entrypoint3.testnet.solana.com:8001 --num-nodes 10 --timeout 15 2>&1 | awk -v id="$IDENTITY" '/obtained shred-version/ || /IP Address/ || /ShredVer/ || index($0, id) {print}' || true
else
  echo "solana-gossip not found; verify shred version by another source before XDP changes."
fi
section "Disk And Snapshots"
df -h / /mnt/data /mnt/accounts "$LEDGER" "$SNAPSHOTS" 2>/dev/null || true
if [ -d "$SNAPSHOTS" ]; then
  find "$SNAPSHOTS" -maxdepth 1 -type f \( -name 'snapshot-*.tar.zst' -o -name 'incremental-snapshot-*.tar.zst' \) -printf '%T@ %s %p\n' 2>/dev/null | sort -nr | head -n 8 | awk '{size=$2; $1=$2=""; sub(/^  */, ""); printf "%10.2f GiB %s\n", size/1024/1024/1024, $0}' || true
fi
section "Leader Slots"
export RPC IDENTITY
python3 -c '
import json, os, urllib.request
rpc=os.environ["RPC"]
identity=os.environ["IDENTITY"]
def call(method, params=None):
    data=json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params or []}).encode()
    req=urllib.request.Request(rpc, data=data, headers={"Content-Type":"application/json"})
    out=json.load(urllib.request.urlopen(req, timeout=8))
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]
epoch=call("getEpochInfo")
schedule=call("getLeaderSchedule", [None, {"identity": identity}]) or {}
slots=schedule.get(identity, [])
current=epoch["absoluteSlot"]
first=current-epoch["slotIndex"]
future=[first+s for s in slots if first+s>=current]
print(f"current_slot={current}")
print(f"next_slots={future[:12]}")
if future:
    print(f"next_delta_slots={future[0]-current}")
    print(f"approx_minutes={round((future[0]-current)*0.4/60, 1)}")
'
section "Read-only Result"
echo "preflight_complete=true"
echo "No files changed, no service restarted."
"""


SOURCE_SECONDARY_REMOTE = r"""
set -euo pipefail
STAKED="${SOLANA_STAKED_IDENTITY_PATH:?missing SOLANA_STAKED_IDENTITY_PATH}"
SECONDARY="${SOLANA_SOURCE_SECONDARY_IDENTITY_PATH:?missing SOLANA_SOURCE_SECONDARY_IDENTITY_PATH}"
VOTE="${SOLANA_VOTE_KEYPAIR_PATH:?missing SOLANA_VOTE_KEYPAIR_PATH}"
KEYGEN="${SOLANA_KEYGEN_BIN:-}"
if [ -z "$KEYGEN" ]; then
  KEYGEN="$(command -v solana-keygen || true)"
fi
if [ -z "$KEYGEN" ] || [ ! -x "$KEYGEN" ]; then
  echo "BLOCKER: solana-keygen not found on source host" >&2
  exit 60
fi
for f in "$STAKED" "$SECONDARY" "$VOTE"; do
  if [ ! -s "$f" ]; then
    echo "BLOCKER: missing or empty key file: $f" >&2
    exit 61
  fi
done
staked_pub="$($KEYGEN pubkey "$STAKED")"
secondary_pub="$($KEYGEN pubkey "$SECONDARY")"
vote_pub="$($KEYGEN pubkey "$VOTE")"
printf 'source_staked_pubkey=%s\n' "$staked_pub"
printf 'source_hotswap_secondary_pubkey=%s\n' "$secondary_pub"
printf 'source_vote_pubkey=%s\n' "$vote_pub"
if [ "$secondary_pub" = "$staked_pub" ]; then
  echo "BLOCKER: source secondary equals staked identity" >&2
  exit 62
fi
if [ "$secondary_pub" = "$vote_pub" ]; then
  echo "BLOCKER: source secondary equals vote key" >&2
  exit 63
fi
echo "source_hotswap_secondary_gate=ok"
"""


CHERRY_VERIFY_REMOTE = r"""
set -euo pipefail
echo "ssh_user=$(whoami)"
hostname
date -u +"utc=%Y-%m-%dT%H:%M:%SZ"
echo "== disks =="
lsblk -e7 -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
echo "== mdraid =="
cat /proc/mdstat || true
if grep -q '^md' /proc/mdstat 2>/dev/null; then
  echo "BLOCKER: mdraid device is active" >&2
  exit 30
fi
if lsblk -nr -o FSTYPE | grep -q '^linux_raid_member$'; then
  echo "BLOCKER: linux_raid_member disks are present" >&2
  exit 31
fi
free_nvme="$(lsblk -J -e7 -o NAME,TYPE,FSTYPE,MOUNTPOINTS | python3 -c '
import json, sys
data=json.load(sys.stdin)
count=0
for dev in data.get("blockdevices", []):
    if dev.get("type") != "disk" or not str(dev.get("name", "")).startswith("nvme"):
        continue
    mountpoints=[m for m in (dev.get("mountpoints") or []) if m]
    if dev.get("fstype") or mountpoints or dev.get("children"):
        continue
    count += 1
print(count)
')"
echo "free_unformatted_nvme_count=$free_nvme"
if [ "$free_nvme" -lt 1 ]; then
  echo "BLOCKER: no free NVMe data disk found" >&2
  exit 32
fi
echo "cherry_disk_gate=ok"
"""


POST_BOOTSTRAP_REMOTE = r"""
set -euo pipefail
whoami
hostname
date -u +"utc=%Y-%m-%dT%H:%M:%SZ"
systemctl is-active ssh || systemctl is-active sshd || true
tmux ls 2>/dev/null || true
pgrep -af 'install-runner|fire-full-setup|apt-get|git clone|make|gcc|cargo|fdctl' || true
lsblk -e7 -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
cat /proc/mdstat || true
if command -v sudo >/dev/null 2>&1; then
  sudo bash -c 'log=$(ls -1t /root/fire-full-setup-*.log 2>/dev/null | head -n1 || true); if [ -n "$log" ]; then tail -120 "$log"; fi' || true
else
  tail -120 /root/fire-full-setup-*.log 2>/dev/null || true
fi
systemctl is-active fire 2>/dev/null || true
systemctl is-active solana 2>/dev/null || true
echo "post_bootstrap_gate=ok"
"""


SAFETY_REMOTE = r"""
set -euo pipefail
blocked=0
echo "host=$(hostname)"
echo "utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
systemctl is-active fire 2>/dev/null || true
systemctl is-active solana 2>/dev/null || true
if pgrep -af 'fdctl|solana-validator|agave-validator|frankendancer|firedancer' >/tmp/validator-hotswap-pgrep.txt 2>/dev/null; then
  echo "DELETE_BLOCKER: validator-like process is present"
  cat /tmp/validator-hotswap-pgrep.txt
  blocked=1
fi
if find /mnt/ramdisk /mnt/ledger /home/ubuntu /home/sol /root -maxdepth 4 -type f \( -name '*identity*.json' -o -name '*vote*.json' -o -name '*voter*.json' -o -name 'tower-*.bin' \) -print -quit 2>/dev/null | grep -q .; then
  echo "DELETE_BLOCKER: validator key/tower-like file is present"
  find /mnt/ramdisk /mnt/ledger /home/ubuntu /home/sol /root -maxdepth 4 -type f \( -name '*identity*.json' -o -name '*vote*.json' -o -name '*voter*.json' -o -name 'tower-*.bin' \) -printf '%p\n' 2>/dev/null || true
  blocked=1
fi
if [ "$blocked" -eq 1 ]; then
  exit 51
fi
echo "delete_safety_gate=ok"
"""


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def fail(message: str, code: int = 2) -> None:
    print(f"BLOCKER: {message}", file=sys.stderr)
    raise SystemExit(code)


def env_any(names: tuple[str, ...], default: str = "") -> str:
    for name in names:
        value = env(name)
        if value:
            return value
    return default


def require_env_any(*names: str) -> str:
    value = env_any(tuple(names))
    if not value:
        fail(f"one of {', '.join(names)} is required")
    return value


def require_env(name: str) -> str:
    value = env(name)
    if not value:
        fail(f"{name} is required")
    return value


def require_int_env(name: str) -> int:
    value = require_env(name)
    try:
        return int(value)
    except ValueError:
        fail(f"{name} must be an integer")


def load_env_file(path: str) -> None:
    if not path:
        return
    p = Path(path)
    if not p.exists():
        fail(f"env file not found: {path}")
    for raw in p.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def redacted(value):
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            lowered = str(key).lower()
            if any(
                part in lowered
                for part in ("token", "secret", "password", "private", "jwt")
            ):
                out[key] = "<redacted>"
            else:
                out[key] = redacted(item)
        return out
    if isinstance(value, list):
        return [redacted(item) for item in value]
    return value


def print_json(value) -> None:
    print(json.dumps(value, indent=2, sort_keys=True))


def api_base() -> str:
    return env("CHERRY_API_BASE", "https://api.cherryservers.com/v1").rstrip("/")


def api_request(method: str, path: str, body=None):
    token = require_env_any("CHERRY_KEY", "CHERRY_AUTH_TOKEN", "CHERRY_API_TOKEN")
    url = f"{api_base()}/{path.lstrip('/')}"
    data = None
    if body is not None:
        data = json.dumps(body).encode()
    req = request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with request.urlopen(req, timeout=int(env("CHERRY_API_TIMEOUT", "30"))) as res:
            raw = res.read()
            if not raw:
                return None, res.status
            return json.loads(raw.decode()), res.status
    except error.HTTPError as exc:
        text = exc.read().decode("utf-8", "replace")
        if text:
            print(text, file=sys.stderr)
        fail(f"Cherry API {method} {path} failed with HTTP {exc.code}", 1)
    except error.URLError as exc:
        fail(f"Cherry API {method} {path} failed: {exc}", 1)


def project_id() -> str:
    return require_env("CHERRY_PROJECT_ID")


def server_id() -> str:
    return require_env("SERVER_ID")


def server_ip() -> str:
    return require_env("SERVER_IP")


def default_variant_ids() -> list[int]:
    raw = env("CHERRY_VARIANT_IDS")
    if not raw:
        return []
    return [int(part) for part in raw.replace(",", " ").split() if part]


def cherry_order_payload() -> dict:
    ssh_key_id = require_int_env("CHERRY_SSH_KEY_ID")
    payload = {
        "plan": env("CHERRY_PLAN", "amd-ryzen-9950x"),
        "region": env("CHERRY_REGION", "LT-Siauliai"),
        "image": env("CHERRY_IMAGE", "ubuntu_24_04_64bit"),
        "hostname": env("CHERRY_HOSTNAME", "solana-hotswap"),
        "ssh_keys": [ssh_key_id],
        "cycle": env("CHERRY_CYCLE", "hourly"),
        "spot_market": env("CHERRY_SPOT_MARKET", "false").lower() == "true",
        "tags": {
            "purpose": env("CHERRY_TAG_PURPOSE", "solana-validator-hotswap"),
            "owner": env("CHERRY_TAG_OWNER", "solana-operator"),
            "created_by": env("CHERRY_TAG_CREATED_BY", "solana-hot-swap-operator-kit"),
            "rental_cap": env("CHERRY_RENTAL_CAP", "120m"),
        },
    }
    variants = default_variant_ids()
    if variants:
        payload["variant_ids"] = variants
    return payload


def extract_server(value):
    if isinstance(value, dict):
        for key in ("server", "data", "result"):
            item = value.get(key)
            if isinstance(item, dict):
                return item
        return value
    if isinstance(value, list) and value and isinstance(value[0], dict):
        return value[0]
    return {}


def extract_ip(server: dict) -> str:
    values = server.get("ip_addresses") or server.get("ips") or []
    if isinstance(values, dict):
        values = list(values.values())
    for item in values:
        if isinstance(item, dict):
            addr = item.get("address") or item.get("ip")
        else:
            addr = str(item)
        if addr:
            return addr
    return server.get("ip") or server.get("primary_ip") or ""


def ssh_args(key: str = "", known_hosts: str = "") -> list[str]:
    args = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        f"ConnectTimeout={env('SSH_CONNECT_TIMEOUT', '8')}",
        "-o",
        "ServerAliveInterval=10",
        "-o",
        "ServerAliveCountMax=2",
    ]
    if known_hosts:
        Path(known_hosts).parent.mkdir(parents=True, exist_ok=True)
        Path(known_hosts).touch(exist_ok=True)
        args.extend(
            [
                "-o",
                "StrictHostKeyChecking=accept-new",
                "-o",
                f"UserKnownHostsFile={known_hosts}",
            ]
        )
    if key:
        args.extend(["-i", key])
    return args


def run_remote(
    host: str,
    script: str,
    remote_env: dict[str, str] | None = None,
    key: str = "",
    known_hosts: str = "",
) -> None:
    prefix = ""
    if remote_env:
        prefix = (
            " ".join(
                f"{name}={shlex.quote(value)}" for name, value in remote_env.items()
            )
            + " "
        )
    cmd = f"{prefix}bash -s"
    subprocess.run(
        ssh_args(key, known_hosts) + [host, cmd], input=script, text=True, check=True
    )


def cmd_show_config(_args) -> None:
    data = {
        "solana": {
            "network": env("SOLANA_NETWORK", "testnet"),
            "source": env("SOLANA_SOURCE"),
            "identity": env_any(("SOLANA_IDENTITY", "SOLANA_VALIDATOR_IDENTITY")),
            "rpc": env("SOLANA_RPC_URL", "https://api.testnet.solana.com"),
        },
        "cherry": {
            "api_base": api_base(),
            "project_id": env("CHERRY_PROJECT_ID"),
            "plan": env("CHERRY_PLAN", "amd-ryzen-9950x"),
            "region": env("CHERRY_REGION", "LT-Siauliai"),
            "image": env("CHERRY_IMAGE", "ubuntu_24_04_64bit"),
            "ssh_key_id": env("CHERRY_SSH_KEY_ID"),
            "token_present": bool(env_any(("CHERRY_KEY", "CHERRY_AUTH_TOKEN", "CHERRY_API_TOKEN"))),
        },
    }
    print_json(data)


def cmd_cherry_order_payload(_args) -> None:
    print_json(cherry_order_payload())


def cmd_cherry_list(_args=None):
    data, _ = api_request("GET", f"projects/{project_id()}/servers")
    servers = data or []
    if isinstance(servers, dict):
        servers = servers.get("data") or servers.get("servers") or []
    active = []
    for server in servers:
        sid = server.get("id")
        hostname = server.get("hostname") or server.get("name") or "-"
        status = str(server.get("status") or "-")
        state = str(server.get("state") or "-")
        plan = server.get("plan") or {}
        region = server.get("region") or {}
        plan_name = (
            plan.get("slug") or plan.get("name") or "-"
            if isinstance(plan, dict)
            else "-"
        )
        region_name = (
            region.get("slug") or region.get("name") or "-"
            if isinstance(region, dict)
            else "-"
        )
        ip = extract_ip(server) or "-"
        print(
            f"id={sid} status={status} state={state} host={hostname} plan={plan_name} region={region_name} ip={ip}"
        )
        if status.lower() not in {"terminated", "deleted"} and state.lower() not in {
            "terminated",
            "deleted",
        }:
            active.append(sid)
    if active:
        fail(f"active Cherry servers exist in project: {active}", 20)
    print("cherry_project_empty=true")
    return servers


def cmd_cherry_balance(_args) -> None:
    data, _ = api_request("GET", "teams")
    print_json(redacted(data))


def attempt_dir() -> Path:
    p = Path(env("HOTSWAP_RUN_DIR", "runs/cherry-attempts"))
    p.mkdir(parents=True, exist_ok=True)
    return p


def cmd_cherry_create(_args) -> None:
    if env("CONFIRM_PAID_CHERRY_CREATE") != "I_CONFIRM_ONE_HOURLY_SERVER":
        fail(
            "set CONFIRM_PAID_CHERRY_CREATE=I_CONFIRM_ONE_HOURLY_SERVER after explicit operator confirmation"
        )
    print("== pre-create cherry-list ==")
    cmd_cherry_list(None)
    payload = cherry_order_payload()
    ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out_dir = attempt_dir()
    payload_file = out_dir / f"cherry-create-{ts}.json"
    response_file = out_dir / f"cherry-create-{ts}.response.redacted.json"
    state_file = out_dir / f"cherry-create-{ts}.env"
    payload_file.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print("== creating one paid hourly Cherry server ==")
    response_data, _ = api_request("POST", f"projects/{project_id()}/servers", payload)
    response_file.write_text(
        json.dumps(redacted(response_data), indent=2, sort_keys=True) + "\n"
    )
    server = extract_server(response_data)
    sid = str(server.get("id") or server.get("server_id") or "")
    ip = extract_ip(server)
    created_epoch = int(time.time())
    state_file.write_text(
        f"export SERVER_ID={sid}\nexport SERVER_IP={ip}\nexport CREATED_AT_EPOCH={created_epoch}\n# payload_file={payload_file}\n# response_file={response_file}\n"
    )
    print(f"state_file={state_file}")
    print(f"export SERVER_ID={sid}")
    print(f"export SERVER_IP={ip}")
    print(f"export CREATED_AT_EPOCH={created_epoch}")
    if not sid:
        fail("could not parse server id from Cherry create response")
    print("NEXT: wait until SERVER_IP is reachable, then run attempt-after-create.")


def cmd_cherry_actions(_args) -> None:
    data, _ = api_request("GET", f"servers/{server_id()}/actions")
    print_json(redacted(data))


def cmd_cherry_rebuild_payload(_args) -> None:
    ssh_key_id = require_int_env("CHERRY_SSH_KEY_ID")
    payload = {
        "type": "rebuild",
        "image": env("CHERRY_IMAGE", "ubuntu_24_04_64bit"),
        "hostname": env("CHERRY_HOSTNAME", "solana-hotswap"),
        "password": env("ROOT_PASSWORD_PLACEHOLDER", "<temporary-root-password>"),
        "ssh_keys": [ssh_key_id],
        "os_partition_size": int(env("CHERRY_OS_PARTITION_SIZE", "1024")),
        "os_raid_level": env("CHERRY_OS_RAID_LEVEL", "No RAID - OS on first disk"),
        "os_disk": env("CHERRY_OS_DISK", "NVMe 1TB"),
        "user_data": env("CHERRY_USER_DATA"),
        "ipxe": env("CHERRY_IPXE"),
    }
    print_json(payload)


def cmd_deadline(args) -> None:
    raw = args.created_at_epoch or env("CREATED_AT_EPOCH")
    if not raw:
        fail("CREATED_AT_EPOCH is required")
    start = int(raw)
    for minutes, label in (
        (10, "SSH and RAID verification complete"),
        (30, "bootstrap running or finished"),
        (60, "snapshot finder/catchup clearly progressing"),
        (90, "continue vs abort decision"),
        (110, "cleanup starts"),
        (120, "delete server unless explicitly extended"),
    ):
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start + minutes * 60))
        print(f"T+{minutes:03d}m {ts} {label}")


def cherry_known_hosts() -> str:
    return env("CHERRY_KNOWN_HOSTS", "runs/known_hosts")


def cmd_cherry_verify(_args) -> None:
    ip = server_ip()
    key = env("CHERRY_SSH_KEY")
    last = None
    for user in ("ubuntu", "root"):
        try:
            run_remote(
                f"{user}@{ip}",
                CHERRY_VERIFY_REMOTE,
                key=key,
                known_hosts=cherry_known_hosts(),
            )
            print(f"cherry_ssh_user={user}")
            return
        except subprocess.CalledProcessError as exc:
            last = exc
            if exc.returncode in {30, 31, 32}:
                raise
    if last:
        fail(
            "neither ubuntu nor root accepted the Cherry SSH key", last.returncode or 33
        )
    fail("Cherry SSH verification failed", 33)


def cmd_post_bootstrap_verify(_args) -> None:
    ip = server_ip()
    key = env("CHERRY_SSH_KEY")
    last = None
    for user in ("ubuntu", "root"):
        try:
            run_remote(
                f"{user}@{ip}",
                POST_BOOTSTRAP_REMOTE,
                key=key,
                known_hosts=cherry_known_hosts(),
            )
            print(f"post_bootstrap_ssh_user={user}")
            return
        except subprocess.CalledProcessError as exc:
            last = exc
    if last:
        fail(
            "SSH is reachable but neither ubuntu nor root accepted the Cherry key",
            last.returncode or 41,
        )
    fail("post-bootstrap verification failed", 41)


def cmd_attempt_after_create(args) -> None:
    require_env("SERVER_ID")
    require_env("SERVER_IP")
    require_env("CREATED_AT_EPOCH")
    print("== rental deadlines ==")
    cmd_deadline(args)
    print("\n== cherry actions ==")
    cmd_cherry_actions(args)
    print("\n== cherry verify ==")
    cmd_cherry_verify(args)
    print(
        "NEXT: bootstrap only after cherry-verify is green. Do not stage validator keys before post-bootstrap-verify passes."
    )


def run_safety_gate(strict: bool) -> None:
    ip = env("SERVER_IP")
    if not ip:
        print(
            "WARN: SERVER_IP is unset; cannot inspect temporary host over SSH",
            file=sys.stderr,
        )
        return
    try:
        run_remote(
            f"ubuntu@{ip}",
            SAFETY_REMOTE,
            key=env("CHERRY_SSH_KEY"),
            known_hosts=cherry_known_hosts(),
        )
    except subprocess.CalledProcessError as exc:
        if (
            exc.returncode == 51
            and strict
            and env("CONFIRM_DELETE_WITH_MATERIAL") != "I_ACCEPT_RISK"
        ):
            fail(
                "refusing delete because validator process/key/tower material was detected",
                51,
            )
        if strict and exc.returncode != 51:
            print(
                "WARN: could not inspect temporary host over SSH before delete",
                file=sys.stderr,
            )
        if not strict:
            print("temporary_host_safety_gate=blocked_or_unreachable", file=sys.stderr)


def cmd_final_status(args) -> None:
    require_env("SERVER_ID")
    print("== Cherry billing state ==")
    data, _ = api_request("GET", f"servers/{server_id()}")
    print_json(redacted(data))
    print("\n== temporary host safety check ==")
    run_safety_gate(False)
    print(
        "FINAL STATUS: continue with exact next command, pause with explicit rental extension, or clean up and delete."
    )


def cmd_cherry_delete(args) -> None:
    sid = server_id()
    if env("CONFIRM_DELETE_SERVER_ID") != sid:
        fail(f"set CONFIRM_DELETE_SERVER_ID={sid} before deleting")
    print("== pre-delete final status ==")
    cmd_final_status(args)
    run_safety_gate(True)
    print(f"\n== deleting Cherry server {sid} ==")
    _data, status = api_request("DELETE", f"servers/{sid}")
    print(f"delete_http_status={status}")
    if status not in {200, 202, 204}:
        fail(f"unexpected Cherry delete status {status}", 50)
    print("\n== post-delete cherry-list ==")
    cmd_cherry_list(args)


def cmd_source_preflight(_args) -> None:
    host = require_env("SOLANA_SOURCE")
    identity = require_env_any("SOLANA_IDENTITY", "SOLANA_VALIDATOR_IDENTITY")
    remote_env = {
        "SOLANA_RPC_URL": env("SOLANA_RPC_URL", "https://api.testnet.solana.com"),
        "SOLANA_VALIDATOR_IDENTITY": identity,
        "SOLANA_MAX_DELINQUENT_PERCENT": env("SOLANA_MAX_DELINQUENT_PERCENT", "10"),
        "SOLANA_LEDGER_PATH": env("SOLANA_LEDGER_PATH", "/mnt/ledger"),
        "SOLANA_SNAPSHOT_PATH": env("SOLANA_SNAPSHOT_PATH", "/mnt/snapshots"),
        "SOLANA_BIN": env("SOLANA_BIN"),
        "SOLANA_GOSSIP_BIN": env("SOLANA_GOSSIP_BIN"),
        "SOLANA_VALIDATOR_BIN": env("SOLANA_VALIDATOR_BIN"),
    }
    run_remote(host, SOURCE_PREFLIGHT_REMOTE, remote_env, key=env("SOLANA_SSH_KEY"))


def cmd_source_secondary_verify(_args) -> None:
    host = require_env("SOLANA_SOURCE")
    remote_env = {
        "SOLANA_STAKED_IDENTITY_PATH": env(
            "SOLANA_STAKED_IDENTITY_PATH", "/home/sol/solana/staked-identity.json"
        ),
        "SOLANA_SOURCE_SECONDARY_IDENTITY_PATH": env(
            "SOLANA_SOURCE_SECONDARY_IDENTITY_PATH",
            "/home/sol/solana/source-secondary-identity.json",
        ),
        "SOLANA_VOTE_KEYPAIR_PATH": env(
            "SOLANA_VOTE_KEYPAIR_PATH", "/home/sol/solana/vote-account-keypair.json"
        ),
        "SOLANA_KEYGEN_BIN": env("SOLANA_KEYGEN_BIN"),
    }
    run_remote(host, SOURCE_SECONDARY_REMOTE, remote_env, key=env("SOLANA_SSH_KEY"))


def cmd_attempt_preflight(args) -> None:
    print("== source secondary verify ==")
    cmd_source_secondary_verify(args)
    print("\n== source preflight ==")
    cmd_source_preflight(args)
    print("\n== cherry list ==")
    cmd_cherry_list(args)
    print("\n== guarded order payload ==")
    cmd_cherry_order_payload(args)
    print("NEXT: get explicit operator confirmation before cherry-create.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="solana-validator-hotswap")
    parser.add_argument(
        "--env-file",
        default="",
        help="load KEY=VALUE entries before running the command",
    )
    parser.add_argument("--version", action="version", version=VERSION)
    sub = parser.add_subparsers(dest="command")
    commands = {
        "show-config": cmd_show_config,
        "cherry-order-payload": cmd_cherry_order_payload,
        "cherry-list": cmd_cherry_list,
        "cherry-balance": cmd_cherry_balance,
        "cherry-create": cmd_cherry_create,
        "cherry-actions": cmd_cherry_actions,
        "cherry-rebuild-payload": cmd_cherry_rebuild_payload,
        "cherry-verify": cmd_cherry_verify,
        "post-bootstrap-verify": cmd_post_bootstrap_verify,
        "attempt-after-create": cmd_attempt_after_create,
        "final-status": cmd_final_status,
        "attempt-final-status": cmd_final_status,
        "cherry-delete": cmd_cherry_delete,
        "source-preflight": cmd_source_preflight,
        "source-secondary-verify": cmd_source_secondary_verify,
        "attempt-preflight": cmd_attempt_preflight,
    }
    for name, func in commands.items():
        p = sub.add_parser(name)
        p.set_defaults(func=func)
    p = sub.add_parser("deadline")
    p.add_argument("--created-at-epoch", default="")
    p.set_defaults(func=cmd_deadline)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    load_env_file(args.env_file)
    if not hasattr(args, "func"):
        parser.print_help()
        return 0
    try:
        args.func(args)
        return 0
    except subprocess.CalledProcessError as exc:
        return exc.returncode or 1


if __name__ == "__main__":
    raise SystemExit(main())
