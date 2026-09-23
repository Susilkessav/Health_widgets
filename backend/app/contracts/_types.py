"""Constrained types and helpers shared by the contract modules."""
from __future__ import annotations

from datetime import date, datetime, time, timedelta, timezone
from typing import Annotated, Any
from zoneinfo import ZoneInfo

from pydantic import AfterValidator, BaseModel, BeforeValidator, ConfigDict, Field, StringConstraints

# Absolute tolerance when a contract checks a derived number against the
# numbers it was derived from (e.g. delta_hours == hours - baseline_hours).
# Calculators must not round more coarsely than this; presentation rounds.
DERIVED_TOLERANCE = 0.01
# The single tolerance for every duration checked against timestamps.
DURATION_TOLERANCE = timedelta(minutes=1)
DURATION_TOLERANCE_HOURS = DURATION_TOLERANCE.total_seconds() / 3600
DURATION_TOLERANCE_MINUTES = DURATION_TOLERANCE.total_seconds() / 60


class Frozen(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


def utc(dt: datetime) -> datetime:
    """Compare aware datetimes as instants. Python compares two datetimes that
    share a tzinfo by wall clock and ignores `fold`, so inside a DST fall-back
    hour a later instant can compare as earlier."""
    return dt.astimezone(timezone.utc)


def local_day_minutes(day: date, zone: str) -> float:
    """Length of a local calendar day: 1380, 1440 or 1500 minutes around DST."""
    tz = ZoneInfo(zone)
    start = datetime.combine(day, time(0), tz)
    end = datetime.combine(day + timedelta(days=1), time(0), tz)
    return (utc(end) - utc(start)).total_seconds() / 60


def close(a: float, b: float, tolerance: float = DERIVED_TOLERANCE) -> bool:
    return abs(a - b) <= tolerance


def require(fields: dict[str, object], when: str) -> None:
    if missing := [name for name, value in fields.items() if value is None]:
        raise ValueError(f"{when} requires {', '.join(missing)}")


def forbid(fields: dict[str, object], when: str) -> None:
    if present := [name for name, value in fields.items() if value is not None]:
        raise ValueError(f"{when} requires {', '.join(present)} to be unset")


def _json_number(value: Any) -> Any:
    # bool is an int subclass and lax mode coerces numeric strings; neither is
    # a measurement.
    if isinstance(value, (bool, str, bytes)):
        raise ValueError("expected a JSON number")
    return value


_number = BeforeValidator(_json_number)

FiniteFloat = Annotated[float, _number, Field(allow_inf_nan=False)]
NonNegativeFloat = Annotated[float, _number, Field(ge=0, allow_inf_nan=False)]
PositiveFloat = Annotated[float, _number, Field(gt=0, allow_inf_nan=False)]
Confidence = Annotated[float, _number, Field(ge=0, le=1, allow_inf_nan=False)]
Count = Annotated[int, _number, Field(ge=0)]
PositiveCount = Annotated[int, _number, Field(ge=1)]


def _not_blank(value: str) -> str:
    if not value.strip():
        raise ValueError("must not be blank")
    return value


NonEmptyStr = Annotated[str, AfterValidator(_not_blank)]


def _iana_timezone(value: str) -> str:
    try:
        ZoneInfo(value)
    except (KeyError, ValueError, OSError) as error:  # ZoneInfoNotFoundError is a KeyError
        raise ValueError(f"unknown IANA timezone {value!r}") from error
    return value


IanaTimezone = Annotated[str, AfterValidator(_iana_timezone)]
Sha256Hex = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
