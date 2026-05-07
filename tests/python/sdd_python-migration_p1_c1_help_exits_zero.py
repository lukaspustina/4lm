import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent.parent
HELPERS = REPO_ROOT / "bin" / "4lm_helpers.py"


def test_helpers_help_exits_zero():
    result = subprocess.run(
        [sys.executable, str(HELPERS), "--help"],
        capture_output=True,
    )
    assert result.returncode == 0
