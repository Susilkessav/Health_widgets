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
