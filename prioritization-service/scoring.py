from __future__ import annotations


def compute_priority(
    cvss: float | None,
    epss_percentile: float | None,
    *,
    cvss_weight: float = 0.5,
    epss_weight: float = 0.5,
) -> tuple[int, str]:
    """Blend CVSS (0-10) and EPSS percentile (0-1) into a 0-100 priority score.

    Missing components are dropped and the remaining weight is renormalized,
    so a finding with only CVSS still gets a score. Returns (score, note).
    """
    cvss = None if cvss is None else float(cvss)
    epss = None if epss_percentile is None else float(epss_percentile)

    notes: list[str] = []
    weighted_sum = 0.0
    used_weight = 0.0

    if cvss is not None and 0.0 <= cvss <= 10.0:
        weighted_sum += cvss_weight * (cvss / 10.0 * 100.0)
        used_weight += cvss_weight
    else:
        notes.append("cvss-missing")

    if epss is not None and 0.0 <= epss <= 1.0:
        weighted_sum += epss_weight * (epss * 100.0)
        used_weight += epss_weight
    else:
        notes.append("epss-missing")

    if used_weight == 0.0:
        return 0, "no-scoreable-data"

    priority = round(weighted_sum / used_weight)
    return priority, ",".join(notes) if notes else "ok"


def priority_band(priority: int) -> str:
    if priority >= 80:
        return "critical"
    if priority >= 60:
        return "high"
    if priority >= 40:
        return "medium"
    return "low"
