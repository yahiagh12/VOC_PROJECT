from __future__ import annotations

import logging
import re
from collections.abc import Iterator
from typing import Any

import httpx

log = logging.getLogger(__name__)

CVE_RE = re.compile(r"CVE-\d{4}-\d{4,7}", re.IGNORECASE)

# Tags this service owns and rewrites on every scoring pass. Anything the
# user or a scanner added stays untouched.
VOC_TAG_PREFIXES = (
    "voc-asset-",
    "voc-exposure-",
    "voc-crit-",
    "voc-data-",
    "voc-internet-facing",
    "voc-not-internet-facing",
)

# Delimits the block we inject into a finding's description, so re-scoring
# replaces the old explanation instead of stacking copies of it.
EXPLANATION_START = "<!-- voc-priority-start -->"
EXPLANATION_END = "<!-- voc-priority-end -->"


def _is_managed_tag(tag: str, priority_prefix: str) -> bool:
    lowered = tag.lower()
    return lowered.startswith(f"{priority_prefix}-") or lowered.startswith(VOC_TAG_PREFIXES)


def _with_explanation(description: str, explanation: str) -> str:
    block = f"{EXPLANATION_START}\n**VOC priority:** {explanation}\n{EXPLANATION_END}"
    start = description.find(EXPLANATION_START)
    if start != -1:
        end = description.find(EXPLANATION_END)
        if end != -1:
            end += len(EXPLANATION_END)
            return (description[:start] + block + description[end:]).strip()
        return (description[:start] + block).strip()
    return (description.rstrip() + "\n\n" + block).strip()


def extract_cve(finding: dict) -> str | None:
    """Pull a CVE id from a DefectDojo finding (cve field, vulnerability_ids, or title)."""
    cve = finding.get("cve")
    if cve and CVE_RE.fullmatch(str(cve)):
        return str(cve).upper()
    for v in finding.get("vulnerability_ids") or []:
        vid = v.get("vulnerability_id") if isinstance(v, dict) else v
        if vid and CVE_RE.fullmatch(str(vid)):
            return str(vid).upper()
    m = CVE_RE.search(finding.get("title") or "")
    return m.group(0).upper() if m else None


class DefectDojoClient:
    def __init__(
        self,
        base_url: str,
        api_key: str,
        *,
        verify: bool = True,
        timeout: float = 30.0,
    ):
        self.base_url = base_url.rstrip("/")
        self.client = httpx.Client(
            base_url=self.base_url,
            headers={
                "Authorization": f"Token {api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            timeout=timeout,
            verify=verify,
        )

    def close(self) -> None:
        self.client.close()

    def __enter__(self) -> "DefectDojoClient":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def list_findings(
        self,
        *,
        active: bool = True,
        verified: bool | None = None,
        limit: int = 500,
        o: str = "-id",
    ) -> Iterator[dict]:
        params: dict[str, Any] = {"limit": limit, "o": o}
        if active:
            params["active"] = "true"
        if verified is not None:
            params["verified"] = "true" if verified else "false"

        url: str | None = "/api/v2/findings/"
        first = True
        while url:
            r = self.client.get(url, params=params if first else None)
            r.raise_for_status()
            data = r.json()
            yield from data.get("results", [])
            url = data.get("next")
            first = False

    def get_finding(self, finding_id: int) -> dict:
        r = self.client.get(f"/api/v2/findings/{finding_id}/")
        r.raise_for_status()
        return r.json()

    def update_finding(self, finding_id: int, payload: dict) -> dict:
        r = self.client.patch(f"/api/v2/findings/{finding_id}/", json=payload)
        r.raise_for_status()
        return r.json()

    def set_priority(
        self,
        finding_id: int,
        priority: int,
        *,
        existing_tags: list[str] | None = None,
        existing_risk_score: float | None = None,
        existing_severity: str | None = None,
        tag_prefix: str = "priority",
        set_risk_score: bool = True,
        set_severity: bool = True,
        priority_band_func: callable | None = None,
        context_tags: list[str] | None = None,
        explanation: str | None = None,
        existing_description: str | None = None,
    ) -> dict:
        """PATCH a finding with its computed priority.

        `context_tags` carry the asset context that produced the score
        (voc-asset:, voc-exposure:, voc-crit:, ...) so the reasoning is
        visible in the DefectDojo UI. They are managed by us: every tag in
        the VOC_TAG_PREFIXES namespace is rewritten on each pass, so an asset
        moving from internal to internet-facing does not leave a stale tag
        behind. Returns {} when nothing needed changing (no wasted PATCH).
        """
        if existing_tags is None:
            finding = self.get_finding(finding_id)
            existing_tags = finding.get("tags") or []
            existing_risk_score = finding.get("risk_score")
            existing_severity = finding.get("severity")
            existing_description = finding.get("description")

        target_tag = f"{tag_prefix}-{priority}"
        managed = [target_tag, *(context_tags or [])]
        target_severity = (
            priority_band_func(priority).capitalize() if priority_band_func and set_severity else None
        )

        existing = [t for t in (existing_tags or []) if isinstance(t, str)]
        # DefectDojo lowercases tags on write; compare on the same footing so
        # an unchanged finding is not PATCHed on every single pass.
        existing_lower = {t.lower() for t in existing}
        needs_update = any(t.lower() not in existing_lower for t in managed)
        if not needs_update:
            # Any managed tag that should no longer be there (e.g. the old
            # priority-42 after a rescore) also forces an update.
            stale = {
                t.lower()
                for t in existing
                if _is_managed_tag(t, tag_prefix) and t.lower() not in {m.lower() for m in managed}
            }
            needs_update = bool(stale)
        if not needs_update and set_risk_score:
            needs_update = existing_risk_score is None or float(existing_risk_score) != float(priority)
        if not needs_update and target_severity:
            needs_update = existing_severity != target_severity

        new_description = None
        if explanation is not None:
            new_description = _with_explanation(existing_description or "", explanation)
            if new_description == (existing_description or ""):
                new_description = None
            else:
                needs_update = True

        if not needs_update:
            return {}

        kept = [t for t in existing if not _is_managed_tag(t, tag_prefix)]
        kept.extend(managed)
        payload: dict[str, Any] = {"tags": kept}
        if set_risk_score:
            payload["risk_score"] = float(priority)
        if target_severity:
            payload["severity"] = target_severity
        if new_description is not None:
            payload["description"] = new_description

        return self.update_finding(finding_id, payload)

    def mark_duplicate(self, finding_id: int) -> dict:
        return self.update_finding(finding_id, {"active": False, "verified": False, "duplicate": True})
