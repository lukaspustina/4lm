import argparse
import io
import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent.parent
HELPERS = REPO_ROOT / "bin" / "4lm_helpers.py"
FIXTURES = Path(__file__).parent / "fixtures"


def run_recommend(rec, lm, active_paths="", limit=5):
    result = subprocess.run(
        [sys.executable, str(HELPERS), "recommend", str(rec), str(lm), active_paths, str(limit)],
        capture_output=True,
        text=True,
    )
    return result


def test_normalize_strips_org_prefix(helpers):
    assert helpers.normalize("mlx-community/Qwen2.5-Coder-32B-Instruct-4bit") == "qwen2.5-coder-32b"


def test_normalize_llama(helpers):
    assert helpers.normalize("mlx-community/Llama-3.1-8B-Instruct-8bit") == "llama-3.1-8b"


def test_normalize_already_clean(helpers):
    assert helpers.normalize("llama-3.1-8b") == "llama-3.1-8b"


def test_recommend_five_rows_in_top():
    result = run_recommend(FIXTURES / "rec.json", FIXTURES / "lm.json", "", 5)
    assert result.returncode == 0
    # Count lines that look like data rows (start with spaces then a rank number)
    rows = [l for l in result.stdout.splitlines() if l.strip() and l.strip()[0].isdigit()]
    assert len(rows) == 5


def test_recommend_active_model_outside_top():
    # Llama-3.3-70B is rank 8; active_paths contains it; limit=5 → appears after separator
    active = "mlx-community/Llama-3.3-70B-Instruct-4bit"
    result = run_recommend(FIXTURES / "rec.json", FIXTURES / "lm.json", active, 5)
    assert result.returncode == 0
    assert "active profile" in result.stdout
    assert "Llama-3.3-70B" in result.stdout


def test_recommend_missing_rec_file():
    result = run_recommend(FIXTURES / "nonexistent.json", FIXTURES / "lm.json")
    assert result.returncode == 1
    assert result.stderr


def test_recommend_corrupt_lm_file(tmp_path):
    bad_lm = tmp_path / "bad.json"
    bad_lm.write_text("not json")
    result = run_recommend(FIXTURES / "rec.json", bad_lm, "", 5)
    # corrupt lm.json is tolerated (treated as empty benchmarks), not a fatal error
    assert result.returncode == 0
