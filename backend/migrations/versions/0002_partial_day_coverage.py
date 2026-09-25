"""partial-day coverage: exact UTC intervals as an alternative to whole days

Revision ID: 0002
Revises: 0001
"""
from alembic import op
import sqlalchemy as sa

revision = '0002'
down_revision = '0001'
branch_labels = None
depends_on = None

FORM = ("(start_day IS NOT NULL AND end_day IS NOT NULL AND start_at IS NULL AND end_at IS NULL "
        "AND start_day <= end_day) OR (start_day IS NULL AND end_day IS NULL AND start_at IS NOT NULL "
        "AND end_at IS NOT NULL AND start_at < end_at)")


def upgrade() -> None:
    op.add_column('coverage_declarations', sa.Column('start_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column('coverage_declarations', sa.Column('end_at', sa.DateTime(timezone=True), nullable=True))
    op.alter_column('coverage_declarations', 'start_day', existing_type=sa.Date(), nullable=True)
    op.alter_column('coverage_declarations', 'end_day', existing_type=sa.Date(), nullable=True)
    op.drop_constraint('ck_coverage_order', 'coverage_declarations', type_='check')
    op.create_check_constraint('ck_coverage_form', 'coverage_declarations', FORM)


def downgrade() -> None:
    op.execute("DELETE FROM coverage_declarations WHERE start_day IS NULL")
    op.drop_constraint('ck_coverage_form', 'coverage_declarations', type_='check')
    op.create_check_constraint('ck_coverage_order', 'coverage_declarations', 'start_day <= end_day')
    op.alter_column('coverage_declarations', 'end_day', existing_type=sa.Date(), nullable=False)
    op.alter_column('coverage_declarations', 'start_day', existing_type=sa.Date(), nullable=False)
    op.drop_column('coverage_declarations', 'end_at')
    op.drop_column('coverage_declarations', 'start_at')
