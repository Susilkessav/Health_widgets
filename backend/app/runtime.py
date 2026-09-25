"""Runtime settings from the environment, and the injectable clock."""
from __future__ import annotations

import os
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from uuid import UUID

from app.config import DEFAULT_PATH

DEFAULT_DATABASE_URL = "postgresql+psycopg://postgres:postgres@localhost:5433/homeostat"
DEFAULT_DEV_USER_ID = UUID("00000000-0000-4000-8000-000000000001")

Clock = Callable[[], datetime]


def system_clock() -> datetime:
    return datetime.now(timezone.utc)


@dataclass(frozen=True)
class Runtime:
    database_url: str
    api_key: str
    dev_user_id: UUID
    development: bool
    config_path: Path
    worker_interval_seconds: float

    def __repr__(self) -> str:  # never print the key
        return f"Runtime(database_url=<set>, development={self.development}, dev_user_id={self.dev_user_id})"


def load_runtime(environ: Mapping[str, str] = os.environ, require_api_key: bool = True) -> Runtime:
    api_key = environ.get("HOMEOSTAT_API_KEY", "").strip()
    if require_api_key and not api_key:
        raise RuntimeError("HOMEOSTAT_API_KEY must be set")
    return Runtime(
        database_url=environ.get("DATABASE_URL", DEFAULT_DATABASE_URL),
        api_key=api_key,
        dev_user_id=UUID(environ.get("HOMEOSTAT_DEV_USER_ID", str(DEFAULT_DEV_USER_ID))),
        development=environ.get("HOMEOSTAT_ENV", "") == "development",
        config_path=Path(environ.get("HOMEOSTAT_CONFIG", str(DEFAULT_PATH))),
        worker_interval_seconds=float(environ.get("HOMEOSTAT_WORKER_INTERVAL_SECONDS", "30")),
    )
