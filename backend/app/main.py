"""FastAPI app (Step 6-8 plan section 11).

    HOMEOSTAT_API_KEY=... uv run uvicorn app.main:app

Logs and error bodies never contain health values, event IDs or record IDs.
"""
from __future__ import annotations

import hmac
import json
import logging
from contextlib import asynccontextmanager
from datetime import date
from uuid import UUID

from fastapi import Depends, FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import ValidationError
from sqlalchemy import text
from sqlalchemy.engine import Engine
from sqlalchemy.exc import InterfaceError, OperationalError
from starlette.concurrency import run_in_threadpool

from app import accounts, store
from app.config import Settings, load_settings
from app.db import make_engine
from app.features.selection import local_date
from app.ingest import RequestIdReused, SyncRequest, ingest
from app.recalc import process_user
from app.runtime import Clock, Runtime, load_runtime, system_clock
from app.worker import Worker
from app.widget_api import install_widget_routes

MAX_BODY_BYTES = 5 * 1024 * 1024
INLINE_BUDGET_SECONDS = 10
log = logging.getLogger("homeostat.api")


class BodyTooLarge(Exception):
    pass


async def bounded_body(request: Request, limit: int = MAX_BODY_BYTES) -> bytes:
    """Stop receiving once the cap is exceeded, even without Content-Length."""
    body = bytearray()
    async for chunk in request.stream():
        if len(chunk) > limit - len(body):
            raise BodyTooLarge
        body.extend(chunk)
    return bytes(body)


class JsonFormatter(logging.Formatter):
    """One JSON object per line: the message plus the structured `event` fields."""

    def format(self, record: logging.LogRecord) -> str:
        return json.dumps({"logger": record.name, "level": record.levelname, "message": record.getMessage(),
                           **getattr(record, "event", {})}, default=str, sort_keys=True)


def error(status: int, code: str, **extra) -> JSONResponse:
    return JSONResponse(status_code=status, content={"code": code, **extra})


def sanitized(error_list) -> list[dict]:
    """Codes and field paths only: never echo submitted values."""
    return [{"code": e["type"], "field_path": ".".join(str(part) for part in e["loc"])} for e in error_list]


def create_app(runtime: Runtime | None = None, clock: Clock = system_clock, settings: Settings | None = None,
               engine: Engine | None = None, inline_budget_seconds: float = INLINE_BUDGET_SECONDS) -> FastAPI:
    runtime = runtime or load_runtime()
    settings = settings or load_settings(runtime.config_path)
    engine = engine or make_engine(runtime.database_url)
    homeostat_log = logging.getLogger("homeostat")
    if not homeostat_log.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(JsonFormatter())
        homeostat_log.addHandler(handler)
        homeostat_log.setLevel(logging.INFO)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        worker = Worker(engine, settings, runtime.worker_interval_seconds, clock) \
            if runtime.worker_interval_seconds > 0 else None
        if worker:
            worker.start()
        yield
        if worker:
            worker.stop()

    app = FastAPI(title="Homeostat", version="G1", lifespan=lifespan)

    @app.exception_handler(RequestValidationError)
    async def invalid_request(_: Request, exc: RequestValidationError) -> JSONResponse:
        return error(422, "INVALID_REQUEST", errors=sanitized(exc.errors()))

    def user(request: Request, authorization: str | None = Header(default=None),
             x_homeostat_key: str | None = Header(default=None)) -> UUID:
        """A device key (Authorization: Bearer). In development the shared
        enrollment key also signs in, as the development user."""
        request.state.device_id = None
        if authorization and authorization.startswith("Bearer "):
            with engine.connect() as conn:
                found = accounts.authenticate(conn, authorization.removeprefix("Bearer "))
            if found is None:
                raise _Unauthorized()
            request.state.device_id = found[1]
            return found[0]
        if runtime.development and x_homeostat_key \
                and hmac.compare_digest(x_homeostat_key.encode(), runtime.api_key.encode()):
            return runtime.dev_user_id
        raise _Unauthorized()

    @app.exception_handler(_Unauthorized)
    async def unauthorized(_: Request, __: Exception) -> JSONResponse:
        return error(401, "UNAUTHORIZED")

    def state_block(conn, user_id: UUID, revision: int | None) -> dict:
        latest = store.latest_run(conn, user_id)
        widget = latest.widget_state if latest else None
        # (input_revision, run_id) orders published states: a client keeps a
        # state only if this pair is at least the one it already has.
        order = {"input_revision": latest.input_revision, "run_id": latest.run_id} if latest else \
            {"input_revision": None, "run_id": None}
        if revision is None:
            return {"status": "unchanged", "widget_state": widget, **order}
        if latest is not None and latest.input_revision >= revision:
            return {"status": "published", "widget_state": widget, **order}
        return {"status": "pending", "widget_state": None, "input_revision": None, "run_id": None}

    def handle_sync(user_id: UUID, body: bytes) -> JSONResponse:
        try:
            request = SyncRequest.model_validate_json(body)
        except ValidationError as exc:
            if any(e["type"] == "too_long" and e["loc"][:1] == ("events",) for e in exc.errors()):
                return error(413, "TOO_MANY_EVENTS")
            return error(422, "INVALID_REQUEST", errors=sanitized(exc.errors()))
        now = clock()
        try:
            with engine.begin() as conn:
                result = ingest(conn, user_id, body, request, now)
        except RequestIdReused:
            return error(409, "REQUEST_ID_REUSED")
        except (OperationalError, InterfaceError):
            return JSONResponse(status_code=503, content={"code": "DATABASE_UNAVAILABLE"},
                                headers={"Retry-After": "30"})
        if result.revision is not None and not result.replayed:
            process_user(engine, user_id, settings, now, budget_seconds=inline_budget_seconds)
        with engine.connect() as conn:
            state = state_block(conn, user_id, result.revision)
        log.info("sync", extra={"event": {
            "request_id": str(request.request_id), "revision": result.revision, "replayed": result.replayed,
            "counts": result.counts, "event_types": result.event_types,
            "affected_days": result.response["affected_days"],
            "days_beyond_recalc_window": result.response["days_beyond_recalc_window"],
            "state_status": state["status"], "http_status": 200}})
        return JSONResponse(content={**result.response, "state": state})

    @app.post("/v1/health/sync")
    async def health_sync(request: Request, user_id: UUID = Depends(user)) -> JSONResponse:
        declared = request.headers.get("content-length")
        if declared and declared.isdigit() and int(declared) > MAX_BODY_BYTES:
            return error(413, "BODY_TOO_LARGE")
        try:
            body = await bounded_body(request)
        except BodyTooLarge:
            return error(413, "BODY_TOO_LARGE")
        return await run_in_threadpool(handle_sync, user_id, body)

    def run_payload(row) -> dict:
        return {"day": row.day.isoformat(), "effective_at": row.effective_at.isoformat(),
                "input_revision": row.input_revision, "run_id": row.run_id, "health_state": row.state,
                "widget_state": row.widget_state}

    @app.get("/v1/state/current")
    def state_current(user_id: UUID = Depends(user)) -> JSONResponse:
        with engine.connect() as conn:
            latest = store.latest_run(conn, user_id)
            if latest is None:
                return error(404, "NO_STATE_YET")
            _, _, zone = store.current_revision(conn, user_id)
        return JSONResponse(content={**run_payload(latest), "is_today": latest.day == local_date(clock(), zone)})

    install_widget_routes(app, engine, user, clock)
    accounts.install_account_routes(app, engine, user, clock, runtime)

    @app.get("/v1/state/runs/{run_id}")
    def state_for_run(run_id: int, user_id: UUID = Depends(user)) -> JSONResponse:
        from app.db import calculation_runs
        with engine.connect() as conn:
            row = conn.execute(store._latest_runs(user_id).where(calculation_runs.c.run_id == run_id)).one_or_none()
        if row is None:
            return error(404, "NO_STATE_FOR_RUN")
        return JSONResponse(content={**run_payload(row), "is_today": row.day == local_date(clock(), row.timezone)}, headers={"Cache-Control": "no-store"})

    @app.get("/v1/state/{day}")
    def state_for_day(day: date, user_id: UUID = Depends(user)) -> JSONResponse:
        with engine.connect() as conn:
            row = store.latest_run(conn, user_id, day)
        if row is None:
            return error(404, "NO_STATE_FOR_DAY")
        return JSONResponse(content={**run_payload(row), "finalized": row.kind in ("finalize", "rebuild")})

    if runtime.development:
        @app.get("/v1/debug/features/{day}")
        def debug_features(day: date, user_id: UUID = Depends(user)) -> JSONResponse:
            with engine.connect() as conn:
                row = store.latest_run(conn, user_id, day)
            if row is None:
                return error(404, "NO_STATE_FOR_DAY")
            return JSONResponse(content=row.report)

    @app.get("/healthz")
    def healthz() -> JSONResponse:
        try:
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
        except (OperationalError, InterfaceError):
            return JSONResponse(status_code=503, content={"database": "unavailable"})
        return JSONResponse(content={"database": "ok"})

    return app


class _Unauthorized(Exception):
    pass


def __getattr__(name: str):
    # `uvicorn app.main:app` builds the app lazily, so importing this module
    # (e.g. in tests) doesn't require HOMEOSTAT_API_KEY.
    if name == "app":
        return create_app()
    raise AttributeError(name)
