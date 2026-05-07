import importlib.util
from pathlib import Path
import pytest


@pytest.fixture(scope="session")
def helpers():
    spec = importlib.util.spec_from_file_location(
        "helpers",
        Path(__file__).parents[2] / "bin" / "4lm_helpers.py",
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
