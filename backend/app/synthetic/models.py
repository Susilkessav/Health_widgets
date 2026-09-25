"""Fixture metadata, not production health events or calculated health state."""
from __future__ import annotations

from datetime import date, timedelta
from typing import Literal
from uuid import UUID

from pydantic import AwareDatetime, Field, JsonValue, model_validator

from app.contracts._types import Frozen, IanaTimezone, NonEmptyStr, Sha256Hex, utc
from app.contracts.canonical_events import CanonicalEvent
from app.synthetic import GENERATOR_VERSION


class GenerationConfig(Frozen):
    seed: int = Field(default=20260923, strict=True)
    start_date: date = date(2026, 8, 14)
    days: int = Field(default=40, ge=40, strict=True)
    timezone: IanaTimezone = "America/Chicago"

    @model_validator(mode="after")
    def _date_range(self) -> GenerationConfig:
        try:
            self.start_date - timedelta(days=1)
            self.start_date + timedelta(days=self.days)
        except OverflowError as error:
            raise ValueError("history and closing midnight must fit in the date range") from error
        return self


class Checkpoint(Frozen):
    id: NonEmptyStr
    effective_at: AwareDatetime
    known_at: AwareDatetime
    note: NonEmptyStr

    @model_validator(mode="after")
    def _order(self) -> Checkpoint:
        if utc(self.known_at) < utc(self.effective_at):
            raise ValueError("known_at cannot precede effective_at in these fixtures")
        return self


CoverageStatus = Literal["complete", "unavailable"]


class Coverage(Frozen):
    """A fixture declaration of query coverage, never inferred from an empty list."""
    sleep: CoverageStatus = "complete"
    hrv: CoverageStatus = "complete"
    rhr: CoverageStatus = "complete"
    movement: CoverageStatus = "complete"
    workout: CoverageStatus = "complete"


class CoverageWindow(Frozen):
    start_day: date
    end_day: date
    domains: Coverage = Field(default_factory=Coverage)

    @model_validator(mode="after")
    def _order(self) -> CoverageWindow:
        if self.end_day < self.start_day:
            raise ValueError("coverage window is reversed")
        return self


class Context(Frozen):
    id: str = Field(pattern=r"^[a-z][a-z0-9_]*$")
    synthetic: Literal[True] = True
    version: str = GENERATOR_VERSION
    person: Literal["fictional-person-001"] = "fictional-person-001"
    timezone: IanaTimezone
    start_day: date
    end_day: date
    golden_case: int | None = Field(default=None, ge=1, le=14)
    checkpoints: tuple[Checkpoint, ...] = Field(min_length=1)
    coverage: tuple[CoverageWindow, ...] = Field(min_length=1)
    labels: tuple[str, ...] = ()
    note: NonEmptyStr

    @model_validator(mode="after")
    def _consistent(self) -> Context:
        if self.start_day > self.end_day:
            raise ValueError("context date range is reversed")
        ids = [point.id for point in self.checkpoints]
        if len(ids) != len(set(ids)):
            raise ValueError("checkpoint IDs must be unique")
        return self


class Delivery(Frozen):
    id: NonEmptyStr
    delivered_at: AwareDatetime
    event_ids: tuple[UUID, ...] = Field(min_length=1)
    note: NonEmptyStr = "Initial delivery"


class Assertion(Frozen):
    layer: Literal["raw", "resolution", "features", "state", "widget"]
    checkpoint: NonEmptyStr = "evaluation"
    field: NonEmptyStr
    expected: JsonValue
    event_ids: tuple[UUID, ...] = ()
    note: NonEmptyStr


class Expectations(Frozen):
    assumptions: dict[str, JsonValue]
    assertions: tuple[Assertion, ...] = Field(min_length=1)


class Dataset(Frozen):
    context: Context
    events: tuple[CanonicalEvent, ...]
    deliveries: tuple[Delivery, ...]
    expectations: Expectations | None = None

    @model_validator(mode="after")
    def _references(self) -> Dataset:
        ids = {event.event_id for event in self.events}
        if len(ids) != len(self.events):
            raise ValueError("duplicate event_id in canonical events")
        delivered = {event_id for batch in self.deliveries for event_id in batch.event_ids}
        if delivered != ids:
            raise ValueError("deliveries must reference exactly the existing event set")
        batch_ids = [batch.id for batch in self.deliveries]
        if len(batch_ids) != len(set(batch_ids)):
            raise ValueError("duplicate delivery ID")
        if self.expectations:
            checkpoints = {point.id for point in self.context.checkpoints}
            for assertion in self.expectations.assertions:
                if assertion.checkpoint not in checkpoints or not set(assertion.event_ids) <= ids:
                    raise ValueError("expectation references unknown checkpoint or event")
        return self


class FileRecord(Frozen):
    sha256: Sha256Hex
    bytes: int = Field(ge=0)


class DatasetRecord(Frozen):
    path: NonEmptyStr
    golden_case: int | None
    unique_events: int = Field(ge=0)
    delivery_batches: int = Field(ge=0)
    event_deliveries: int = Field(ge=0)


class Manifest(Frozen):
    synthetic: Literal[True] = True
    generator_version: str = GENERATOR_VERSION
    event_schema_version: Literal["1.0.0"] = "1.0.0"
    parameters: GenerationConfig
    runtime: dict[str, JsonValue]
    datasets: dict[str, DatasetRecord]
    files: dict[str, FileRecord]
