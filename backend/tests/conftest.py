import pytest

from app.synthetic.generator import generate_demo
from app.synthetic.models import GenerationConfig
from app.synthetic.scenarios import generate_scenarios
from app.synthetic.writer import build_artifacts


@pytest.fixture(scope="session")
def demo():
    return generate_demo(GenerationConfig())


@pytest.fixture(scope="session")
def scenarios():
    return {dataset.context.id: dataset for dataset in generate_scenarios()}


@pytest.fixture(scope="session")
def artifacts():
    return build_artifacts(GenerationConfig())


# ---------------------------------------------------------------- PostgreSQL
# Database tests use a throwaway database on the Compose server (port 5433),
# created per test session and dropped afterwards; they never touch
# development data. They fail loudly when PostgreSQL is unreachable. Run
# everything else with: pytest -m "not db".
import os  # noqa: E402
from uuid import uuid4  # noqa: E402

from alembic import command  # noqa: E402
from alembic.config import Config  # noqa: E402
from sqlalchemy import create_engine, make_url, text  # noqa: E402
from sqlalchemy.exc import OperationalError  # noqa: E402

from app.db import make_engine, metadata  # noqa: E402
from app.runtime import DEFAULT_DATABASE_URL  # noqa: E402

BACKEND_DIR = __import__("pathlib").Path(__file__).resolve().parents[1]


def _admin():
    base = make_url(os.environ.get("DATABASE_URL", DEFAULT_DATABASE_URL))
    admin = create_engine(base.set(database="postgres"), isolation_level="AUTOCOMMIT")
    try:
        admin.connect().close()
    except OperationalError:
        pytest.fail(f"PostgreSQL is unreachable at {base.host}:{base.port}. Start it with "
                    "`docker compose up -d db`, or run `pytest -m 'not db'`.", pytrace=False)
    return base, admin


def create_database() -> str:
    base, admin = _admin()
    name = f"homeostat_test_{uuid4().hex[:12]}"
    with admin.connect() as connection:
        connection.execute(text(f'CREATE DATABASE "{name}"'))
    admin.dispose()
    return base.set(database=name).render_as_string(hide_password=False)


def drop_database(url: str) -> None:
    _, admin = _admin()
    with admin.connect() as connection:
        connection.execute(text(f'DROP DATABASE IF EXISTS "{make_url(url).database}" WITH (FORCE)'))
    admin.dispose()


def alembic_config(url: str) -> Config:
    config = Config(str(BACKEND_DIR / "alembic.ini"))
    config.set_main_option("sqlalchemy.url", url)
    return config


@pytest.fixture(scope="session")
def database_url():
    url = create_database()
    command.upgrade(alembic_config(url), "head")
    yield url
    drop_database(url)


@pytest.fixture
def db_engine(database_url):
    engine = make_engine(database_url)
    yield engine
    with engine.begin() as connection:
        tables = ", ".join(f'"{name}"' for name in metadata.tables)
        connection.execute(text(f"TRUNCATE {tables} RESTART IDENTITY CASCADE"))
    engine.dispose()


def pytest_collection_modifyitems(items):
    for item in items:
        if {"database_url", "db_engine", "fresh_database_url"} & set(item.fixturenames):
            item.add_marker(pytest.mark.db)
