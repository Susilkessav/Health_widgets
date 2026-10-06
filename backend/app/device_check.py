"""Check an iPhone's on-device results against the Python reference engine.

    uv run python -m app.device_check STORE.sqlite --out python.json [--swift swift.json]

STORE is a copy of the app's local database (Application Support/
homeostat-*.sqlite). The inputs are rebuilt exactly as LocalCalculation.swift
builds them: every logged event, minus records a completed re-read no longer
returned, with each domain covered from the import lower bound to how far its
last complete import reached. It recalculates the phone's stored result and
every past day at its closing boundary (replay), and with --swift compares
each checkpoint to the Swift engine's output for the same database.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timedelta

from app.config import load_settings
from app.contracts._types import json_value, local_day_start, utc
from app.contracts.canonical_events import HEALTHKIT_TYPES
from app.engine import compute_health_state
from app.features.calculate import calculate_features
from app.features.models import CalculationContext, CoverageWindow, Observation
from app.features.selection import local_date
from app.presentation import map_widget_state
from app.store import EVENTS

TYPES = {"sleep": "sleep_stage", "hrv": "hrv_sdnn_ms", "rhr": "resting_hr_bpm", "workout": "workout"}


def instant(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def load(path: str, zone: str):
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    state = dict(db.execute("SELECT key, value FROM sync_state"))
    lower = instant(state["import_lower_bound"])
    through = {domain: instant(state[f"covered_through_{key}"])
               for key, domain in [("sleep", "sleep"), ("hrv", "hrv"), ("rhr", "rhr"), ("workout", "workout"),
                                   ("steps", "movement")] if f"covered_through_{key}" in state}
    visible = {}
    for key in TYPES:
        generation = state.get(f"covered_generation_{key}")
        if generation and f"covered_through_{key}" in state:
            visible[HEALTHKIT_TYPES[TYPES[key]]] = {row[0] for row in db.execute(
                "SELECT source_record_id FROM generation_members WHERE type = ? AND generation = ?", (key, generation))}
    observations = []
    for body, created in db.execute("SELECT body, created_at FROM event_outbox ORDER BY id"):
        event = EVENTS.validate_json(body)
        meta = getattr(event, "metadata", None)
        if meta is not None and meta.healthkit_type in visible and event.source_record_id not in visible[meta.healthkit_type]:
            continue  # withdrawn by a completed re-read
        observations.append(Observation(event=event, delivered_at=instant(created)))
    quarantined = set()
    for domain, end in through.items():
        hit = db.execute("""SELECT 1 FROM quarantine WHERE domain = ? AND resolved_at IS NULL AND (sample_start IS NULL
                            OR sample_end IS NULL OR (sample_start < ? AND sample_end >= ?))""",
                         (domain, int(end.timestamp() * 1e6), int(lower.timestamp() * 1e6))).fetchone()
        if hit:
            quarantined.add(domain)
    coverage = tuple(CoverageWindow(domain=domain, timezone=zone, status="unavailable" if domain in quarantined
                                    else "complete", start_at=lower, end_at=max(end, lower))
                     for domain, end in through.items())
    stored = json.loads(state["local_state"]) if "local_state" in state else None
    return lower, through, observations, coverage, stored


def calculate(observations, coverage, zone, effective, settings):
    known = max([effective, *(o.delivered_at for o in observations)])
    context = CalculationContext(day=local_date(effective, zone), timezone=zone, effective_at=effective,
                                 known_at=known, coverage=coverage)
    report = calculate_features(observations, context, settings)
    state = compute_health_state(report.features, settings)
    return {"day": context.day.isoformat(), "effective_at": json_value(effective),
            "features": json_value(report.features), "health_state": json_value(state),
            "widget_state": json_value(map_widget_state(state))}


def differences(expected, actual, path=""):
    if isinstance(expected, dict) and isinstance(actual, dict):
        return [d for key in sorted(set(expected) | set(actual))
                for d in differences(expected.get(key), actual.get(key), f"{path}.{key}")]
    if isinstance(expected, list) and isinstance(actual, list):
        if len(expected) != len(actual):
            return [f"{path}: {len(expected)} items vs {len(actual)}"]
        return [d for i, (a, b) in enumerate(zip(expected, actual)) for d in differences(a, b, f"{path}[{i}]")]
    numbers = (int, float)
    if isinstance(expected, numbers) and isinstance(actual, numbers) and not isinstance(expected, bool):
        return [] if abs(expected - actual) <= 1e-9 * max(1, abs(expected)) else [f"{path}: {expected} vs {actual}"]
    return [] if expected == actual else [f"{path}: {expected!r} vs {actual!r}"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("store")
    parser.add_argument("--zone", default="America/Chicago")
    parser.add_argument("--out", required=True, help="Write the Python results (and checkpoints) here.")
    parser.add_argument("--swift", help="Swift results for the same checkpoints, to compare.")
    args = parser.parse_args()
    settings = load_settings()
    lower, through, observations, coverage, stored = load(args.store, args.zone)
    cutoff = min(through.values()) if through else None
    checkpoints = []
    if stored:
        checkpoints.append(("phone", instant(stored["effective_at"])))
    day = local_date(lower, args.zone) + timedelta(days=1)
    while cutoff is not None and local_day_start(day + timedelta(days=1), args.zone) <= cutoff:
        checkpoints.append((f"close:{day}", local_day_start(day + timedelta(days=1), args.zone)))
        day += timedelta(days=1)
    results = {name: calculate(observations, coverage, args.zone, utc(at), settings) for name, at in checkpoints}
    with open(args.out, "w") as handle:
        json.dump(results, handle, indent=1, sort_keys=True, ensure_ascii=False)
    print(f"{len(observations)} events, coverage through {cutoff.isoformat() if cutoff else 'unavailable'}, "
          f"{len(results)} checkpoints")
    if not results:
        print("No replayable coverage or stored result; no comparison was performed.", file=sys.stderr)
        sys.exit(2)

    failures = 0
    if stored:
        for part in ("health_state", "widget_state"):
            found = differences(stored[part], results["phone"][part], f"phone.{part}")
            failures += len(found)
            print(f"stored phone {part} vs Python: {'identical' if not found else found[:10]}")
    if args.swift:
        swift = json.load(open(args.swift))
        for name in results:
            for part in ("features", "health_state", "widget_state"):
                found = differences(results[name][part], swift[name][part], f"{name}.{part}")
                failures += len(found)
                for line in found[:5]:
                    print("MISMATCH", line)
        print(f"Swift vs Python: {len(results)} checkpoints, {'all identical' if not failures else f'{failures} differences'}")
    for name, result in results.items():
        presentation = result["widget_state"]["presentation"]
        print(f"{name:18} {presentation['icon']} {presentation['headline']} · {presentation.get('detail') or ''}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
