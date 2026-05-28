#!/usr/bin/env python3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from solana_validator_hotswap.redaction import main

raise SystemExit(main())
