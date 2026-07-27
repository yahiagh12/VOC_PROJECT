"""VOC prioritisation model.

The point of this model is that severity alone is the wrong unit of work.
"HIGH" on an internal HR box is not the same job as "MEDIUM" on the
internet-facing payments portal — the second one is what gets you breached
this week. So a score here is three things multiplied together, not one
number copied off a CVE page:

    priority = base(technical, threat) x context(asset)

  technical  How broken is it?      CVSS 0-10, or the scanner's severity
                                    word when no CVSS exists (most DAST
                                    findings have no CVSS at all).
  threat     Is anyone using it?    EPSS probability + percentile, and CISA
                                    KEV as a hard floor for "already
                                    exploited in the wild".
  context    Does it matter here?   Internet exposure, business criticality
                                    (1-5) and data classification of the
                                    asset the finding lives on.

`base` is a weighted blend on 0..100. `context` is a multiplier in
[context_min_multiplier, context_max_multiplier] — below 1.0 it damps a
finding on a throwaway box, above 1.0 it amplifies one on a crown jewel.
The multiplier range is deliberately wide enough to reorder findings ACROSS
severity bands, because that reordering is the entire product.

Worked example with the shipped defaults and inventory:

    MEDIUM (CVSS 5.5) on juice-shop  — internet, crit 5/5, financial data
        base 52 x 1.60  ->  84  CRITICAL
    HIGH   (CVSS 8.0) on dvwa        — internal, crit 1/5, internal data
        base 65 x 0.79  ->  51  MEDIUM

Every number that decides an outcome is exposed in ScoreResult so the
explanation written back to DefectDojo can be audited, and every weight is
a setting in config.py so the model can be tuned without a code change.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from assets import Asset

# Scanner severity words -> a stand-in CVSS. Most web findings (nuclei, ffuf,
# sqlmap, xsstrike) carry a severity string and no CVSS vector at all; without
# this fallback they scored 0 and were dropped from prioritisation entirely.
SEVERITY_TO_CVSS: dict[str, float] = {
    "critical": 9.5,
    "high": 7.5,
    "medium": 5.0,
    "low": 3.0,
    "info": 1.0,
    "informational": 1.0,
    "none": 0.0,
}

# Priority band cut-offs. Names match DefectDojo severities so the band can be
# written straight back onto the finding.
BANDS: tuple[tuple[int, str], ...] = (
    (80, "critical"),
    (60, "high"),
    (40, "medium"),
    (20, "low"),
    (0, "info"),
)

# Used when EPSS has nothing for a CVE, or the finding has no CVE at all.
# Slightly below neutral: absence of evidence is not evidence of safety, but
# it must not outweigh a measured score.
UNKNOWN_THREAT = 0.15


@dataclass(frozen=True)
class ScoreInput:
    """Everything the model needs about one finding."""

    cvss: float | None = None
    severity: str | None = None          # scanner-reported, e.g. "High"
    epss: float | None = None            # exploitation probability 0..1
    epss_percentile: float | None = None # rank among all CVEs 0..1
    kev: bool = False                    # listed in CISA KEV
    cve: str | None = None
    asset: Asset = field(default_factory=Asset)


@dataclass(frozen=True)
class ScoreResult:
    priority: int
    band: str
    technical: float      # 0..1
    threat: float         # 0..1
    context: float        # 0..1 composite context score
    multiplier: float     # context expressed as a multiplier
    base: float           # 0..100 before context
    notes: tuple[str, ...]
    explanation: str

    def as_dict(self) -> dict:
        return {
            "priority": self.priority,
            "band": self.band,
            "technical": round(self.technical, 3),
            "threat": round(self.threat, 3),
            "context": round(self.context, 3),
            "multiplier": round(self.multiplier, 3),
            "base": round(self.base, 1),
            "notes": list(self.notes),
            "explanation": self.explanation,
        }


def technical_factor(cvss: float | None, severity: str | None) -> tuple[float, str | None]:
    """CVSS on 0..1, falling back to the scanner's severity word."""
    if cvss is not None:
        try:
            value = float(cvss)
        except (TypeError, ValueError):
            value = -1.0
        if 0.0 <= value <= 10.0:
            return value / 10.0, None

    if severity:
        mapped = SEVERITY_TO_CVSS.get(str(severity).strip().lower())
        if mapped is not None:
            return mapped / 10.0, "cvss-from-severity"

    return 0.0, "no-technical-score"


def threat_factor(
    epss: float | None,
    epss_percentile: float | None,
    kev: bool = False,
) -> tuple[float, str | None]:
    """Exploitation likelihood on 0..1.

    EPSS probabilities are tiny in absolute terms (the median CVE sits around
    0.0005), so using the raw probability would flatten this term to zero for
    almost everything. We take the larger of:

      * the percentile, which is already a 0..1 ranking, and
      * sqrt(probability), which lifts the small-but-real probabilities into a
        usable range (1% -> 0.10, 25% -> 0.50, 90% -> 0.95)

    so a CVE that is either widely-ranked OR individually likely scores high,
    and one that is both does not get double-counted.
    """
    if kev:
        return 1.0, "kev-listed"

    candidates: list[float] = []
    if epss_percentile is not None:
        try:
            pct = float(epss_percentile)
            if 0.0 <= pct <= 1.0:
                candidates.append(pct)
        except (TypeError, ValueError):
            pass
    if epss is not None:
        try:
            prob = float(epss)
            if 0.0 <= prob <= 1.0:
                candidates.append(math.sqrt(prob))
        except (TypeError, ValueError):
            pass

    if not candidates:
        return UNKNOWN_THREAT, "epss-missing"
    return max(candidates), None


def context_score(
    asset: Asset,
    *,
    exposure_weight: float = 0.4,
    criticality_weight: float = 0.4,
    data_weight: float = 0.2,
) -> float:
    """Blend the asset's factors into a single 0..1 context score."""
    total_weight = exposure_weight + criticality_weight + data_weight
    if total_weight <= 0:
        return 0.5
    weighted = (
        exposure_weight * asset.exposure_factor
        + criticality_weight * asset.criticality_factor
        + data_weight * asset.data_factor
    )
    return max(0.0, min(1.0, weighted / total_weight))


def compute_score(
    inp: ScoreInput,
    *,
    cvss_weight: float = 0.5,
    epss_weight: float = 0.5,
    exposure_weight: float = 0.4,
    criticality_weight: float = 0.4,
    data_weight: float = 0.2,
    context_min_multiplier: float = 0.5,
    context_max_multiplier: float = 1.6,
    kev_priority_floor: int = 70,
) -> ScoreResult:
    notes: list[str] = []

    technical, tech_note = technical_factor(inp.cvss, inp.severity)
    if tech_note:
        notes.append(tech_note)

    threat, threat_note = threat_factor(inp.epss, inp.epss_percentile, inp.kev)
    if threat_note:
        notes.append(threat_note)

    # A finding with neither a technical score nor any threat signal has
    # nothing to rank on; say so rather than emitting a confident-looking 8.
    if tech_note == "no-technical-score" and threat_note == "epss-missing":
        notes.append("no-scoreable-data")

    weight_sum = cvss_weight + epss_weight
    if weight_sum <= 0:
        base = 0.0
    else:
        base = 100.0 * (cvss_weight * technical + epss_weight * threat) / weight_sum

    ctx = context_score(
        inp.asset,
        exposure_weight=exposure_weight,
        criticality_weight=criticality_weight,
        data_weight=data_weight,
    )
    multiplier = context_min_multiplier + (context_max_multiplier - context_min_multiplier) * ctx

    priority = int(round(max(0.0, min(100.0, base * multiplier))))

    # KEV means someone is already exploiting this. Context can raise it but
    # must not bury it below the floor.
    if inp.kev and priority < kev_priority_floor:
        priority = kev_priority_floor
        notes.append("kev-floor-applied")

    band = priority_band(priority)
    return ScoreResult(
        priority=priority,
        band=band,
        technical=technical,
        threat=threat,
        context=ctx,
        multiplier=multiplier,
        base=base,
        notes=tuple(notes),
        explanation=_explain(inp, technical, threat, base, ctx, multiplier, priority, band),
    )


def _explain(
    inp: ScoreInput,
    technical: float,
    threat: float,
    base: float,
    ctx: float,
    multiplier: float,
    priority: int,
    band: str,
) -> str:
    asset = inp.asset
    if inp.kev:
        threat_src = "CISA KEV (actively exploited)"
    elif inp.epss is not None or inp.epss_percentile is not None:
        prob = inp.epss if inp.epss is not None else 0.0
        pct = (inp.epss_percentile if inp.epss_percentile is not None else 0.0) * 100
        threat_src = f"EPSS {prob:.4f} / p{pct:.0f}"
    else:
        threat_src = "no EPSS data"
    direction = "amplified" if multiplier > 1 else "damped" if multiplier < 1 else "unchanged"
    return (
        f"technical {technical * 10:.1f}/10 + threat {threat:.2f} ({threat_src}) "
        f"= base {base:.0f}; asset {asset.summary()} gives context {ctx:.2f} "
        f"(x{multiplier:.2f}, {direction}) -> priority {priority} [{band}]"
    )


def priority_band(priority: int) -> str:
    for threshold, name in BANDS:
        if priority >= threshold:
            return name
    return "info"


# --- backwards compatibility -------------------------------------------
# The pre-context model. Kept so anything still calling the old two-argument
# helper keeps working; new code should call compute_score().
def compute_priority(
    cvss: float | None,
    epss_percentile: float | None,
    *,
    cvss_weight: float = 0.5,
    epss_weight: float = 0.5,
) -> tuple[int, str]:
    result = compute_score(
        ScoreInput(cvss=cvss, epss_percentile=epss_percentile),
        cvss_weight=cvss_weight,
        epss_weight=epss_weight,
        context_min_multiplier=1.0,
        context_max_multiplier=1.0,
    )
    return result.priority, ",".join(result.notes) if result.notes else "ok"
