PYTHON ?= python3

.PHONY: check
check:
	$(PYTHON) -m py_compile solana_validator_hotswap/*.py scripts/*.py
	bash -n scripts/*.sh
	if command -v node >/dev/null 2>&1 && node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' >/dev/null 2>&1; then node --check relay/openclaw-codex-relay.mjs; fi
	$(PYTHON) scripts/redaction-check.py .
