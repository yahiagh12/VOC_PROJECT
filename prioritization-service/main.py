from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any

from fastapi import FastAPI, HTTPException

from assets import AssetInventory
from config import settings
from defectdojo_client import DefectDojoClient, extract_cve
from epss_client import fetch_epss_bulk
from kev_client import KevCatalog
from scoring import ScoreInput, compute_score, priority_band

logging.basicConfig(
    level=settings.log_level,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("prioritization")

inventory = AssetInventory.load(settings.asset_inventory_path)
kev = KevCatalog(settings.kev_feed_url, ttl_seconds=settings.kev_refresh_seconds)

state: dict[str, Any] = {
    "last_run": None,
    "scored": 0,
    "skipped": 0,
    "errors": 0,
    "running": False,
    "assets_loaded": len(inventory.assets),
    "kev_loaded": 0,
    "band_counts": {},
}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _score_kwargs() -> dict:
    """Model tuning pulled from settings — one place, so /explain and the
    scoring pass can never drift apart."""
    return {
        "cvss_weight": settings.cvss_weight,
        "epss_weight": settings.epss_weight,
        "exposure_weight": settings.exposure_weight,
        "criticality_weight": settings.criticality_weight,
        "data_weight": settings.data_weight,
        "context_min_multiplier": settings.context_min_multiplier,
        "context_max_multiplier": settings.context_max_multiplier,
        "kev_priority_floor": settings.kev_priority_floor,
    }


def _score_finding(finding: dict, percentile: float | None, probability: float | None):
    """Build the model input for one finding and score it."""
    asset, how = inventory.resolve(finding)
    cve = extract_cve(finding)
    result = compute_score(
        ScoreInput(
            cvss=finding.get("cvssv3_score") or finding.get("cvssv2_score"),
            severity=finding.get("severity"),
            epss=probability,
            epss_percentile=percentile,
            kev=kev.contains(cve),
            cve=cve,
            title=finding.get("title"),
            asset=asset,
        ),
        **_score_kwargs(),
    )
    return asset, how, result


def _deduplicate(dd: DefectDojoClient, findings: list[dict]) -> tuple[list[dict], int, int]:
    """Collapse same-title findings, keeping the lowest id as primary."""
    by_title: dict[str, list[dict]] = {}
    for f in findings:
        by_title.setdefault((f.get("title") or "").strip().lower(), []).append(f)

    primary: list[dict] = []
    marked = errors = 0
    for title_key, group in by_title.items():
        if not title_key:
            primary.extend(group)
            continue
        group.sort(key=lambda x: x["id"])
        primary.append(group[0])
        for dup in group[1:]:
            try:
                dd.mark_duplicate(dup["id"])
                marked += 1
                log.info("Marked finding %s as duplicate of %s", dup["id"], group[0]["id"])
            except Exception as exc:
                errors += 1
                log.warning("Failed to mark finding %s as duplicate: %s", dup["id"], exc)
    return primary, marked, errors


def run_scoring_pass() -> dict:
    if state.get("running"):
        raise HTTPException(status_code=409, detail="a scoring pass is already running")
    state["running"] = True
    scored = skipped = errors = 0
    band_counts: dict[str, int] = {}

    try:
        if settings.kev_enabled:
            kev.refresh()
            state["kev_loaded"] = kev.size

        with DefectDojoClient(
            settings.defectdojo_url,
            settings.defectdojo_api_key,
            verify=settings.defectdojo_verify_tls,
        ) as dd:
            findings = list(dd.list_findings(active=True))
            log.info("Loaded %d active findings from DefectDojo", len(findings))

            findings, marked, dedup_errors = _deduplicate(dd, findings)
            skipped += marked
            errors += dedup_errors
            log.info("Proceeding to score %d primary active findings", len(findings))

            # One EPSS lookup for every CVE in the batch. Findings without a
            # CVE are still scored — their technical term comes from CVSS or
            # the scanner's severity, and their threat term is the unknown
            # prior. Dropping them (the old behaviour) meant every web
            # finding from nuclei/sqlmap/ffuf/xsstrike went unprioritised.
            cve_by_fid: dict[int, str | None] = {f["id"]: extract_cve(f) for f in findings}
            cves = {c for c in cve_by_fid.values() if c}
            epss = fetch_epss_bulk(cves, settings.epss_api_url) if cves else {}
            if cves:
                log.info("EPSS: resolved %d/%d CVEs", len(epss), len(cves))

            for finding in findings:
                fid = finding["id"]
                entry = epss.get(cve_by_fid.get(fid) or "")
                asset, how, result = _score_finding(
                    finding,
                    entry["percentile"] if entry else None,
                    entry["epss"] if entry else None,
                )

                if "no-scoreable-data" in result.notes:
                    skipped += 1
                    log.debug("finding=%s has no scoreable data — skipped", fid)
                    continue

                try:
                    changed = dd.set_priority(
                        fid,
                        result.priority,
                        existing_tags=finding.get("tags") or [],
                        existing_risk_score=finding.get("risk_score"),
                        existing_severity=finding.get("severity"),
                        existing_description=finding.get("description"),
                        priority_band_func=priority_band,
                        context_tags=asset.context_tags(),
                        explanation=result.explanation if settings.write_explanation else None,
                    )
                    if changed:
                        scored += 1
                    else:
                        skipped += 1
                    band_counts[result.band] = band_counts.get(result.band, 0) + 1
                    log.debug(
                        "finding=%s asset=%s (%s) %s", fid, asset.name, how, result.explanation
                    )
                except Exception as exc:
                    errors += 1
                    log.warning("failed to update finding %s: %s", fid, exc)
    finally:
        state["running"] = False

    result = {
        "last_run": _now(),
        "scored": scored,
        "skipped": skipped,
        "errors": errors,
        "running": False,
        "band_counts": band_counts,
        "assets_loaded": len(inventory.assets),
        "kev_loaded": kev.size,
    }
    state.update(result)
    log.info("Scoring pass complete: %s", result)
    return result


@asynccontextmanager
async def lifespan(_app: FastAPI):
    if settings.kev_enabled:
        # Warm the catalogue off the request path so the first scoring pass
        # is not waiting on a 1 MB download.
        asyncio.create_task(asyncio.to_thread(kev.refresh))

    if settings.run_scheduler:
        async def loop():
            while True:
                try:
                    await asyncio.to_thread(run_scoring_pass)
                except HTTPException:
                    pass
                except Exception as exc:
                    log.error("scheduled scoring pass failed: %s", exc)
                await asyncio.sleep(settings.scoring_interval_seconds)

        task = asyncio.create_task(loop())
        try:
            yield
        finally:
            task.cancel()
    else:
        yield


app = FastAPI(title="VOC Prioritization Service", version="0.2.0", lifespan=lifespan)


@app.get("/")
def root():
    return {"service": "voc-prioritization", "version": "0.2.0", "docs": "/docs"}


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/state")
def get_state():
    return state


@app.get("/model")
def get_model():
    """The tuning actually in effect — useful when a score looks surprising."""
    return {
        **_score_kwargs(),
        "kev_enabled": settings.kev_enabled,
        "kev_catalogue_size": kev.size,
        "kev_last_error": kev.last_error,
        "write_explanation": settings.write_explanation,
        "bands": {"critical": 80, "high": 60, "medium": 40, "low": 20, "info": 0},
    }


@app.get("/assets")
def get_assets():
    """The asset inventory driving the context multiplier."""
    return {
        "count": len(inventory.assets),
        "source": settings.asset_inventory_path,
        "default": {
            "business_criticality": inventory.default.business_criticality,
            "exposure": inventory.default.exposure,
            "data_classification": inventory.default.data_classification,
        },
        "assets": inventory.as_dicts(),
    }


@app.get("/explain/{finding_id}")
def explain(finding_id: int):
    """Score a single finding and show the full breakdown without writing
    anything back — the fastest way to answer 'why is this a 84?'."""
    with DefectDojoClient(
        settings.defectdojo_url,
        settings.defectdojo_api_key,
        verify=settings.defectdojo_verify_tls,
    ) as dd:
        try:
            finding = dd.get_finding(finding_id)
        except Exception as exc:
            raise HTTPException(status_code=404, detail=f"finding {finding_id}: {exc}") from exc

    cve = extract_cve(finding)
    entry = fetch_epss_bulk([cve], settings.epss_api_url).get(cve) if cve else None
    if settings.kev_enabled:
        kev.refresh()
    asset, how, result = _score_finding(
        finding,
        entry["percentile"] if entry else None,
        entry["epss"] if entry else None,
    )
    return {
        "finding_id": finding_id,
        "title": finding.get("title"),
        "reported_severity": finding.get("severity"),
        "cve": cve,
        "kev": kev.contains(cve),
        "asset": {
            "name": asset.name,
            "matched_by": how,
            "business_criticality": asset.business_criticality,
            "exposure": asset.exposure,
            "internet_facing": asset.internet_facing,
            "data_classification": asset.data_classification,
            "owner": asset.owner,
        },
        "score": result.as_dict(),
    }


@app.post("/score")
def score():
    return run_scoring_pass()


@app.post("/reload")
def reload_inventory():
    """Re-read the asset inventory ConfigMap without restarting the pod."""
    global inventory
    inventory = AssetInventory.load(settings.asset_inventory_path)
    state["assets_loaded"] = len(inventory.assets)
    return {"assets_loaded": len(inventory.assets), "assets": [a.name for a in inventory.assets]}
