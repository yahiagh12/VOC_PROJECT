from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any

from fastapi import FastAPI, HTTPException

from config import settings
from defectdojo_client import DefectDojoClient, extract_cve
from epss_client import fetch_epss_bulk
from scoring import compute_priority, priority_band

logging.basicConfig(
    level=settings.log_level,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("prioritization")

state: dict[str, Any] = {
    "last_run": None,
    "scored": 0,
    "skipped": 0,
    "errors": 0,
    "running": False,
}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def run_scoring_pass() -> dict:
    if state.get("running"):
        raise HTTPException(status_code=409, detail="a scoring pass is already running")
    state["running"] = True
    scored = skipped = errors = 0
    try:
        with DefectDojoClient(
            settings.defectdojo_url,
            settings.defectdojo_api_key,
            verify=settings.defectdojo_verify_tls,
        ) as dd:
            findings = list(dd.list_findings(active=True))
            log.info("Loaded %d active findings from DefectDojo", len(findings))

            cve_to_fids: dict[str, list[int]] = {}
            non_cve_fids: list[int] = []
            for f in findings:
                cve = extract_cve(f)
                cvss = f.get("cvssv3_score") or f.get("cvssv2_score")
                if cve:
                    cve_to_fids.setdefault(cve, []).append(f["id"])
                elif cvss is not None:
                    non_cve_fids.append(f["id"])
                else:
                    skipped += 1

            if not cve_to_fids and not non_cve_fids:
                log.info("No findings to score (no CVE and no CVSS)")
            else:
                epss = {}
                if cve_to_fids:
                    epss = fetch_epss_bulk(cve_to_fids.keys(), settings.epss_api_url)

                to_score: list[tuple[int, str | None, float | None]] = []
                for cve, fids in cve_to_fids.items():
                    entry = epss.get(cve)
                    percentile = entry["percentile"] if entry else None
                    for fid in fids:
                        to_score.append((fid, cve, percentile))
                for fid in non_cve_fids:
                    to_score.append((fid, None, None))

                for fid, cve, percentile in to_score:
                    src = next((x for x in findings if x["id"] == fid), {})
                    cvss = src.get("cvssv3_score") or src.get("cvssv2_score")
                    priority, note = compute_priority(
                        cvss,
                        percentile,
                        cvss_weight=settings.cvss_weight,
                        epss_weight=settings.epss_weight,
                    )
                    try:
                        dd.set_priority(
                            fid,
                            priority,
                            existing_tags=src.get("tags") or [],
                        )
                        scored += 1
                        log.debug(
                            "finding=%s cve=%s priority=%d band=%s (%s)",
                            fid, cve or "none", priority, priority_band(priority), note,
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
    }
    state.update(result)
    log.info("Scoring pass complete: %s", result)
    return result


@asynccontextmanager
async def lifespan(_app: FastAPI):
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


app = FastAPI(title="VOC Prioritization Service", version="0.1.0", lifespan=lifespan)


@app.get("/")
def root():
    return {"service": "voc-prioritization", "version": "0.1.0", "docs": "/docs"}


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/state")
def get_state():
    return state


@app.post("/score")
def score():
    return run_scoring_pass()
