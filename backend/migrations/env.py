"""Alembic environment. URL: the config's sqlalchemy.url if set (tests), else
DATABASE_URL, else the Compose default."""
import os

from alembic import context
from sqlalchemy import create_engine

from app.db import metadata
from app.runtime import DEFAULT_DATABASE_URL

config = context.config
url = config.get_main_option("sqlalchemy.url") or os.environ.get("DATABASE_URL", DEFAULT_DATABASE_URL)

with create_engine(url).connect() as connection:
    context.configure(connection=connection, target_metadata=metadata, compare_type=True)
    with context.begin_transaction():
        context.run_migrations()
