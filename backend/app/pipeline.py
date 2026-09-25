"""Synthetic end-to-end run: events -> features -> HealthState -> WidgetState.

    python -m app.pipeline run --dataset DIR --checkpoint ID [--config PATH] [--output PATH]
    python -m app.pipeline timeline --dataset DIR [--config PATH]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from zoneinfo import ZoneInfo

from pydantic import ValidationError

from app.config import DEFAULT_PATH, Settings, load_settings
from app.contracts._types import Frozen, utc
from app.contracts.health_state import HealthState
from app.contracts.widget_state import WidgetState
from app.engine import compute_health_state
from app.features.models import CalculationReport
from app.features.synthetic import calculate_checkpoint, load_dataset
from app.presentation import map_widget_state
from app.synthetic.models import Dataset
from app.synthetic.writer import json_bytes


class PipelineResult(Frozen):
    features_report: CalculationReport
    health_state: HealthState
    widget_state: WidgetState


def run_checkpoint(dataset: Dataset, checkpoint_id: str, settings: Settings) -> PipelineResult:
    report = calculate_checkpoint(dataset, checkpoint_id, settings)
    state = compute_health_state(report.features, settings)
    return PipelineResult(features_report=report, health_state=state, widget_state=map_widget_state(state))


def timeline(dataset: Dataset, settings: Settings) -> list[str]:
    """One line per checkpoint, in checkpoint order, in the dataset's local time."""
    zone = ZoneInfo(dataset.context.timezone)
    lines = []
    for point in dataset.context.checkpoints:
        widget = run_checkpoint(dataset, point.id, settings).widget_state.presentation
        when = utc(point.effective_at).astimezone(zone).strftime("%Y-%m-%d %H:%M")
        text = " · ".join(part for part in (widget.headline, widget.detail, widget.secondary) if part)
        lines.append(f"{when}  {widget.icon} {text}")
    return lines


def main() -> None:
    parser = argparse.ArgumentParser(description="Run synthetic events through features, state and widget.")
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run")
    run.add_argument("--checkpoint", required=True)
    run.add_argument("--output", type=Path, help="Write here instead of stdout.")
    listing = commands.add_parser("timeline")
    for command in (run, listing):
        command.add_argument("--dataset", type=Path, required=True)
        command.add_argument("--config", type=Path, default=DEFAULT_PATH)
    args = parser.parse_args()
    try:
        dataset, settings = load_dataset(args.dataset), load_settings(args.config)
        if args.command == "timeline":
            data = ("\n".join(timeline(dataset, settings)) + "\n").encode("utf-8")
        else:
            data = json_bytes(run_checkpoint(dataset, args.checkpoint, settings))
    except (ValidationError, ValueError, OSError) as error:
        parser.error(str(error))
    if getattr(args, "output", None):
        args.output.write_bytes(data)
    else:
        sys.stdout.buffer.write(data)


if __name__ == "__main__":
    main()
