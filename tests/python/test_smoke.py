import subprocess
import sys
from pathlib import Path

import pytest

HELPERS = Path(__file__).parents[2] / "bin" / "4lm_helpers.py"
VENV_PYTHON = Path.home() / ".4lm" / "venv" / "bin" / "python"


# Note: sdd_python-migration_p1_c1_help_exits_zero.py::test_helpers_help_exits_zero is identical in behavior.
def test_help_exits_zero():
    result = subprocess.run(
        [sys.executable, str(HELPERS), "--help"],
        capture_output=True,
    )
    assert result.returncode == 0


@pytest.mark.skipif(not VENV_PYTHON.exists(), reason="venv not installed — run: make install")
def test_venv_imports_rich_yaml_pytest():
    result = subprocess.run(
        [str(VENV_PYTHON), "-c", "import rich, yaml, pytest"],
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr.decode()
