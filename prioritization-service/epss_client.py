from __future__ import annotations

import logging
from collections.abc import Iterable

import httpx

log = logging.getLogger(__name__)

# FIRST.org EPSS API caps the number of CVEs per request; chunk well under that.
CHUNK_SIZE = 200


def fetch_epss_bulk(
    cves: Iterable[str],
    api_url: str,
    *,
    client: httpx.Client | None = None,
    timeout: float = 30.0,
) -> dict[str, dict[str, float]]:
    """Fetch EPSS scores for a batch of CVEs.

    Returns a mapping { cve: {"epss": float, "percentile": float} }.
    The EPSS API supports ?cve=CVE-1,CVE-2,... in a single request.
    """
    unique = [c for c in dict.fromkeys(cves) if c]
    if not unique:
        return {}

    results: dict[str, dict[str, float]] = {}
    own_client = client is None
    client = client or httpx.Client(timeout=timeout)
    try:
        for i in range(0, len(unique), CHUNK_SIZE):
            chunk = unique[i : i + CHUNK_SIZE]
            r = client.get(api_url, params={"cve": ",".join(chunk)})
            r.raise_for_status()
            data = r.json()
            for entry in data.get("data", []):
                cve = entry.get("cve")
                try:
                    results[cve] = {
                        "epss": float(entry.get("epss", 0.0)),
                        "percentile": float(entry.get("percentile", 0.0)),
                    }
                except (TypeError, ValueError):
                    continue
    finally:
        if own_client:
            client.close()

    missing = [c for c in unique if c not in results]
    if missing:
        log.warning("EPSS: no data for %d/%d CVEs", len(missing), len(unique))
    return results
