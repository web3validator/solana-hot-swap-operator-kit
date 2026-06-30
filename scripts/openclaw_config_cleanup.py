#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

OMNIROUTE_PORT_MARKERS = ("localhost:20128", "127.0.0.1:20128", "[::1]:20128")
OMNIROUTE_PROVIDER_NAMES = {"kiro", "omniroute"}
OMNIROUTE_MODEL_PREFIXES = ("kiro/", "omniroute/")
DEFAULT_PRIMARY_MODEL = "codex/gpt-5.5"
DEFAULT_FALLBACK_MODEL = "openai/gpt-5.5"


def load_json(path: Path) -> Any | None:
    if not path.exists():
        return None
    return json.loads(path.read_text())


def write_json(path: Path, data: Any, dry_run: bool) -> bool:
    new_text = json.dumps(data, indent=2, sort_keys=True) + "\n"
    old_text = path.read_text() if path.exists() else ""
    changed = new_text != old_text
    if changed and not dry_run:
        path.write_text(new_text)
    return changed


def has_omniroute_base_url(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    base_url = str(
        value.get("baseUrl") or value.get("baseURL") or value.get("base_url") or ""
    )
    return any(marker in base_url for marker in OMNIROUTE_PORT_MARKERS)


def provider_is_omniroute(name: str, value: Any) -> bool:
    return name.lower() in OMNIROUTE_PROVIDER_NAMES or has_omniroute_base_url(value)


def model_is_omniroute(name: str) -> bool:
    return name.lower() in OMNIROUTE_PROVIDER_NAMES or name.startswith(
        OMNIROUTE_MODEL_PREFIXES
    )


def cleanup_provider_catalog(data: dict[str, Any]) -> bool:
    changed = False
    providers = data.get("providers")
    if isinstance(providers, dict):
        for name in list(providers):
            if provider_is_omniroute(name, providers[name]):
                providers.pop(name)
                changed = True
    return changed


def cleanup_auth_profiles(data: dict[str, Any]) -> bool:
    profiles = data.get("profiles")
    if not isinstance(profiles, dict):
        return False
    profile = profiles.get("anthropic:manual")
    if (
        isinstance(profile, dict)
        and profile.get("provider") == "anthropic"
        and profile.get("type") in {"token", "api_key"}
    ):
        profiles.pop("anthropic:manual")
        return True
    return False


def cleanup_openclaw_config(data: dict[str, Any]) -> bool:
    changed = False
    models = data.get("models")
    if isinstance(models, dict):
        providers = models.get("providers")
        if isinstance(providers, dict):
            for name in list(providers):
                if provider_is_omniroute(name, providers[name]):
                    providers.pop(name)
                    changed = True

    defaults = (
        data.get("agents", {}).get("defaults", {})
        if isinstance(data.get("agents"), dict)
        else {}
    )
    if isinstance(defaults, dict):
        model_cfg = defaults.get("model")
        if isinstance(model_cfg, dict):
            primary = str(model_cfg.get("primary") or "")
            if model_is_omniroute(primary):
                model_cfg["primary"] = DEFAULT_PRIMARY_MODEL
                changed = True
            fallbacks = model_cfg.get("fallbacks")
            if isinstance(fallbacks, list):
                cleaned = [
                    item
                    for item in fallbacks
                    if isinstance(item, str) and not model_is_omniroute(item)
                ]
                if DEFAULT_FALLBACK_MODEL not in cleaned:
                    cleaned.append(DEFAULT_FALLBACK_MODEL)
                if cleaned != fallbacks:
                    model_cfg["fallbacks"] = cleaned
                    changed = True
        configured_models = defaults.get("models")
        if isinstance(configured_models, dict):
            for name in list(configured_models):
                if model_is_omniroute(name):
                    configured_models.pop(name)
                    changed = True
            if DEFAULT_PRIMARY_MODEL not in configured_models:
                configured_models[DEFAULT_PRIMARY_MODEL] = {}
                changed = True
            if DEFAULT_FALLBACK_MODEL not in configured_models:
                configured_models[DEFAULT_FALLBACK_MODEL] = {}
                changed = True
    return changed


def process(path: Path, dry_run: bool) -> str:
    data = load_json(path)
    if data is None:
        return f"missing {path}"
    if not isinstance(data, dict):
        return f"skipped non-object {path}"
    if path.name == "openclaw.json":
        changed = cleanup_openclaw_config(data)
    elif path.name == "auth-profiles.json":
        changed = cleanup_auth_profiles(data)
    else:
        changed = cleanup_provider_catalog(data)
    wrote = write_json(path, data, dry_run) if changed else False
    if changed and dry_run:
        return f"would_update {path}"
    if wrote:
        return f"updated {path}"
    return f"ok {path}"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Remove OmniRoute/localhost:20128 model routing from OpenClaw JSON config files."
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args()

    if args.paths:
        paths = [Path(item).expanduser() for item in args.paths]
    else:
        home = Path.home()
        paths = [
            home / ".openclaw" / "openclaw.json",
            home / ".openclaw" / "agents" / "main" / "agent" / "models.json",
            home / ".openclaw" / "agents" / "main" / "agent" / "auth-profiles.json",
        ]

    for path in paths:
        print(process(path, args.dry_run))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
