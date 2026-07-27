"""Tests for the context-aware prioritisation model.

Run from prioritization-service/:  python -m pytest test_scoring.py -q
(or plain `python test_scoring.py` for a no-pytest smoke run)

The headline case is `test_medium_on_bank_beats_high_on_hr`: it encodes the
whole reason this model exists, so if it ever fails the model has stopped
doing its job regardless of what the other numbers say.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from assets import Asset, AssetInventory  # noqa: E402
from scoring import ScoreInput, compute_score, priority_band, technical_factor, threat_factor  # noqa: E402

INVENTORY = AssetInventory.load(os.path.join(os.path.dirname(__file__), "asset-inventory.yaml"))
BANK = next(a for a in INVENTORY.assets if a.name == "juice-shop")
HR = next(a for a in INVENTORY.assets if a.name == "dvwa")


def score(**kwargs):
    return compute_score(ScoreInput(**kwargs))


# --- the case the model exists for --------------------------------------


def test_medium_on_bank_beats_high_on_hr():
    """A MEDIUM on the internet-facing payments portal must outrank a HIGH on
    the internal HR box. Severity alone would order these the other way."""
    bank_medium = score(cvss=5.5, severity="Medium", epss=0.02, epss_percentile=0.50, asset=BANK)
    hr_high = score(cvss=8.0, severity="High", epss=0.02, epss_percentile=0.50, asset=HR)

    assert bank_medium.priority > hr_high.priority, (
        f"bank medium={bank_medium.priority} should beat hr high={hr_high.priority}\n"
        f"  {bank_medium.explanation}\n  {hr_high.explanation}"
    )


def test_inventory_matches_the_configured_lab_profile():
    """juice-shop 5/5 internet-facing, dvwa 1/5 internal."""
    assert BANK.business_criticality == 5 and BANK.internet_facing
    assert HR.business_criticality == 1 and not HR.internet_facing


def test_same_bug_scores_higher_when_internet_facing():
    exposed = score(cvss=7.0, epss_percentile=0.6, asset=BANK)
    internal = score(cvss=7.0, epss_percentile=0.6, asset=HR)
    assert exposed.priority > internal.priority
    assert exposed.multiplier > 1.0 > internal.multiplier


# --- asset resolution ----------------------------------------------------


def test_resolves_asset_from_scanner_tags():
    asset, how = INVENTORY.resolve({"tags": ["web", "nuclei", "juice-shop"]})
    assert asset.name == "juice-shop" and how.startswith("tag:")


def test_resolves_grype_image_alias_to_the_right_asset():
    # grype imports tag findings with the image short name, not the target.
    asset, _ = INVENTORY.resolve({"tags": ["container", "grype", "web-dvwa"]})
    assert asset.name == "dvwa"


def test_resolves_from_endpoint_when_tags_are_missing():
    asset, how = INVENTORY.resolve(
        {"tags": [], "endpoints": [{"host": "juice-shop.targets.svc.cluster.local"}]}
    )
    assert asset.name == "juice-shop" and how.startswith("endpoint:")


def test_unknown_asset_falls_back_to_defaults_not_an_error():
    asset, how = INVENTORY.resolve({"tags": ["web", "nuclei", "some-other-box"]})
    assert how == "unresolved"
    assert asset.business_criticality == INVENTORY.default.business_criticality


def test_explicit_tag_overrides_everything():
    asset, how = INVENTORY.resolve({"tags": ["dvwa", "voc-asset-juice-shop"]})
    assert asset.name == "juice-shop" and how == "explicit-tag"


# --- technical / threat terms -------------------------------------------


def test_severity_word_is_used_when_no_cvss():
    """Nuclei/sqlmap/ffuf findings have a severity and no CVSS. Before this
    fallback existed they were dropped from prioritisation entirely."""
    factor, note = technical_factor(None, "High")
    assert factor == 0.75 and note == "cvss-from-severity"

    result = score(cvss=None, severity="Critical", asset=BANK)
    assert result.priority > 0
    assert "no-scoreable-data" not in result.notes


def test_finding_with_nothing_to_score_is_flagged():
    result = score(cvss=None, severity=None, asset=BANK)
    assert "no-scoreable-data" in result.notes


def test_kev_dominates_the_threat_term():
    factor, note = threat_factor(0.001, 0.10, kev=True)
    assert factor == 1.0 and note == "kev-listed"


def test_kev_floor_lifts_a_damped_finding():
    """Actively-exploited bugs must not be buried by a low-value asset. A
    low-CVSS KEV bug on the internal HR box scores ~52 on the weights alone;
    the floor pulls it back to 70."""
    result = score(cvss=2.0, epss=0.001, epss_percentile=0.1, kev=True, asset=HR)
    assert result.priority == 70, result.explanation
    assert "kev-floor-applied" in result.notes


def test_kev_finding_above_the_floor_keeps_its_computed_score():
    result = score(cvss=9.0, epss=0.5, epss_percentile=0.95, kev=True, asset=BANK)
    assert result.priority > 70
    assert "kev-floor-applied" not in result.notes


def test_epss_probability_is_not_flattened_to_zero():
    """Raw EPSS probabilities are tiny; sqrt() keeps them meaningful."""
    low, _ = threat_factor(0.0005, 0.05)
    high, _ = threat_factor(0.25, 0.05)
    assert high > 0.4 > low


def test_missing_epss_uses_the_unknown_prior_not_zero():
    factor, note = threat_factor(None, None)
    assert 0 < factor < 0.5 and note == "epss-missing"


# --- bands and bounds ----------------------------------------------------


def test_priority_stays_in_range_at_the_extremes():
    worst = score(cvss=10.0, epss=1.0, epss_percentile=1.0, kev=True, asset=BANK)
    best = score(cvss=0.1, epss=0.0, epss_percentile=0.0, asset=HR)
    assert 0 <= best.priority <= worst.priority <= 100
    assert worst.band == "critical"


def test_bands_map_onto_defectdojo_severities():
    assert priority_band(95) == "critical"
    assert priority_band(65) == "high"
    assert priority_band(45) == "medium"
    assert priority_band(25) == "low"
    assert priority_band(5) == "info"


def test_context_can_be_disabled_by_flattening_the_multiplier():
    flat = compute_score(
        ScoreInput(cvss=7.0, epss_percentile=0.5, asset=BANK),
        context_min_multiplier=1.0,
        context_max_multiplier=1.0,
    )
    assert flat.multiplier == 1.0
    assert flat.priority == round(flat.base)


def test_context_tags_describe_the_decision():
    tags = BANK.context_tags()
    assert "voc-asset-juice-shop" in tags
    assert "voc-exposure-internet" in tags
    assert "voc-crit-5" in tags
    assert "voc-internet-facing" in tags


def test_broken_inventory_path_degrades_to_defaults():
    inv = AssetInventory.load("/nonexistent/asset-inventory.yaml")
    # Falls back to the copy shipped next to the module rather than exploding.
    assert isinstance(inv.default, Asset)


if __name__ == "__main__":
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"PASS {name}")
            except AssertionError as exc:
                failures += 1
                print(f"FAIL {name}: {exc}")
    # Show the headline comparison so the numbers are visible, not just green.
    bank = score(cvss=5.5, severity="Medium", epss=0.02, epss_percentile=0.50, asset=BANK)
    hr = score(cvss=8.0, severity="High", epss=0.02, epss_percentile=0.50, asset=HR)
    print(f"\n  MEDIUM on bank : {bank.priority:3d} [{bank.band}]  {bank.explanation}")
    print(f"  HIGH   on HR   : {hr.priority:3d} [{hr.band}]  {hr.explanation}")
    print(f"\n{'FAILURES: ' + str(failures) if failures else 'all tests passed'}")
    sys.exit(1 if failures else 0)
