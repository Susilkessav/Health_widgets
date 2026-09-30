"""Device keys and pairing codes."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "devices",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("token_sha256", sa.Text(), nullable=False, unique=True),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
    )
    op.create_index("ix_devices_user", "devices", ["user_id"])
    op.create_table(
        "pairing_codes",
        sa.Column("code_sha256", sa.Text(), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("created_by", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("used_by", postgresql.UUID(as_uuid=True)),
    )
    op.add_column("widget_credentials", sa.Column("device_id", postgresql.UUID(as_uuid=True)))


def downgrade():
    op.drop_column("widget_credentials", "device_id")
    op.drop_table("pairing_codes")
    op.drop_index("ix_devices_user", table_name="devices")
    op.drop_table("devices")
