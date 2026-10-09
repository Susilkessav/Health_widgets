"""Review daily widget observations from a local iPhone database export.

    python -m app.experience_audit STORE.sqlite --out-dir /tmp/homeostat-review --days 30

Uses the existing reference replay engine, at local noon on each supported day.
This is a retrospective reconstruction using currently retained/corrected data,
not a record of what the user actually saw. No network or database writes.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import date, datetime, time, timedelta
import json
from pathlib import Path
import sqlite3
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.config import load_settings, settings_sha256
from app.contracts._types import utc
from app.device_check import calculate, load
from app.engine import ENGINE_VERSION
from app.presentation import PRESENTATION_VERSION

CATEGORIES = ("headline", "quiet", "calibrating", "no_data")
TRAITS = {"sleep": "headline", "recovery": "headline", "movement": "headline", "workout": "headline",
          "typical": "quiet", "calibration": "calibrating", "no_data": "no_data"}
LIMITATION = ("Retrospective reconstruction from retained, corrected data at local noon; not historical "
              "delivery or actual widget exposure. A headline is an eligible observation, not proof of "
              "usefulness or a newly changed state. Missing data is separate from a quiet day. "
              "Calibration here reflects retained history, not days since installation.")


def checkpoints(lower: datetime, through: dict[str, datetime], zone: str, days: int,
                end: date | None = None) -> list[tuple[str, datetime]]:
    if not 1 <= days <= 60:
        raise ValueError("days must be between 1 and 60")
    if not through:
        return []
    tz = ZoneInfo(zone)
    # Be conservative across imported domains, as device_check does. Unrequested
    # domains aren't fabricated; their absence remains visible in engine outputs.
    cutoff = min(through.values())
    last = cutoff.astimezone(tz).date()
    if utc(datetime.combine(last, time(12), tz)) > cutoff:
        last -= timedelta(days=1)
    if end is not None:
        last = min(last, end)
    result = []
    for offset in range(days - 1, -1, -1):
        day = last - timedelta(days=offset)
        start = utc(datetime.combine(day, time.min, tz))
        at = utc(datetime.combine(day, time(12), tz))
        if start >= lower and at <= cutoff:
            result.append((f"noon:{day}", at))
    return result


def summarize(results: dict) -> dict:
    rows = []
    for name, result in sorted(results.items(), key=lambda item: item[1]["effective_at"]):
        widget = result["widget_state"]
        trait = widget["primary_trait"]["id"]
        if trait not in TRAITS:
            raise ValueError(f"Unknown primary trait: {trait}")
        rows.append({"checkpoint": name, "day": result["day"], "effective_at": result["effective_at"],
                     "category": TRAITS[trait], "primary_trait": trait,
                     "headline": widget["presentation"]["headline"],
                     "detail": widget["presentation"].get("detail"),
                     "secondary": widget["presentation"].get("secondary"),
                     "calibration": result["health_state"]["calibration"]})
    counts = Counter(row["category"] for row in rows)
    return {"counts": {category: counts[category] for category in CATEGORIES},
            "evaluated_days": len(rows),
            "first_day": rows[0]["day"] if rows else None,
            "last_day": rows[-1]["day"] if rows else None,
            "headline_frequencies": dict(Counter(row["headline"] for row in rows).most_common()),
            "days": rows}


def audit(path: str, zone: str, days: int, end: date | None = None) -> tuple[dict, dict]:
    settings = load_settings()
    lower, through, observations, coverage, _ = load(path, zone)
    wanted = checkpoints(lower, through, zone, days, end)
    results = {name: calculate(observations, coverage, zone, at, settings) for name, at in wanted}
    report = {"version": "experience-audit@0.1.0", "timezone": zone, "local_sample_time": "12:00",
              "requested_days": days, "requested_end": end.isoformat() if end else None,
              "import_lower_bound": lower.isoformat(),
              "coverage_through": {domain: at.isoformat() for domain, at in sorted(through.items())},
              "coverage_status": {window.domain: window.status for window in coverage},
              "event_count": len(observations), "engine_version": ENGINE_VERSION,
              "presentation_version": PRESENTATION_VERSION, "settings_sha256": settings_sha256(settings),
              "limitation": LIMITATION, **summarize(results)}
    return report, results


def markdown(report: dict) -> str:
    def cell(value):
        return str(value or "—").replace("|", "\\|").replace("\n", " ")
    lines = ["# Daily widget experience review", "", report["limitation"], "",
             f"Requested: {report['requested_days']} days. Evaluated: {report['evaluated_days']} days.",
             f"Window: {report['first_day'] or 'none'} to {report['last_day'] or 'none'}; "
             f"12:00 in {report['timezone']}.", "",
             "Only days starting within retained coverage and reaching noon across imported domains are included.",
             "", "| Category | Days |", "|---|---:|"]
    lines += [f"| {category} | {count} |" for category, count in report["counts"].items()]
    if not report["evaluated_days"]:
        lines += ["", "No supported daily checkpoints. No usefulness conclusion can be drawn."]
    lines += ["", "## Daily observations", "", "| Day | Category | Headline | Detail | Secondary |",
              "|---|---|---|---|---|"]
    lines += ["| " + " | ".join(cell(row[key]) for key in ("day", "category", "headline", "detail", "secondary"))
              + " |" for row in report["days"]]
    lines += ["", "## Review notes", "",
              "- Which observations were helpful, repetitive or misleading?",
              "- How should quiet and calibrating days look?",
              "- Which missing inputs limit the result? See report.json for per-domain coverage and calibration.",
              "- These are reconstructed observations. Validate morning/evening behavior and actual usefulness on device.", ""]
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("store", type=Path)
    parser.add_argument("--out-dir", type=Path, required=True, help="New directory for local reports; must not already exist.")
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--zone", default="America/Chicago")
    parser.add_argument("--end", type=date.fromisoformat, help="Optional latest local day (YYYY-MM-DD).")
    args = parser.parse_args()
    if not args.store.is_file():
        parser.error("store must be an existing iPhone database export")
    if args.out_dir.exists():
        parser.error("out-dir already exists; choose a new directory to preserve previous evidence")
    try:
        ZoneInfo(args.zone)
        report, results = audit(str(args.store.resolve()), args.zone, args.days, args.end)
    except (ValueError, KeyError, sqlite3.Error, ZoneInfoNotFoundError) as error:
        parser.error(str(error))
    args.out_dir.mkdir(parents=True, exist_ok=False)
    for filename, value in (("report.json", report), ("checkpoints.json", results)):
        (args.out_dir / filename).write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    (args.out_dir / "review.md").write_text(markdown(report))
    # Keep health observations in the requested local files, not terminal logs.
    print(f"Wrote local review: {report['evaluated_days']} / {args.days} requested days evaluated.")
    if not results:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
