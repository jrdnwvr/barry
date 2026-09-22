"""The shared tendency fixture is what the Python table says. The Swift test
reads the same file, so the two tables cannot drift apart silently."""
import json
from pathlib import Path

import pytest

from app import tendency

FIXTURE = Path(__file__).parent / "fixtures" / "tendency_cases.json"
CASES = json.loads(FIXTURE.read_text())["cases"]


@pytest.mark.parametrize("case", CASES, ids=[str(c["delta3h"]) for c in CASES])
def test_fixture_matches_the_python_table(case):
    assert tendency.classify(case["delta3h"]) == case["class"]
    assert tendency.intensity(case["delta3h"]) == pytest.approx(case["intensity"], abs=5e-4)


def test_fixture_covers_every_class_and_both_sides_of_each_threshold():
    classes = {c["class"] for c in CASES}
    assert classes == {"rising_fast", "rising", "steady", "falling", "falling_mod", "falling_fast"}
    for t in (tendency.RISING_FAST, tendency.RISING, tendency.STEADY, tendency.FALLING, tendency.FALLING_MOD):
        deltas = [c["delta3h"] for c in CASES]
        assert any(abs(d - t) < 0.02 and d < t for d in deltas) and any(abs(d - t) < 0.02 and d >= t for d in deltas)
