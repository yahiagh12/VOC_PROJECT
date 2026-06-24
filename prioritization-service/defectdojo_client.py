from __future__ import annotations

import logging
import re
from collections.abc import Iterator
from typing import Any

import httpx

log = logging.getLogger(__name__)

CVE_RE = re.compile(r"CVE-\d{4}-\d{4,7}", re.IGNORECASE)


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
        limit: int = 200,
    ) -> Iterator[dict]:
        params: dict[str, Any] = {"limit": limit, "o": "false"}
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
        tag_prefix: str = "priority",
        set_risk_score: bool = True,
    ) -> dict:
        if existing_tags is None:
            existing_tags = (self.get_finding(finding_id).get("tags") or [])
        kept = [t for t in existing_tags if not (isinstance(t, str) and t.startswith(f"{tag_prefix}-"))]
        kept.append(f"{tag_prefix}-{priority}")
        payload: dict[str, Any] = {"tags": kept}
        if set_risk_score:
            payload["risk_score"] = float(priority)
        return self.update_finding(finding_id, payload)
