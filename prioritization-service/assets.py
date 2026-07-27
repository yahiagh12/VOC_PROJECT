"""Asset inventory: the business-context half of the prioritisation model.

A finding's technical severity says how broken the code is. This module says
how much it matters *where* the code runs — is the box reachable from the
internet, does it hold money, would the business stop if it fell over.

Resolution is best-effort and never raises: an unresolvable finding falls back
to the inventory `defaults` block rather than being dropped.
"""

from __future__ import annotations

import logging
import os
import re
from dataclasses import dataclass, field
from typing import Any, Iterable
from urllib.parse import urlsplit

import yaml

log = logging.getLogger(__name__)

# How reachable the asset is. Drives the biggest single context swing:
# the same bug on an internet-facing box is worth roughly twice what it is
# worth on an air-gapped one.
EXPOSURE_WEIGHTS: dict[str, float] = {
    "internet": 1.00,
    "dmz": 0.75,
    "internal": 0.45,
    "isolated": 0.15,
}
DEFAULT_EXPOSURE = "internal"

# What the asset holds. Regulated data raises the cost of a breach even when
# the box itself is not business-critical.
DATA_WEIGHTS: dict[str, float] = {
    "financial": 1.00,
    "phi": 1.00,
    "pii": 0.85,
    "confidential": 0.70,
    "internal": 0.40,
    "public": 0.15,
}
DEFAULT_DATA_CLASSIFICATION = "internal"

_SPLIT_RE = re.compile(r"[^a-z0-9]+")


def _norm(value: Any) -> str:
    return str(value or "").strip().lower()


@dataclass(frozen=True)
class Asset:
    """One entry from asset-inventory.yaml."""

    name: str = "unknown"
    description: str = ""
    business_criticality: int = 3
    exposure: str = DEFAULT_EXPOSURE
    data_classification: str = DEFAULT_DATA_CLASSIFICATION
    owner: str = "unassigned"
    aliases: tuple[str, ...] = field(default=())

    # --- derived 0..1 factors used by scoring.py -------------------------

    @property
    def exposure_factor(self) -> float:
        return EXPOSURE_WEIGHTS.get(_norm(self.exposure), EXPOSURE_WEIGHTS[DEFAULT_EXPOSURE])

    @property
    def criticality_factor(self) -> float:
        """1..5 business criticality mapped onto 0.2..1.0."""
        crit = max(1, min(5, int(self.business_criticality or 3)))
        return crit / 5.0

    @property
    def data_factor(self) -> float:
        return DATA_WEIGHTS.get(
            _norm(self.data_classification), DATA_WEIGHTS[DEFAULT_DATA_CLASSIFICATION]
        )

    @property
    def internet_facing(self) -> bool:
        return _norm(self.exposure) in ("internet", "dmz")

    def context_tags(self) -> list[str]:
        """Tags written back onto the DefectDojo finding so the context that
        produced the score is visible in the UI, not just in our logs.

        Hyphen-delimited rather than `key:value` — it matches the existing
        `priority-87` convention and avoids depending on DefectDojo accepting
        colons in tags.
        """
        return [
            f"voc-asset-{self.name}",
            f"voc-exposure-{_norm(self.exposure)}",
            f"voc-crit-{max(1, min(5, int(self.business_criticality or 3)))}",
            f"voc-data-{_norm(self.data_classification)}",
            "voc-internet-facing" if self.internet_facing else "voc-not-internet-facing",
        ]

    def summary(self) -> str:
        return (
            f"{self.name} (crit {self.business_criticality}/5, {_norm(self.exposure)}"
            f"-exposed, {_norm(self.data_classification)} data)"
        )


class AssetInventory:
    """Loads asset-inventory.yaml and resolves findings onto assets."""

    def __init__(self, assets: Iterable[Asset], default: Asset):
        self.assets = list(assets)
        self.default = default
        # alias -> Asset, longest alias first so "web-dvwa" wins over "dvwa"
        self._alias_index: list[tuple[str, Asset]] = []
        for asset in self.assets:
            seen = {_norm(asset.name), *(_norm(a) for a in asset.aliases)}
            for alias in seen:
                if alias:
                    self._alias_index.append((alias, asset))
        self._alias_index.sort(key=lambda pair: len(pair[0]), reverse=True)

    # --- loading ---------------------------------------------------------

    @classmethod
    def load(cls, path: str | None) -> "AssetInventory":
        """Load from `path`, falling back to a built-in copy next to this
        module, and finally to an empty inventory. Never raises — a broken
        inventory degrades scoring, it must not take the service down."""
        candidates = [
            p
            for p in (path, os.path.join(os.path.dirname(__file__), "asset-inventory.yaml"))
            if p
        ]
        for candidate in candidates:
            try:
                with open(candidate, "r", encoding="utf-8") as fh:
                    raw = yaml.safe_load(fh) or {}
            except FileNotFoundError:
                continue
            except Exception as exc:  # malformed YAML, unreadable file, ...
                log.warning("asset inventory %s could not be parsed: %s", candidate, exc)
                continue
            inv = cls._from_dict(raw)
            log.info("Loaded %d assets from %s", len(inv.assets), candidate)
            return inv

        log.warning(
            "No asset inventory found (tried %s) — using defaults for every finding", candidates
        )
        return cls([], Asset())

    @classmethod
    def _from_dict(cls, raw: dict) -> "AssetInventory":
        default = cls._asset_from_dict(raw.get("defaults") or {}, Asset())
        assets = [
            cls._asset_from_dict(entry, default)
            for entry in (raw.get("assets") or [])
            if isinstance(entry, dict) and entry.get("name")
        ]
        return cls(assets, default)

    @staticmethod
    def _asset_from_dict(entry: dict, fallback: Asset) -> Asset:
        try:
            criticality = int(entry.get("business_criticality", fallback.business_criticality))
        except (TypeError, ValueError):
            criticality = fallback.business_criticality
        return Asset(
            name=str(entry.get("name") or fallback.name),
            description=str(entry.get("description") or fallback.description),
            business_criticality=max(1, min(5, criticality)),
            exposure=_norm(entry.get("exposure")) or fallback.exposure,
            data_classification=_norm(entry.get("data_classification"))
            or fallback.data_classification,
            owner=str(entry.get("owner") or fallback.owner),
            aliases=tuple(str(a) for a in (entry.get("aliases") or []) if a),
        )

    # --- resolution ------------------------------------------------------

    def resolve(self, finding: dict) -> tuple[Asset, str]:
        """Map a DefectDojo finding onto an inventory asset.

        Returns (asset, how) where `how` records which signal matched, so the
        explanation can say *why* a finding was attributed to an asset.
        Signals are tried most-authoritative first.
        """
        if not self._alias_index:
            return self.default, "inventory-empty"

        tags = [_norm(t) for t in (finding.get("tags") or []) if t]

        # 1. Explicit override: someone tagged the finding voc-asset-<name>.
        for tag in tags:
            if tag.startswith("voc-asset-"):
                wanted = tag[len("voc-asset-"):]
                for asset in self.assets:
                    if _norm(asset.name) == wanted:
                        return asset, "explicit-tag"

        # 2. Scanner tags. scan-all.sh imports with tags like
        #    "web,nuclei,juice-shop" / "container,grype,web-dvwa", so the
        #    target short name is usually sitting right there.
        for tag in tags:
            asset = self._match_exact(tag)
            if asset:
                return asset, f"tag:{tag}"

        # 3. Endpoint hostnames — survives retagging and manual imports.
        for host in self._endpoint_hosts(finding):
            asset = self._match_substring(host)
            if asset:
                return asset, f"endpoint:{host}"

        # 4. Free text (title, then description) as a last resort.
        for key in ("title", "description"):
            asset = self._match_substring(_norm(finding.get(key)))
            if asset:
                return asset, f"{key}-match"

        return self.default, "unresolved"

    def _match_exact(self, token: str) -> Asset | None:
        if not token:
            return None
        for alias, asset in self._alias_index:
            if alias == token:
                return asset
        return None

    def _match_substring(self, text: str) -> Asset | None:
        if not text:
            return None
        # Word-ish boundaries so "dvwa" does not match inside a random hash.
        parts = set(_SPLIT_RE.split(text))
        for alias, asset in self._alias_index:
            if alias in text and (alias in parts or "/" in alias or "-" in alias):
                return asset
        return None

    @staticmethod
    def _endpoint_hosts(finding: dict) -> list[str]:
        hosts: list[str] = []
        for ep in finding.get("endpoints") or []:
            if isinstance(ep, dict):
                raw = ep.get("host") or ep.get("uri") or ""
            else:
                raw = str(ep)
            raw = _norm(raw)
            if not raw:
                continue
            if "://" in raw:
                raw = urlsplit(raw).hostname or raw
            hosts.append(raw)
        return hosts

    def as_dicts(self) -> list[dict]:
        """Inventory rendered for the /assets endpoint."""
        return [
            {
                "name": a.name,
                "description": a.description,
                "business_criticality": a.business_criticality,
                "exposure": a.exposure,
                "internet_facing": a.internet_facing,
                "data_classification": a.data_classification,
                "owner": a.owner,
                "aliases": list(a.aliases),
                "factors": {
                    "exposure": round(a.exposure_factor, 3),
                    "criticality": round(a.criticality_factor, 3),
                    "data": round(a.data_factor, 3),
                },
            }
            for a in self.assets
        ]
