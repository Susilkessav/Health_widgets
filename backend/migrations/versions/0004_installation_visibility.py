"""Isolate visibility scans by installation; retain legacy scans for replay."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("visibility_scans", sa.Column("installation_id", postgresql.UUID(as_uuid=True)))
    op.add_column("visibility_scans", sa.Column("scope_end_at", sa.DateTime(timezone=True)))
    op.create_table(
        "installation_records",
        sa.Column("id", sa.BigInteger(), sa.Identity(), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("installation_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("source_record_id", sa.Text(), nullable=False),
        sa.Column("revision", sa.BigInteger(), nullable=False),
        sa.UniqueConstraint("user_id", "installation_id", "source", "source_record_id", "revision", name="uq_installation_record"),
    )
    op.create_index("ix_installation_records_user_revision", "installation_records", ["user_id", "revision"])


def downgrade():
    op.drop_table("installation_records")
    op.drop_column("visibility_scans", "installation_id")
    op.drop_column("visibility_scans", "scope_end_at")
