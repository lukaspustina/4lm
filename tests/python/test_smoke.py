import subprocess
import sys
from pathlib import Path

HELPERS = Path(__file__).parents[2] / "bin" / "4lm_helpers.py"


def test_help_exits_zero():
    result = subprocess.run(
        [sys.executable, str(HELPERS), "--help"],
        capture_output=True,
    )
    assert result.returncode == 0
