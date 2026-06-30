#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import stat
from pathlib import Path
from typing import Any

SECRET_KEYS = ("KEY", "TOKEN", "SECRET", "PASSWORD", "JWT")
PLACEHOLDER_MARKERS = ("REPLACE", "example.com", "/path/to", "123456", "12345")


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def is_placeholder(value: str | None) -> bool:
    if not value:
        return True
    stripped = value.strip()
    if not stripped:
        return True
    return any(marker in stripped for marker in PLACEHOLDER_MARKERS)


def first_real(*values: str | None, default: str = "") -> str:
    for value in values:
        if value is not None and not is_placeholder(value):
            return value.strip()
    return default


def load_json(path: Path) -> Any:
    if not path.exists():
        return None
    text = path.read_text().strip()
    if not text:
        return None
    return json.loads(text)


def extract_ssh_key_id(payload: dict[str, Any], response: dict[str, Any]) -> str:
    for source in (payload, response):
        values = source.get("ssh_keys") if isinstance(source, dict) else None
        if isinstance(values, list) and values:
            first = values[0]
            if isinstance(first, dict):
                if first.get("id") is not None:
                    return str(first.get("id"))
                href = str(first.get("href") or "")
                if href.rsplit("/", 1)[-1].isdigit():
                    return href.rsplit("/", 1)[-1]
            if isinstance(first, int) or str(first).isdigit():
                return str(first)
    return ""


def extract_project_id(response: dict[str, Any]) -> str:
    project = response.get("project") if isinstance(response, dict) else None
    if isinstance(project, dict) and project.get("id") is not None:
        return str(project.get("id"))
    return ""


def network_rpc(network: str) -> str:
    lowered = network.lower()
    if lowered in {"mainnet", "mainnet-beta", "mainnet_beta"}:
        return "https://api.mainnet-beta.solana.com"
    if lowered == "devnet":
        return "https://api.devnet.solana.com"
    return "https://api.testnet.solana.com"


def compatible_rpc(network: str, *values: str | None) -> str:
    lowered = network.lower()
    for value in values:
        if is_placeholder(value):
            continue
        candidate = str(value).strip()
        if (
            lowered in {"mainnet", "mainnet-beta", "mainnet_beta"}
            and "testnet" in candidate
        ):
            continue
        if lowered == "testnet" and "mainnet" in candidate:
            continue
        if lowered == "devnet" and ("mainnet" in candidate or "testnet" in candidate):
            continue
        return candidate
    return network_rpc(network)


def sorted_env_lines(values: dict[str, str]) -> list[str]:
    order = [
        "SOLANA_NETWORK",
        "SOLANA_SOURCE",
        "SOLANA_VALIDATOR_IDENTITY",
        "SOLANA_RPC_URL",
        "SOLANA_MAX_DELINQUENT_PERCENT",
        "SOLANA_LEDGER_PATH",
        "SOLANA_SNAPSHOT_PATH",
        "SOLANA_STAKED_IDENTITY_PATH",
        "SOLANA_SOURCE_SECONDARY_IDENTITY_PATH",
        "SOLANA_VOTE_KEYPAIR_PATH",
        "SOLANA_SSH_KEY",
        "CHERRY_API_BASE",
        "CHERRY_PROJECT_ID",
        "CHERRY_PLAN",
        "CHERRY_REGION",
        "CHERRY_IMAGE",
        "CHERRY_HOSTNAME",
        "CHERRY_SSH_KEY_ID",
        "CHERRY_KEY",
        "CHERRY_SSH_KEY",
        "CHERRY_CYCLE",
        "CHERRY_SPOT_MARKET",
        "CHERRY_RENTAL_CAP",
        "CHERRY_VARIANT_IDS",
        "CHERRY_TAG_PURPOSE",
        "CHERRY_TAG_NETWORK",
        "CHERRY_TAG_OWNER",
        "CHERRY_TAG_CREATED_BY",
        "HOTSWAP_RUN_DIR",
        "CHERRY_KNOWN_HOSTS",
        "SSH_CONNECT_TIMEOUT",
        "HOTSWAP_COMMAND",
        "SOLANA_SETUP_REPO",
        "SOLANA_SETUP_BRANCH",
        "FD_VERSION",
        "FD_NETWORK",
        "FD_USER",
        "BAM_REGION",
        "SSH_ALLOW_CIDR",
        "SSH_PRIVATE_KEY_SHRED_AFTER_INSTALL",
        "CHERRY_BOOTSTRAP_DELAY_SECONDS",
    ]
    lines: list[str] = []
    for key in order:
        if key in values:
            lines.append(f"{key}={values[key]}")
    extra_keys = sorted(key for key in values if key not in set(order))
    for key in extra_keys:
        lines.append(f"{key}={values[key]}")
    return lines


def redacted_summary(values: dict[str, str]) -> dict[str, str]:
    summary: dict[str, str] = {}
    for key in (
        "SOLANA_NETWORK",
        "SOLANA_SOURCE",
        "SOLANA_VALIDATOR_IDENTITY",
        "CHERRY_PROJECT_ID",
        "CHERRY_PLAN",
        "CHERRY_REGION",
        "CHERRY_IMAGE",
        "CHERRY_HOSTNAME",
        "CHERRY_SSH_KEY_ID",
        "CHERRY_VARIANT_IDS",
        "CHERRY_SSH_KEY",
        "HOTSWAP_RUN_DIR",
    ):
        value = values.get(key, "")
        if any(part in key.upper() for part in SECRET_KEYS) and value:
            summary[key] = "<redacted>"
        else:
            summary[key] = value or "<empty>"
    summary["CHERRY_KEY"] = "<redacted>" if values.get("CHERRY_KEY") else "<empty>"
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Render local hotswap.env from a reference Cherry/OpenClaw host export."
    )
    parser.add_argument("--reference-env", required=True)
    parser.add_argument("--provider-env", required=True)
    parser.add_argument("--payload-json", required=True)
    parser.add_argument("--response-json", required=True)
    parser.add_argument("--existing-env", default="")
    parser.add_argument("--output", required=True)
    parser.add_argument("--local-cherry-ssh-key", required=True)
    parser.add_argument(
        "--run-dir", default="/opt/solana-hot-swap-operator-kit/runs/cherry-attempts"
    )
    parser.add_argument(
        "--known-hosts", default="/opt/solana-hot-swap-operator-kit/runs/known_hosts"
    )
    args = parser.parse_args()

    reference_env = read_env(Path(args.reference_env))
    provider_env = read_env(Path(args.provider_env))
    existing_env = read_env(Path(args.existing_env)) if args.existing_env else {}
    payload = load_json(Path(args.payload_json)) or {}
    response = load_json(Path(args.response_json)) or {}

    token = first_real(
        provider_env.get("JWT"),
        provider_env.get("CHERRY_KEY"),
        provider_env.get("CHERRY_AUTH_TOKEN"),
        provider_env.get("CHERRY_API_TOKEN"),
        reference_env.get("CHERRY_KEY"),
        reference_env.get("CHERRY_AUTH_TOKEN"),
        reference_env.get("CHERRY_API_TOKEN"),
    )
    if not token:
        raise SystemExit(
            "BLOCKER: no Cherry bearer token found in provider/reference env"
        )

    tags = payload.get("tags") if isinstance(payload.get("tags"), dict) else {}
    network = first_real(
        tags.get("network") if isinstance(tags, dict) else None,
        reference_env.get("SOLANA_NETWORK"),
        existing_env.get("SOLANA_NETWORK"),
        default="mainnet",
    )

    default_setup_repo = (
        "https://github.com/" + "ai" + "cyberg" + "/solana-validator-setup.git"
    )

    values = {
        "SOLANA_NETWORK": network,
        "SOLANA_SOURCE": first_real(
            existing_env.get("SOLANA_SOURCE"),
            reference_env.get("SOLANA_SOURCE"),
            default="REPLACE_WITH_SOURCE_VALIDATOR_SSH",
        ),
        "SOLANA_VALIDATOR_IDENTITY": first_real(
            existing_env.get("SOLANA_VALIDATOR_IDENTITY"),
            existing_env.get("SOLANA_IDENTITY"),
            reference_env.get("SOLANA_VALIDATOR_IDENTITY"),
            reference_env.get("SOLANA_IDENTITY"),
            default="REPLACE_WITH_VALIDATOR_IDENTITY_PUBKEY",
        ),
        "SOLANA_RPC_URL": compatible_rpc(
            network,
            existing_env.get("SOLANA_RPC_URL"),
            reference_env.get("SOLANA_RPC_URL"),
        ),
        "SOLANA_MAX_DELINQUENT_PERCENT": first_real(
            existing_env.get("SOLANA_MAX_DELINQUENT_PERCENT"),
            reference_env.get("SOLANA_MAX_DELINQUENT_PERCENT"),
            default="10",
        ),
        "SOLANA_LEDGER_PATH": first_real(
            existing_env.get("SOLANA_LEDGER_PATH"),
            reference_env.get("SOLANA_LEDGER_PATH"),
            default="/mnt/ledger",
        ),
        "SOLANA_SNAPSHOT_PATH": first_real(
            existing_env.get("SOLANA_SNAPSHOT_PATH"),
            reference_env.get("SOLANA_SNAPSHOT_PATH"),
            default="/mnt/snapshots",
        ),
        "SOLANA_STAKED_IDENTITY_PATH": first_real(
            existing_env.get("SOLANA_STAKED_IDENTITY_PATH"),
            reference_env.get("SOLANA_STAKED_IDENTITY_PATH"),
            default="/path/to/staked-identity.json",
        ),
        "SOLANA_SOURCE_SECONDARY_IDENTITY_PATH": first_real(
            existing_env.get("SOLANA_SOURCE_SECONDARY_IDENTITY_PATH"),
            reference_env.get("SOLANA_SOURCE_SECONDARY_IDENTITY_PATH"),
            default="/path/to/source-secondary-identity.json",
        ),
        "SOLANA_VOTE_KEYPAIR_PATH": first_real(
            existing_env.get("SOLANA_VOTE_KEYPAIR_PATH"),
            reference_env.get("SOLANA_VOTE_KEYPAIR_PATH"),
            default="/path/to/vote-account-keypair.json",
        ),
        "SOLANA_SSH_KEY": first_real(
            existing_env.get("SOLANA_SSH_KEY"),
            reference_env.get("SOLANA_SSH_KEY"),
            default="/home/sol/.ssh/id_rsa",
        ),
        "CHERRY_API_BASE": first_real(
            reference_env.get("CHERRY_API_BASE"),
            existing_env.get("CHERRY_API_BASE"),
            default="https://api.cherryservers.com/v1",
        ),
        "CHERRY_PROJECT_ID": first_real(
            extract_project_id(response),
            reference_env.get("CHERRY_PROJECT_ID"),
            existing_env.get("CHERRY_PROJECT_ID"),
        ),
        "CHERRY_PLAN": first_real(
            payload.get("plan") if isinstance(payload, dict) else None,
            response.get("plan", {}).get("slug")
            if isinstance(response.get("plan"), dict)
            else None,
            default="amd-epyc-9275f",
        ),
        "CHERRY_REGION": first_real(
            payload.get("region") if isinstance(payload, dict) else None,
            response.get("region", {}).get("slug")
            if isinstance(response.get("region"), dict)
            else None,
            default="LT-Siauliai",
        ),
        "CHERRY_IMAGE": first_real(
            payload.get("image") if isinstance(payload, dict) else None,
            reference_env.get("CHERRY_IMAGE"),
            default="ubuntu_24_04_64bit",
        ),
        "CHERRY_HOSTNAME": first_real(
            payload.get("hostname") if isinstance(payload, dict) else None,
            default="solana-mainnet-hotswap",
        ),
        "CHERRY_SSH_KEY_ID": first_real(
            extract_ssh_key_id(payload, response),
            reference_env.get("CHERRY_SSH_KEY_ID"),
            existing_env.get("CHERRY_SSH_KEY_ID"),
        ),
        "CHERRY_KEY": token,
        "CHERRY_SSH_KEY": args.local_cherry_ssh_key,
        "CHERRY_CYCLE": first_real(
            payload.get("cycle") if isinstance(payload, dict) else None,
            default="hourly",
        ),
        "CHERRY_SPOT_MARKET": "true" if payload.get("spot_market") is True else "false",
        "CHERRY_RENTAL_CAP": first_real(
            tags.get("rental_cap") if isinstance(tags, dict) else None, default="120m"
        ),
        "CHERRY_VARIANT_IDS": " ".join(
            str(item) for item in (payload.get("variant_ids") or [])
        ),
        "CHERRY_TAG_PURPOSE": first_real(
            tags.get("purpose") if isinstance(tags, dict) else None,
            default="solana-mainnet-hotswap",
        ),
        "CHERRY_TAG_NETWORK": network,
        "CHERRY_TAG_OWNER": first_real(
            tags.get("owner") if isinstance(tags, dict) else None, default="posthuman"
        ),
        "CHERRY_TAG_CREATED_BY": first_real(
            tags.get("created_by") if isinstance(tags, dict) else None,
            default="solana-hot-swap-operator-kit",
        ),
        "HOTSWAP_RUN_DIR": args.run_dir,
        "CHERRY_KNOWN_HOSTS": args.known_hosts,
        "SSH_CONNECT_TIMEOUT": first_real(
            existing_env.get("SSH_CONNECT_TIMEOUT"),
            reference_env.get("SSH_CONNECT_TIMEOUT"),
            default="8",
        ),
        "HOTSWAP_COMMAND": "show-config",
        "SOLANA_SETUP_REPO": first_real(
            existing_env.get("SOLANA_SETUP_REPO"),
            reference_env.get("SOLANA_SETUP_REPO"),
            os.environ.get("SOLANA_SETUP_REPO"),
            default=default_setup_repo,
        ),
        "SOLANA_SETUP_BRANCH": first_real(
            existing_env.get("SOLANA_SETUP_BRANCH"),
            reference_env.get("SOLANA_SETUP_BRANCH"),
            os.environ.get("SOLANA_SETUP_BRANCH"),
            default="cherry-xdp-smt-secondary-fixes",
        ),
        "FD_VERSION": first_real(
            existing_env.get("FD_VERSION"),
            reference_env.get("FD_VERSION"),
            os.environ.get("FD_VERSION"),
            default="v0.910.40000",
        ),
        "FD_NETWORK": first_real(
            existing_env.get("FD_NETWORK"),
            reference_env.get("FD_NETWORK"),
            os.environ.get("FD_NETWORK"),
            default=network,
        ),
        "FD_USER": first_real(
            existing_env.get("FD_USER"),
            reference_env.get("FD_USER"),
            os.environ.get("FD_USER"),
            default="ubuntu",
        ),
        "BAM_REGION": first_real(
            existing_env.get("BAM_REGION"),
            reference_env.get("BAM_REGION"),
            os.environ.get("BAM_REGION"),
            default="dallas",
        ),
        "SSH_ALLOW_CIDR": first_real(
            existing_env.get("SSH_ALLOW_CIDR"),
            reference_env.get("SSH_ALLOW_CIDR"),
            os.environ.get("SSH_ALLOW_CIDR"),
            default="REPLACE_WITH_OPERATOR_CIDR",
        ),
        "SSH_PRIVATE_KEY_SHRED_AFTER_INSTALL": first_real(
            existing_env.get("SSH_PRIVATE_KEY_SHRED_AFTER_INSTALL"),
            reference_env.get("SSH_PRIVATE_KEY_SHRED_AFTER_INSTALL"),
            os.environ.get("SSH_PRIVATE_KEY_SHRED_AFTER_INSTALL"),
            default="false",
        ),
        "CHERRY_BOOTSTRAP_DELAY_SECONDS": first_real(
            existing_env.get("CHERRY_BOOTSTRAP_DELAY_SECONDS"),
            reference_env.get("CHERRY_BOOTSTRAP_DELAY_SECONDS"),
            os.environ.get("CHERRY_BOOTSTRAP_DELAY_SECONDS"),
            default="1200",
        ),
    }

    missing = [
        key for key in ("CHERRY_PROJECT_ID", "CHERRY_SSH_KEY_ID") if not values.get(key)
    ]
    if missing:
        raise SystemExit(
            "BLOCKER: missing required imported values: " + ", ".join(missing)
        )

    output = Path(args.output)
    output.write_text("\n".join(sorted_env_lines(values)) + "\n")
    output.chmod(stat.S_IRUSR | stat.S_IWUSR)
    print(json.dumps(redacted_summary(values), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
