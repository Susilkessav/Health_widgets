"""The migration builds, removes and rebuilds the schema, and matches app/db.py."""
import pytest
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from sqlalchemy import create_engine, inspect

from app.db import metadata
from tests.conftest import alembic_config, create_database, drop_database


@pytest.fixture
def fresh_database_url():
    url = create_database()
    yield url
    drop_database(url)


def test_upgrade_downgrade_upgrade(fresh_database_url):
    config = alembic_config(fresh_database_url)
    engine = create_engine(fresh_database_url)
    command.upgrade(config, "head")
    assert set(metadata.tables) <= set(inspect(engine).get_table_names())
    command.downgrade(config, "base")
    assert set(inspect(engine).get_table_names()) == {"alembic_version"}
    command.upgrade(config, "head")
    with engine.connect() as connection:
        assert compare_metadata(MigrationContext.configure(connection), metadata) == []
    engine.dispose()
