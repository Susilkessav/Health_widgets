"""lost-anchor reconciliation: visible membership per HealthKit type

Revision ID: 0003
Revises: 0002
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = '0003'
down_revision = '0002'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        'visibility_scans',
        sa.Column('id', sa.BigInteger(), sa.Identity(always=False), nullable=False),
        sa.Column('user_id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('scan_id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('healthkit_type', sa.Text(), nullable=False),
        sa.Column('scope_start_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('members', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column('revision', sa.BigInteger(), nullable=False),
        sa.Column('received_at', sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('user_id', 'scan_id', name='uq_visibility_scan'),
    )
    op.create_index('ix_visibility_user_revision', 'visibility_scans', ['user_id', 'revision'])


def downgrade() -> None:
    op.drop_index('ix_visibility_user_revision', table_name='visibility_scans')
    op.drop_table('visibility_scans')
