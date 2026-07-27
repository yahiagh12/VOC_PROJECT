"""CISA Known Exploited Vulnerabilities (KEV) catalogue.

EPSS predicts exploitation; KEV records that it already happened in the wild.
A CVE on this list is not a probability argument, so it gets a hard priority
floor rather than a weighted nudge.

The catalogue is ~1 MB of JSON and changes at most daily, so it is fetched
once per TTL and held in memory. Every failure path degrades to "no KEV data"
— an offline lab must still be able to score findings.
"""

from __future__ import annotations

import logging
import threading
import time

import httpx

log = logging.getLogger(__name__)


class KevCatalog:
    def __init__(self, url: str, ttl_seconds: int = 86_400, timeout: float = 30.0):
        self.url = url
        self.ttl_seconds = ttl_seconds
        self.timeout = timeout
        self._cves: frozenset[str] = frozenset()
        self._fetched_at: float = 0.0
        self._last_error: str | None = None
        self._lock = threading.Lock()

    @property
    def loaded(self) -> bool:
        return bool(self._cves)

    @property
    def size(self) -> int:
        return len(self._cves)

    @property
    def last_error(self) -> str | None:
        return self._last_error

    def refresh(self, *, force: bool = False) -> bool:
        """Fetch the catalogue if the cache is cold or stale. Returns True if
        usable data is in memory afterwards."""
        with self._lock:
            fresh = self._cves and (time.monotonic() - self._fetched_at) < self.ttl_seconds
            if fresh and not force:
                return True
            try:
                with httpx.Client(timeout=self.timeout) as client:
                    r = client.get(self.url)
                    r.raise_for_status()
                    data = r.json()
                cves = {
                    str(item.get("cveID", "")).upper()
                    for item in data.get("vulnerabilities", [])
                    if item.get("cveID")
                }
                if not cves:
                    raise ValueError("KEV feed contained no vulnerabilities")
                self._cves = frozenset(cves)
                self._fetched_at = time.monotonic()
                self._last_error = None
                log.info("KEV catalogue loaded: %d known-exploited CVEs", len(self._cves))
                return True
            except Exception as exc:
                self._last_error = str(exc)
                # Keep serving a stale catalogue if we have one — stale KEV
                # data is far better than pretending nothing is exploited.
                if self._cves:
                    log.warning("KEV refresh failed (%s) — using cached catalogue", exc)
                    return True
                log.warning("KEV unavailable (%s) — scoring without exploitation data", exc)
                return False

    def contains(self, cve: str | None) -> bool:
        return bool(cve) and cve.upper() in self._cves
