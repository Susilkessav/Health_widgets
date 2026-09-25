"""initial schema

Revision ID: 0001
Revises: 
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = '0001'
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table('config_snapshots',
    sa.Column('config_sha256', sa.Text(), nullable=False),
    sa.Column('payload', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
    sa.Column('first_used_at', sa.DateTime(timezone=True), nullable=False),
    sa.PrimaryKeyConstraint('config_sha256')
    )
    op.create_table('users',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('timezone', sa.Text(), nullable=False),
    sa.Column('revision', sa.BigInteger(), server_default='0', nullable=False),
    sa.Column('revision_received_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_table('calculation_runs',
    sa.Column('run_id', sa.BigInteger(), sa.Identity(always=False), nullable=False),
    sa.Column('user_id', sa.UUID(), nullable=False),
    sa.Column('kind', sa.Text(), nullable=False),
    sa.Column('day', sa.Date(), nullable=False),
    sa.Column('timezone', sa.Text(), nullable=False),
    sa.Column('effective_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('known_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('input_revision', sa.BigInteger(), nullable=False),
    sa.Column('config_sha256', sa.Text(), nullable=False),
    sa.Column('feature_version', sa.Text(), nullable=False),
    sa.Column('engine_version', sa.Text(), nullable=False),
    sa.Column('presentation_version', sa.Text(), nullable=False),
    sa.Column('job_id', sa.BigInteger(), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
    sa.CheckConstraint("kind IN ('sync', 'finalize', 'rebuild')", name='ck_run_kind'),
    sa.CheckConstraint('known_at >= effective_at', name='ck_run_known_after_effective'),
    sa.ForeignKeyConstraint(['config_sha256'], ['config_snapshots.config_sha256'], ),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ),
    sa.PrimaryKeyConstraint('run_id'),
    sa.UniqueConstraint('user_id', 'kind', 'day', 'timezone', 'effective_at', 'known_at', 'input_revision', 'config_sha256', 'feature_version', 'engine_version', 'presentation_version', name='uq_calculation_runs_context')
    )
    op.create_index('ix_runs_latest', 'calculation_runs', ['user_id', 'day', sa.literal_column('input_revision DESC'), sa.literal_column('run_id DESC')], unique=False)
    op.create_table('coverage_declarations',
    sa.Column('id', sa.BigInteger(), sa.Identity(always=False), nullable=False),
    sa.Column('user_id', sa.UUID(), nullable=False),
    sa.Column('domain', sa.Text(), nullable=False),
    sa.Column('start_day', sa.Date(), nullable=False),
    sa.Column('end_day', sa.Date(), nullable=False),
    sa.Column('timezone', sa.Text(), nullable=False),
    sa.Column('status', sa.Text(), nullable=False),
    sa.Column('revision', sa.BigInteger(), nullable=False),
    sa.Column('received_at', sa.DateTime(timezone=True), nullable=False),
    sa.CheckConstraint("domain IN ('sleep', 'hrv', 'rhr', 'movement', 'workout')", name='ck_coverage_domain'),
    sa.CheckConstraint("status IN ('complete', 'unavailable')", name='ck_coverage_status'),
    sa.CheckConstraint('start_day <= end_day', name='ck_coverage_order'),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_coverage_user_revision', 'coverage_declarations', ['user_id', 'revision'], unique=False)
    op.create_table('health_events',
    sa.Column('id', sa.BigInteger(), sa.Identity(always=False), nullable=False),
    sa.Column('user_id', sa.UUID(), nullable=False),
    sa.Column('source', sa.Text(), nullable=False),
    sa.Column('source_record_id', sa.Text(), nullable=False),
    sa.Column('event_type', sa.Text(), nullable=False),
    sa.Column('payload_sha256', sa.Text(), nullable=False),
    sa.Column('observed_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('start_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('end_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('payload', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
    sa.Column('revision', sa.BigInteger(), nullable=False),
    sa.Column('received_at', sa.DateTime(timezone=True), nullable=False),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('user_id', 'source', 'source_record_id', 'event_type', 'payload_sha256', name='uq_health_events_version')
    )
    op.create_index('ix_health_events_end_at', 'health_events', ['user_id', 'end_at'], unique=False)
    op.create_index('ix_health_events_identity', 'health_events', ['user_id', 'source', 'source_record_id', 'event_type'], unique=False)
    op.create_index('ix_health_events_observed_at', 'health_events', ['user_id', 'observed_at'], unique=False)
    op.create_index('ix_health_events_revision', 'health_events', ['user_id', 'revision'], unique=False)
    op.create_index('ix_health_events_type', 'health_events', ['user_id', 'event_type'], unique=False)
    op.create_table('recalc_jobs',
    sa.Column('id', sa.BigInteger(), sa.Identity(always=False), nullable=False),
    sa.Column('user_id', sa.UUID(), nullable=False),
    sa.Column('kind', sa.Text(), nullable=False),
    sa.Column('target_revision', sa.BigInteger(), nullable=False),
    sa.Column('from_day', sa.Date(), nullable=False),
    sa.Column('status', sa.Text(), server_default='pending', nullable=False),
    sa.Column('attempts', sa.Integer(), server_default='0', nullable=False),
    sa.Column('next_attempt_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('last_error_code', sa.Text(), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('completed_at', sa.DateTime(timezone=True), nullable=True),
    sa.CheckConstraint("kind IN ('sync', 'finalize')", name='ck_job_kind'),
    sa.CheckConstraint("status IN ('pending', 'done')", name='ck_job_status'),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_recalc_jobs_due', 'recalc_jobs', ['status', 'next_attempt_at'], unique=False)
    op.create_index('ix_recalc_jobs_user', 'recalc_jobs', ['user_id', 'status'], unique=False)
    op.create_table('sync_requests',
    sa.Column('user_id', sa.UUID(), nullable=False),
    sa.Column('request_id', sa.UUID(), nullable=False),
    sa.Column('body_sha256', sa.Text(), nullable=False),
    sa.Column('revision', sa.BigInteger(), nullable=True),
    sa.Column('received_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('status_counts', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
    sa.Column('response', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ),
    sa.PrimaryKeyConstraint('user_id', 'request_id')
    )
    op.create_table('event_receipts',
    sa.Column('user_id', sa.UUID(), nullable=False),
    sa.Column('event_id', sa.UUID(), nullable=False),
    sa.Column('payload_sha256', sa.Text(), nullable=False),
    sa.Column('first_request_id', sa.UUID(), nullable=False),
    sa.Column('first_received_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('outcome', sa.Text(), nullable=False),
    sa.Column('code', sa.Text(), nullable=True),
    sa.Column('health_event_id', sa.BigInteger(), nullable=True),
    sa.CheckConstraint("outcome IN ('accepted', 'duplicate', 'conflict', 'rejected')", name='ck_receipt_outcome'),
    sa.ForeignKeyConstraint(['health_event_id'], ['health_events.id'], ),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ),
    sa.PrimaryKeyConstraint('user_id', 'event_id')
    )
    op.create_table('run_outputs',
    sa.Column('run_id', sa.BigInteger(), nullable=False),
    sa.Column('report', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
    sa.Column('state', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
    sa.Column('widget_state', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
    sa.Column('input_sha256', sa.Text(), nullable=False),
    sa.ForeignKeyConstraint(['run_id'], ['calculation_runs.run_id'], ),
    sa.PrimaryKeyConstraint('run_id')
    )


def downgrade() -> None:
    op.drop_table('run_outputs')
    op.drop_table('event_receipts')
    op.drop_table('sync_requests')
    op.drop_index('ix_recalc_jobs_user', table_name='recalc_jobs')
    op.drop_index('ix_recalc_jobs_due', table_name='recalc_jobs')
    op.drop_table('recalc_jobs')
    op.drop_index('ix_health_events_type', table_name='health_events')
    op.drop_index('ix_health_events_revision', table_name='health_events')
    op.drop_index('ix_health_events_observed_at', table_name='health_events')
    op.drop_index('ix_health_events_identity', table_name='health_events')
    op.drop_index('ix_health_events_end_at', table_name='health_events')
    op.drop_table('health_events')
    op.drop_index('ix_coverage_user_revision', table_name='coverage_declarations')
    op.drop_table('coverage_declarations')
    op.drop_index('ix_runs_latest', table_name='calculation_runs')
    op.drop_table('calculation_runs')
    op.drop_table('users')
    op.drop_table('config_snapshots')
