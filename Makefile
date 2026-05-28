PYTHON ?= python3

.PHONY: check
check:
	$(PYTHON) -m py_compile solana_validator_hotswap/*.py
	bash -n scripts/*.sh
	$(PYTHON) scripts/redaction-check.py .
