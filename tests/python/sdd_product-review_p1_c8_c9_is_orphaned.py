"""Tests for is_orphaned() extracted from bin/4lm_helpers.py cmd_diag."""
import importlib.util
import sys
from pathlib import Path

import pytest

_HELPERS = Path(__file__).parents[2] / "bin" / "4lm_helpers.py"

# Load the module without executing top-level __main__ guard.
_spec = importlib.util.spec_from_file_location("helpers", _HELPERS)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

is_orphaned = _mod.is_orphaned


def test_is_orphaned_returns_true_when_admissions_zero():
    """Worker PID in log entries + window_admissions=0 → orphaned."""
    log_entries = ["2026-01-01 pid=4321 admitted request"]
    assert is_orphaned("4321", log_entries, 0) is True


def test_is_orphaned_returns_false_when_admissions_nonzero():
    """Worker PID in log entries but window_admissions=5 → not orphaned."""
    log_entries = ["2026-01-01 pid=4321 admitted request"]
    assert is_orphaned("4321", log_entries, 5) is False


def test_is_orphaned_returns_false_when_pid_not_in_log():
    """PID absent from log entries → not orphaned regardless of admissions."""
    assert is_orphaned("9999", ["pid=1234 something"], 0) is False
