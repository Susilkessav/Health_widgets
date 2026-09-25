"""Background recalculation: a thread inside the API process, and a CLI.

    python -m app.worker --once      # sweep and run everything due, then exit
"""
from __future__ import annotations

import argparse
import logging
import threading

from sqlalchemy.engine import Engine

from app.config import Settings, load_settings
from app.db import make_engine
from app.recalc import run_pending
from app.runtime import Clock, load_runtime, system_clock

log = logging.getLogger("homeostat.worker")


class Worker:
    """Polls every `interval` seconds (and once at start). Pending jobs survive
    crashes and restarts because they live in PostgreSQL."""

    def __init__(self, engine: Engine, settings: Settings, interval: float, clock: Clock = system_clock):
        self.engine, self.settings, self.interval, self.clock = engine, settings, interval, clock
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, name="homeostat-worker", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=30)

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                run_pending(self.engine, self.settings, self.clock())
            except Exception as error:  # keep polling; failures are recorded per job
                log.warning("worker", extra={"event": {"outcome": "poll_failed", "error": type(error).__name__}})
            self._stop.wait(self.interval)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run pending Homeostat recalculations.")
    parser.add_argument("--once", action="store_true", required=True, help="Run everything due, then exit.")
    parser.parse_args()
    runtime = load_runtime(require_api_key=False)
    engine = make_engine(runtime.database_url)
    published = run_pending(engine, load_settings(runtime.config_path), system_clock())
    print(f"Published {published} user calculation(s).")


if __name__ == "__main__":
    main()
