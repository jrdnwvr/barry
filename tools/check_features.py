#!/usr/bin/env python3
"""Keep docs/FEATURES.md honest.

Every settings key the apps store and every route the backend serves must
be named in the feature registry. Run from the repo root:

    python3 tools/check_features.py

Exit code 1 lists what is missing. No third-party packages.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "docs" / "FEATURES.md"
IOS = ROOT / "ios" / "Barry"
MAIN = ROOT / "backend" / "app" / "main.py"

# Keys that are internal plumbing rather than something a person can set
# or a maintainer must know about. Keep this list short.
IGNORED_KEYS = set()


def settings_keys() -> set[str]:
    keys: set[str] = set()
    patterns = [
        re.compile(r'@AppStorage\("([^"]+)"'),
        re.compile(r'static let \w*[kK]ey\w* = "([^"]+)"'),
    ]
    for path in IOS.rglob("*.swift"):
        if "Tests" in path.parts:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for pat in patterns:
            keys.update(pat.findall(text))
    return {k for k in keys if k not in IGNORED_KEYS}


def routes() -> set[str]:
    text = MAIN.read_text(encoding="utf-8")
    return set(re.findall(r'@app\.(?:get|post|put|delete)\("([^"]+)"', text))


def main() -> int:
    registry = REGISTRY.read_text(encoding="utf-8")
    missing_keys = sorted(k for k in settings_keys() if k not in registry)
    missing_routes = sorted(r for r in routes() if r not in registry)
    if not missing_keys and not missing_routes:
        print("FEATURES.md covers every settings key and route.")
        return 0
    if missing_keys:
        print("Settings keys not in docs/FEATURES.md:")
        for k in missing_keys:
            print(f"  {k}")
    if missing_routes:
        print("Routes not in docs/FEATURES.md:")
        for r in missing_routes:
            print(f"  {r}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
