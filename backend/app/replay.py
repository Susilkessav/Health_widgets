"""Replay (Step 6-8 plan section 10).

    python -m app.replay runs    --user dev --from 2026-08-01 --to 2026-09-22
    python -m app.replay rebuild --user dev --from 2026-08-01 --to 2026-09-22 [--cutoff-revision N]

`runs` re-executes every recorded calculation from stored events with its own
context, input revision and configuration snapshot, and compares outputs.
`rebuild` recomputes daily summaries at their closing boundary; running it
twice adds nothing the second time.
"""
from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from uuid import UUID

from sqlalchemy.engine import Engine

from app import recalc, store
from app.config import Settings, load_settings
from app.contracts._types import json_value, local_day_start, utc
from app.contracts.features import FEATURES_VERSION
from app.db import lock_user, make_engine
from app.engine import ENGINE_VERSION
from app.presentation import PRESENTATION_VERSION
from app.runtime import load_runtime, system_clock


@dataclass
class RunCheck:
    run_id: int
    day: date
    status: str  # "identical", "mismatch" or "not_reproducible"
    differences: list[str] = field(default_factory=list)


def _differences(stored: dict, fresh) -> list[str]:
    fresh = json_value(fresh)
    return sorted(key for key in set(stored) | set(fresh)
                  if store.canonical_bytes(stored.get(key)) != store.canonical_bytes(fresh.get(key)))


def verify_runs(engine: Engine, user_id: UUID, first: date, last: date) -> list[RunCheck]:
    checks = []
    with engine.connect() as conn:
        rows = store.runs_between(conn, user_id, first, last)
    for row in rows:
        if row.report is None or row.state is None or row.widget_state is None:
            checks.append(RunCheck(row.run_id, row.day, "mismatch", ["missing_output"]))
            continue
        versions = (row.feature_version, row.engine_version, row.presentation_version)
        if versions != (FEATURES_VERSION, ENGINE_VERSION, PRESENTATION_VERSION):
            checks.append(RunCheck(row.run_id, row.day, "not_reproducible",
                                   [f"recorded {'/'.join(versions)}; this code is "
                                    f"{FEATURES_VERSION}/{ENGINE_VERSION}/{PRESENTATION_VERSION}"]))
            continue
        with engine.begin() as conn:
            lock_user(conn, user_id)
            settings = store.load_config_snapshot(conn, row.config_sha256)
            report, state, widget = recalc.compute(conn, user_id, settings, row.input_revision, row.day,
                                                   row.timezone, row.effective_at, row.known_at)
        differences = [f"report.{k}" for k in _differences(row.report, report)] + \
                      [f"state.{k}" for k in _differences(row.state, state)] + \
                      [f"widget_state.{k}" for k in _differences(row.widget_state, widget)]
        checks.append(RunCheck(row.run_id, row.day, "mismatch" if differences else "identical", differences))
    return checks


@dataclass
class RebuildResult:
    created: int = 0
    unchanged: int = 0
    skipped: list[str] = field(default_factory=list)


def rebuild(engine: Engine, user_id: UUID, settings: Settings, first: date, last: date,
            cutoff_revision: int | None, now: datetime) -> RebuildResult:
    result = RebuildResult()
    with engine.connect() as conn:
        latest, _, zone = store.current_revision(conn, user_id)
        revision = latest if cutoff_revision is None else cutoff_revision
        if not 1 <= revision <= latest:
            raise ValueError(f"cutoff revision must be between 1 and {latest}")
        known_at = recalc.revision_received_at(conn, user_id, revision)
    day = first
    while day <= last:
        boundary = local_day_start(day + timedelta(days=1), zone)
        if boundary > utc(known_at):  # would need knowledge from after the cutoff
            result.skipped.append(f"{day}: closing boundary is after the cutoff revision's receive time")
        else:
            with engine.begin() as conn:
                lock_user(conn, user_id)
                run_id, _, _ = recalc.save(conn, user_id, "rebuild", settings, revision, day, zone, boundary,
                                           known_at, now, None)
            if run_id is None:
                result.unchanged += 1
            else:
                result.created += 1
        day += timedelta(days=1)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description="Verify or rebuild stored Homeostat calculations.")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("runs", "rebuild"):
        command = commands.add_parser(name)
        command.add_argument("--user", required=True, help='"dev" or a user UUID')
        command.add_argument("--from", dest="first", type=date.fromisoformat, required=True)
        command.add_argument("--to", dest="last", type=date.fromisoformat, required=True)
        if name == "rebuild":
            command.add_argument("--cutoff-revision", type=int)
    args = parser.parse_args()
    runtime = load_runtime(require_api_key=False)
    user_id = runtime.dev_user_id if args.user == "dev" else UUID(args.user)
    engine = make_engine(runtime.database_url)
    if args.command == "runs":
        checks = verify_runs(engine, user_id, args.first, args.last)
        for check in checks:
            if check.status != "identical":
                print(f"run {check.run_id} ({check.day}): {check.status}: {', '.join(check.differences)}")
        counts = {s: sum(c.status == s for c in checks) for s in ("identical", "mismatch", "not_reproducible")}
        print(f"{len(checks)} runs: {counts['identical']} identical, {counts['mismatch']} mismatched, "
              f"{counts['not_reproducible']} not reproducible with this code")
        sys.exit(1 if counts["mismatch"] else 0)
    try:
        result = rebuild(engine, user_id, load_settings(runtime.config_path), args.first, args.last,
                         args.cutoff_revision, system_clock())
    except ValueError as error:
        parser.error(str(error))
    for note in result.skipped:
        print(f"skipped {note}")
    print(f"rebuild: {result.created} created, {result.unchanged} already identical, {len(result.skipped)} skipped")


if __name__ == "__main__":
    main()
