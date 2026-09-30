"""Accounts, device keys and pairing codes.

Each device generates its own 256-bit token and registers it; the server keeps
only its hash. A signed-in device can issue a short single-use pairing code
that adds another device to the same account. HOMEOSTAT_API_KEY is the
enrollment secret that creates accounts; outside development it can't read or
write any account's data.
"""
from __future__ import annotations

import hashlib
import hmac
import secrets
from datetime import timedelta
from uuid import UUID, uuid4

from fastapi import Depends, Header, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select, text, update
from sqlalchemy.dialects.postgresql import insert

from app import store
from app.db import devices, pairing_codes, widget_credentials

# Crockford base32: no I, L, O or U, so codes read aloud without confusion.
CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
CODE_LENGTH = 8  # 40 bits, single use, short-lived: guessing is impractical
CODE_TTL = timedelta(minutes=10)


class DeviceIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    device_id: UUID
    token: str = Field(pattern=r"^[0-9a-f]{64}$")
    name: str = Field(min_length=1, max_length=100)


class PairIn(DeviceIn):
    code: str = Field(min_length=1, max_length=32)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def normalize_code(code: str) -> str:
    code = code.upper().replace("-", "").replace(" ", "")
    return code.translate(str.maketrans({"O": "0", "I": "1", "L": "1"}))


def authenticate(conn, token: str) -> tuple[UUID, UUID] | None:
    """(user_id, device_id) for an active device token."""
    row = conn.execute(select(devices.c.user_id, devices.c.id).where(
        devices.c.token_sha256 == digest(token), devices.c.revoked_at.is_(None))).one_or_none()
    return (row.user_id, row.id) if row else None


def install_account_routes(app, engine, user, clock, runtime):
    def response(content, status=200):
        return JSONResponse(content=content, status_code=status, headers={"Cache-Control": "no-store"})

    def register(conn, body: DeviceIn, user_id: UUID) -> JSONResponse:
        store.ensure_user(conn, user_id, "UTC")
        added = conn.execute(insert(devices).values(
            id=body.device_id, user_id=user_id, token_sha256=digest(body.token), name=body.name,
            created_at=clock()).on_conflict_do_nothing().returning(devices.c.id)).scalar_one_or_none()
        if added is None:
            return response({"code": "TOKEN_ALREADY_REGISTERED"}, 409)
        return response({"account_id": str(user_id), "device_id": str(body.device_id)})

    def replay(conn, body: DeviceIn) -> JSONResponse | None:
        """A retried registration returns what the first one did."""
        old = conn.execute(select(devices).where(devices.c.id == body.device_id)).one_or_none()
        if old is None:
            return None
        if old.token_sha256 != digest(body.token) or old.revoked_at is not None:
            return response({"code": "DEVICE_ID_REUSED"}, 409)
        return response({"account_id": str(old.user_id), "device_id": str(old.id)})

    @app.post("/v1/accounts")
    def create_account(body: DeviceIn, x_homeostat_key: str | None = Header(default=None)):
        if not x_homeostat_key or not hmac.compare_digest(x_homeostat_key.encode(), runtime.api_key.encode()):
            return response({"code": "UNAUTHORIZED"}, 401)
        with engine.begin() as conn:
            conn.execute(text("SELECT pg_advisory_xact_lock(hashtext('homeostat.enroll'))"))
            if (done := replay(conn, body)) is not None:
                return done
            # The first account adopts the development user, so data uploaded
            # with the shared key before device keys existed stays with it.
            first = conn.execute(select(devices.c.id).limit(1)).first() is None
            return register(conn, body, runtime.dev_user_id if first else uuid4())

    @app.post("/v1/devices/pair")
    def pair(body: PairIn):
        with engine.begin() as conn:
            if (done := replay(conn, body)) is not None:
                return done
            code = conn.execute(select(pairing_codes).where(
                pairing_codes.c.code_sha256 == digest(normalize_code(body.code))).with_for_update()).one_or_none()
            if code is None or code.used_by is not None or code.expires_at <= clock():
                return response({"code": "INVALID_PAIRING_CODE"}, 401)
            conn.execute(update(pairing_codes).where(pairing_codes.c.code_sha256 == code.code_sha256)
                         .values(used_by=body.device_id))
            return register(conn, body, code.user_id)

    @app.post("/v1/pairing-codes")
    def create_code(request: Request, user_id: UUID = Depends(user)):
        device_id = getattr(request.state, "device_id", None)
        if device_id is None:
            return response({"code": "DEVICE_KEY_REQUIRED"}, 403)
        code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))
        expires_at = clock() + CODE_TTL
        with engine.begin() as conn:
            conn.execute(insert(pairing_codes).values(code_sha256=digest(code), user_id=user_id,
                                                      created_by=device_id, expires_at=expires_at))
        return response({"code": f"{code[:4]}-{code[4:]}", "expires_at": expires_at.isoformat()})

    @app.get("/v1/devices")
    def list_devices(request: Request, user_id: UUID = Depends(user)):
        current = getattr(request.state, "device_id", None)
        with engine.connect() as conn:
            rows = conn.execute(select(devices).where(devices.c.user_id == user_id, devices.c.revoked_at.is_(None))
                                .order_by(devices.c.created_at)).all()
        return response({"devices": [{"device_id": str(r.id), "name": r.name, "created_at": r.created_at.isoformat(),
                                      "current": r.id == current} for r in rows]})

    @app.delete("/v1/devices/{device_id}")
    def remove_device(device_id: UUID, user_id: UUID = Depends(user)):
        now = clock()
        with engine.begin() as conn:
            removed = conn.execute(update(devices).where(
                devices.c.id == device_id, devices.c.user_id == user_id, devices.c.revoked_at.is_(None))
                .values(revoked_at=now).returning(devices.c.id)).scalar_one_or_none()
            if removed is None:
                return response({"code": "NO_SUCH_DEVICE"}, 404)
            # Its widgets and unused pairing codes go with it.
            conn.execute(update(widget_credentials).where(
                widget_credentials.c.device_id == device_id, widget_credentials.c.revoked_at.is_(None))
                .values(revoked_at=now))
            conn.execute(pairing_codes.delete().where(pairing_codes.c.created_by == device_id,
                                                      pairing_codes.c.used_by.is_(None)))
        return response({"revoked": True})
