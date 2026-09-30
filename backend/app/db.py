"""PostgreSQL schema (SQLAlchemy Core), engine and per-user lock.

Migrations in migrations/versions/ are the source of truth for the live
schema; a test asserts they match these definitions.
"""
from __future__ import annotations

from uuid import UUID

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    Column,
    Date,
    DateTime,
    ForeignKey,
    Identity,
    Index,
    Integer,
    MetaData,
    PrimaryKeyConstraint,
    Table,
    Text,
    UniqueConstraint,
    create_engine,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.engine import Connection, Engine

metadata = MetaData()
TZ = DateTime(timezone=True)


def _user() -> Column:
    return Column("user_id", PgUUID(as_uuid=True), ForeignKey("users.id"), nullable=False)


users = Table(
    "users", metadata,
    Column("id", PgUUID(as_uuid=True), primary_key=True),
    Column("timezone", Text, nullable=False),
    Column("revision", BigInteger, nullable=False, server_default="0"),
    Column("revision_received_at", TZ),
    Column("created_at", TZ, nullable=False, server_default=func.now()),
)

sync_requests = Table(
    "sync_requests", metadata,
    _user(),
    Column("request_id", PgUUID(as_uuid=True), nullable=False),
    Column("body_sha256", Text, nullable=False),
    Column("revision", BigInteger),
    Column("received_at", TZ, nullable=False),
    Column("status_counts", JSONB, nullable=False),
    Column("response", JSONB, nullable=False),
    PrimaryKeyConstraint("user_id", "request_id"),
)

widget_credentials = Table(
    "widget_credentials", metadata,
    _user(),
    Column("operation_id", PgUUID(as_uuid=True), nullable=False),
    Column("installation_id", PgUUID(as_uuid=True), nullable=False),
    Column("token_sha256", Text, nullable=False, unique=True),
    Column("created_at", TZ, nullable=False),
    Column("revoked_at", TZ),
    # The signed-in device that provisioned it (migration 0006); removing the
    # device revokes its widgets too. NULL for development-key provisioning.
    Column("device_id", PgUUID(as_uuid=True)),
    PrimaryKeyConstraint("user_id", "operation_id"),
)

# Device keys (migration 0006): each device holds its own random token; only
# the hash is stored.
devices = Table(
    "devices", metadata,
    Column("id", PgUUID(as_uuid=True), primary_key=True),
    _user(),
    Column("token_sha256", Text, nullable=False, unique=True),
    Column("name", Text, nullable=False),
    Column("created_at", TZ, nullable=False),
    Column("revoked_at", TZ),
    Index("ix_devices_user", "user_id"),
)

# Single-use codes that add another device to an account.
pairing_codes = Table(
    "pairing_codes", metadata,
    Column("code_sha256", Text, primary_key=True),
    _user(),
    Column("created_by", PgUUID(as_uuid=True), nullable=False),
    Column("expires_at", TZ, nullable=False),
    Column("used_by", PgUUID(as_uuid=True)),
)

health_events = Table(
    "health_events", metadata,
    Column("id", BigInteger, Identity(), primary_key=True),
    _user(),
    Column("source", Text, nullable=False),
    Column("source_record_id", Text, nullable=False),
    Column("event_type", Text, nullable=False),
    Column("payload_sha256", Text, nullable=False),
    Column("observed_at", TZ),
    Column("start_at", TZ),
    Column("end_at", TZ),
    Column("payload", JSONB, nullable=False),
    Column("revision", BigInteger, nullable=False),
    Column("received_at", TZ, nullable=False),
    UniqueConstraint("user_id", "source", "source_record_id", "event_type", "payload_sha256",
                     name="uq_health_events_version"),
    Index("ix_health_events_identity", "user_id", "source", "source_record_id", "event_type"),
    Index("ix_health_events_revision", "user_id", "revision"),
    Index("ix_health_events_end_at", "user_id", "end_at"),
    Index("ix_health_events_observed_at", "user_id", "observed_at"),
    Index("ix_health_events_type", "user_id", "event_type"),
)

event_receipts = Table(
    "event_receipts", metadata,
    _user(),
    Column("event_id", PgUUID(as_uuid=True), nullable=False),
    Column("payload_sha256", Text, nullable=False),
    Column("first_request_id", PgUUID(as_uuid=True), nullable=False),
    Column("first_received_at", TZ, nullable=False),
    Column("outcome", Text, nullable=False),
    Column("code", Text),
    Column("health_event_id", BigInteger, ForeignKey("health_events.id")),
    PrimaryKeyConstraint("user_id", "event_id"),
    CheckConstraint("outcome IN ('accepted', 'duplicate', 'conflict', 'rejected')", name="ck_receipt_outcome"),
)

coverage_declarations = Table(
    "coverage_declarations", metadata,
    Column("id", BigInteger, Identity(), primary_key=True),
    _user(),
    Column("domain", Text, nullable=False),
    # Either whole local days (start_day/end_day) or an exact UTC interval
    # (start_at/end_at) for a partial day (migration 0002).
    Column("start_day", Date),
    Column("end_day", Date),
    Column("start_at", TZ),
    Column("end_at", TZ),
    Column("timezone", Text, nullable=False),
    Column("status", Text, nullable=False),
    Column("revision", BigInteger, nullable=False),
    Column("received_at", TZ, nullable=False),
    CheckConstraint("domain IN ('sleep', 'hrv', 'rhr', 'movement', 'workout')", name="ck_coverage_domain"),
    CheckConstraint("status IN ('complete', 'unavailable')", name="ck_coverage_status"),
    CheckConstraint("(start_day IS NOT NULL AND end_day IS NOT NULL AND start_at IS NULL AND end_at IS NULL "
                    "AND start_day <= end_day) OR (start_day IS NULL AND end_day IS NULL AND start_at IS NOT NULL "
                    "AND end_at IS NOT NULL AND start_at < end_at)", name="ck_coverage_form"),
    Index("ix_coverage_user_revision", "user_id", "revision"),
)

# Lost-anchor reconciliation (Step 9-13 plan section 3B): the provider records
# of one HealthKit type that a completed fresh scan found visible. Records of
# that type in scope, received before the scan and not listed, are withdrawn
# from visibility (not tombstoned) until a later scan lists them again.
visibility_scans = Table(
    "visibility_scans", metadata,
    Column("id", BigInteger, Identity(), primary_key=True),
    _user(),
    Column("scan_id", PgUUID(as_uuid=True), nullable=False),
    Column("installation_id", PgUUID(as_uuid=True)),
    Column("healthkit_type", Text, nullable=False),
    Column("scope_start_at", TZ, nullable=False),
    Column("scope_end_at", TZ),
    Column("members", JSONB, nullable=False),
    Column("revision", BigInteger, nullable=False),
    Column("received_at", TZ, nullable=False),
    UniqueConstraint("user_id", "scan_id", name="uq_visibility_scan"),
    Index("ix_visibility_user_revision", "user_id", "revision"),
)

# Append-only observations of provider identities by an installation. Duplicate
# provider content still establishes visibility on a second device.
installation_records = Table(
    "installation_records", metadata,
    Column("id", BigInteger, Identity(), primary_key=True),
    _user(),
    Column("installation_id", PgUUID(as_uuid=True), nullable=False),
    Column("source", Text, nullable=False),
    Column("source_record_id", Text, nullable=False),
    Column("revision", BigInteger, nullable=False),
    UniqueConstraint("user_id", "installation_id", "source", "source_record_id", "revision", name="uq_installation_record"),
    Index("ix_installation_records_user_revision", "user_id", "revision"),
)

recalc_jobs = Table(
    "recalc_jobs", metadata,
    Column("id", BigInteger, Identity(), primary_key=True),
    _user(),
    Column("kind", Text, nullable=False),
    Column("target_revision", BigInteger, nullable=False),
    Column("from_day", Date, nullable=False),
    Column("status", Text, nullable=False, server_default="pending"),
    Column("attempts", Integer, nullable=False, server_default="0"),
    Column("next_attempt_at", TZ, nullable=False),
    Column("last_error_code", Text),
    Column("created_at", TZ, nullable=False),
    Column("completed_at", TZ),
    CheckConstraint("kind IN ('sync', 'finalize')", name="ck_job_kind"),
    CheckConstraint("status IN ('pending', 'done')", name="ck_job_status"),
    Index("ix_recalc_jobs_due", "status", "next_attempt_at"),
    Index("ix_recalc_jobs_user", "user_id", "status"),
)

config_snapshots = Table(
    "config_snapshots", metadata,  # global: settings are not user data
    Column("config_sha256", Text, primary_key=True),
    Column("payload", JSONB, nullable=False),
    Column("first_used_at", TZ, nullable=False),
)

calculation_runs = Table(
    "calculation_runs", metadata,
    Column("run_id", BigInteger, Identity(), primary_key=True),
    _user(),
    Column("kind", Text, nullable=False),
    Column("day", Date, nullable=False),
    Column("timezone", Text, nullable=False),
    Column("effective_at", TZ, nullable=False),
    Column("known_at", TZ, nullable=False),
    Column("input_revision", BigInteger, nullable=False),
    Column("config_sha256", Text, ForeignKey("config_snapshots.config_sha256"), nullable=False),
    Column("feature_version", Text, nullable=False),
    Column("engine_version", Text, nullable=False),
    Column("presentation_version", Text, nullable=False),
    Column("job_id", BigInteger),
    Column("created_at", TZ, nullable=False),
    CheckConstraint("kind IN ('sync', 'finalize', 'rebuild')", name="ck_run_kind"),
    CheckConstraint("known_at >= effective_at", name="ck_run_known_after_effective"),
    UniqueConstraint("user_id", "kind", "day", "timezone", "effective_at", "known_at", "input_revision",
                     "config_sha256", "feature_version", "engine_version", "presentation_version",
                     name="uq_calculation_runs_context"),
    Index("ix_runs_latest", "user_id", "day", text("input_revision DESC"), text("run_id DESC")),
)

run_outputs = Table(
    "run_outputs", metadata,
    Column("run_id", BigInteger, ForeignKey("calculation_runs.run_id"), primary_key=True),
    Column("report", JSONB, nullable=False),
    Column("state", JSONB, nullable=False),
    Column("widget_state", JSONB, nullable=False),
    Column("input_sha256", Text, nullable=False),
)


def make_engine(url: str) -> Engine:
    return create_engine(url, pool_pre_ping=True, future=True)


def lock_user(connection: Connection, user_id: UUID) -> None:
    """Transaction-scoped advisory lock serializing calculations for one user.
    Released at commit or rollback; never spans two transactions."""
    connection.execute(text("SELECT pg_advisory_xact_lock(hashtextextended(:user_id, 0))"),
                       {"user_id": str(user_id)})
