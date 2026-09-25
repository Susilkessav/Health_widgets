"""Adapter from a saved synthetic dataset to calculator inputs. The calculator
never imports this; coverage comes from the fixture's declarations, never from
an empty event list."""
from __future__ import annotations

import json
from pathlib import Path

from app.config import Settings
from app.contracts._types import utc
from app.features.calculate import calculate_features
from app.features.models import DOMAINS, CalculationContext, CalculationReport, CoverageWindow, Observation
from app.features.selection import local_date
from app.synthetic.models import Dataset


def load_dataset(path: Path) -> Dataset:
    path = Path(path)
    expectations = path / "expectations.json"
    return Dataset.model_validate({
        "events": [json.loads(line) for line in (path / "events.jsonl").read_text().splitlines()],
        "deliveries": json.loads((path / "deliveries.json").read_text()),
        "context": json.loads((path / "context.json").read_text()),
        "expectations": json.loads(expectations.read_text()) if expectations.exists() else None,
    })


def observations(dataset: Dataset) -> tuple[Observation, ...]:
    events = {event.event_id: event for event in dataset.events}
    return tuple(Observation(event=events[event_id], delivered_at=batch.delivered_at)
                 for batch in dataset.deliveries for event_id in batch.event_ids)


def context_for(dataset: Dataset, checkpoint_id: str) -> CalculationContext:
    point = next((p for p in dataset.context.checkpoints if p.id == checkpoint_id), None)
    if point is None:
        raise ValueError(f"unknown checkpoint {checkpoint_id!r}")
    zone = dataset.context.timezone
    coverage = tuple(
        CoverageWindow(domain=domain, start_day=window.start_day, end_day=window.end_day, timezone=zone,
                       status=getattr(window.domains, domain))
        for window in dataset.context.coverage for domain in DOMAINS
    )
    return CalculationContext(day=local_date(point.effective_at, zone), timezone=zone,
                              effective_at=utc(point.effective_at), known_at=utc(point.known_at), coverage=coverage)


def calculate_checkpoint(dataset: Dataset, checkpoint_id: str, settings: Settings) -> CalculationReport:
    return calculate_features(observations(dataset), context_for(dataset, checkpoint_id), settings)
