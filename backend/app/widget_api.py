"""Read-only widget publication and idempotent credential provisioning.

Only hashes of client-generated 256-bit tokens are persisted. Widget tokens
never authenticate ingestion, explanations, or credential administration.
"""
import hashlib
from uuid import UUID

from fastapi import Depends, Header, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert

from app import store
from app.db import recalc_jobs, users, widget_credentials as credentials


class Provision(BaseModel):
    model_config = ConfigDict(extra="forbid")
    operation_id: UUID
    installation_id: UUID
    token: str = Field(pattern=r"^[0-9a-f]{64}$")


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


def install_widget_routes(app, engine, user, clock):
    def response(content, status=200):
        return JSONResponse(content=content, status_code=status, headers={"Cache-Control": "no-store"})

    @app.get("/v1/account")
    def account(user_id: UUID = Depends(user)):
        return response({"account_id": str(user_id)})

    @app.post("/v1/widget/credentials")
    def provision(body: Provision, request: Request, user_id: UUID = Depends(user)):
        token_hash = digest(body.token)
        with engine.begin() as conn:
            store.ensure_user(conn, user_id, "UTC")
            store.lock_user_row(conn, user_id)
            old = conn.execute(select(credentials).where(
                credentials.c.user_id == user_id, credentials.c.operation_id == body.operation_id)).one_or_none()
            if old:
                if old.installation_id != body.installation_id or old.token_sha256 != token_hash:
                    return response({"code": "OPERATION_ID_REUSED"}, 409)
                # A replay cannot resurrect a revoked token.
                return response({"account_id": str(user_id), "revoked": old.revoked_at is not None})
            added = conn.execute(insert(credentials).values(
                user_id=user_id, operation_id=body.operation_id, installation_id=body.installation_id,
                token_sha256=token_hash, created_at=clock(), device_id=request.state.device_id).on_conflict_do_nothing()
                .returning(credentials.c.operation_id)).scalar_one_or_none()
            if added is None:
                return response({"code": "TOKEN_ALREADY_REGISTERED"}, 409)
        return response({"account_id": str(user_id), "revoked": False})

    @app.delete("/v1/widget/credentials/{operation_id}")
    def revoke(operation_id: UUID, user_id: UUID = Depends(user)):
        with engine.begin() as conn:
            conn.execute(update(credentials).where(credentials.c.user_id == user_id,
                credentials.c.operation_id == operation_id, credentials.c.revoked_at.is_(None))
                .values(revoked_at=clock()))
        return response({"revoked": True})

    @app.get("/v1/widget/current")
    def current(authorization: str | None = Header(default=None)):
        if not authorization or not authorization.startswith("Bearer "):
            return response({"code": "UNAUTHORIZED"}, 401)
        # One consistent snapshot includes authorization, accepted revision,
        # pending finalize/retry work, and the last complete publication.
        with engine.connect().execution_options(isolation_level="REPEATABLE READ") as conn, conn.begin():
            user_id = conn.execute(select(credentials.c.user_id).where(
                credentials.c.token_sha256 == digest(authorization[7:]),
                credentials.c.revoked_at.is_(None))).scalar_one_or_none()
            if user_id is None:
                return response({"code": "UNAUTHORIZED"}, 401)
            revision = conn.execute(select(users.c.revision).where(users.c.id == user_id)).scalar_one()
            jobs = conn.execute(select(recalc_jobs.c.attempts).where(
                recalc_jobs.c.user_id == user_id, recalc_jobs.c.status == "pending")).all()
            latest = store.latest_run(conn, user_id)
            status = "failed" if any(j.attempts > 0 for j in jobs) else "pending" if jobs else \
                "ready" if latest else "no_state"
            published = None if latest is None else {
                "day": latest.day.isoformat(), "timezone": latest.timezone,
                "input_revision": latest.input_revision, "run_id": latest.run_id,
                "widget_state": latest.widget_state,
            }
        return response({"schema": 1, "account_id": str(user_id), "calculation_status": status,
                         "accepted_revision": revision, "published": published})
