from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

SKIP_DIRS = {
    ".git",
    "runs",
    "__pycache__",
    ".pytest_cache",
    "node_modules",
    ".venv",
    "venv",
}
ALLOWED_FILENAMES = {".env.example"}
FORBIDDEN_TEXT = [
    "POST" + "HUMAN",
    "web" + "34ever",
    "ai" + "cyberg",
    "196" + "890",
    "146" + "15",
    "889" + "430",
    "889" + "483",
    "888" + "315",
    "888" + "607",
    "886" + "854",
]
PRIVATE_KEY_RE = re.compile(r"BEGIN (?:OPENSSH|RSA|DSA|EC|PGP) PRIVATE KEY")
IP_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
TOKEN_ASSIGN_RE = re.compile(
    r"(?m)^\s*(?:CHERRY_KEY|[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_KEY|PRIVATE_KEY|JWT))[ \t]*=[ \t]*[^\s#]+"
)


def is_private_filename(path: Path) -> bool:
    name = path.name
    lowered = name.lower()
    if name in ALLOWED_FILENAMES or lowered.endswith(".env.example"):
        return False
    if lowered == ".env" or lowered.startswith(".env."):
        return True
    if lowered in {"id_rsa", "id_ed25519"}:
        return True
    if lowered.endswith((".pem", ".key")):
        return True
    if lowered.endswith(".json") and (
        "keypair" in lowered or "identity" in lowered or "wallet" in lowered
    ):
        return True
    if lowered.endswith(".bin") and "tower" in lowered:
        return True
    return False


def is_public_ip(value: str) -> bool:
    parts = [int(part) for part in value.split(".")]
    if parts[0] == 127 or parts[0] == 0:
        return False
    if parts[0] == 10:
        return False
    if parts[0] == 192 and parts[1] == 168:
        return False
    if parts[0] == 172 and 16 <= parts[1] <= 31:
        return False
    return all(0 <= part <= 255 for part in parts)


def is_git_ignored(root: Path, path: Path) -> bool:
    rel = path.relative_to(root)
    result = subprocess.run(
        ["git", "-C", str(root), "check-ignore", "--quiet", "--", str(rel)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def iter_files(root: Path):
    for path in root.rglob("*"):
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        if path.is_file() and not is_git_ignored(root, path):
            yield path


def check(root: Path) -> list[str]:
    issues: list[str] = []
    for path in iter_files(root):
        rel = path.relative_to(root)
        if is_private_filename(path):
            issues.append(f"private-looking filename: {rel}")
            continue
        try:
            text = path.read_text(errors="ignore")
        except OSError as exc:
            issues.append(f"cannot read {rel}: {exc}")
            continue
        for forbidden in FORBIDDEN_TEXT:
            if forbidden in text:
                issues.append(f"forbidden private label in {rel}: {forbidden}")
        if PRIVATE_KEY_RE.search(text):
            issues.append(f"private key material in {rel}")
        for match in TOKEN_ASSIGN_RE.finditer(text):
            value = match.group(0).split("=", 1)[1].strip()
            if (
                value
                and not value.startswith("REPLACE_")
                and not value.startswith("REPLACE_WITH_")
                and value not in {"", "<temporary-root-password>"}
            ):
                issues.append(f"non-placeholder secret assignment in {rel}")
        for match in IP_RE.finditer(text):
            ip = match.group(0)
            if is_public_ip(ip):
                issues.append(f"public IPv4 literal in {rel}: {ip}")
    return issues


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    root = Path(args[0] if args else ".").resolve()
    issues = check(root)
    if issues:
        for issue in issues:
            print(issue, file=sys.stderr)
        return 1
    print("redaction_check=ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
