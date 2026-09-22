"""Regenerate tests/fixtures/tendency_cases.json from app/tendency.py.

    python tools/gen_tendency_fixture.py

The Swift table in ios/Barry/Shared/Tendency.swift is checked against the
same file, so a threshold change here fails the Swift test until it is
mirrored by hand, which is the point.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app import tendency  # noqa: E402

DELTAS = [-6.0, -4.5, -4.0, -3.99, -3.5, -3.01, -3.0, -2.99, -2.4, -2.0, -1.51, -1.5, -1.49, -1.0, -0.51, -0.5,
          -0.49, -0.1, 0.0, 0.1, 0.49, 0.5, 0.51, 1.0, 1.49, 1.5, 1.51, 2.0, 3.0, 4.0, 4.5, 6.0]

if __name__ == "__main__":
    cases = [{"delta3h": d, "class": tendency.classify(d), "intensity": round(tendency.intensity(d), 3)} for d in DELTAS]
    doc = {"_": "3 h pressure tendency: the class and intensity both apps must agree on for each delta (hPa). "
                "Generated from backend/app/tendency.py, the source of truth; read by tests/test_tendency_fixture.py "
                "and ios/Barry/iOSAppTests/TendencyParityTests.swift. Regenerate with tools/gen_tendency_fixture.py.",
           "cases": cases}
    out = Path(__file__).resolve().parents[1] / "tests" / "fixtures" / "tendency_cases.json"
    out.write_text(json.dumps(doc, indent=1) + "\n")
    print(f"{len(cases)} cases -> {out}")
