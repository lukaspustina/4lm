import argparse
import io
import json
import sys
import urllib.error
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

REPO_ROOT = Path(__file__).parent.parent.parent


def _has_rich():
    try:
        import rich  # noqa: F401
        return True
    except ImportError:
        return False


requires_venv = pytest.mark.skipif(
    not _has_rich(), reason="venv not installed — run: make install"
)


def _make_repo(tmp_path, req_txt="", req_helpers="", brewfile=""):
    (tmp_path / "requirements.txt").write_text(req_txt)
    (tmp_path / "requirements-helpers.txt").write_text(req_helpers)
    (tmp_path / "Brewfile").write_text(brewfile)
    return tmp_path


def _pypi_mock(versions: dict):
    def _urlopen(url, timeout=None):
        url_str = str(url)
        for pkg, ver in versions.items():
            if f"/{pkg}/json" in url_str:
                body = json.dumps({"info": {"version": ver}}).encode()
                resp = MagicMock()
                resp.__enter__ = lambda s: s
                resp.__exit__ = MagicMock(return_value=False)
                resp.read.return_value = body
                return resp
        raise urllib.error.URLError("not found")

    return _urlopen


def _run_outdated(helpers, repo_dir, porcelain=False, capture=True):
    args = argparse.Namespace(repo_dir=str(repo_dir), porcelain=porcelain)
    if capture:
        buf = io.StringIO()
        old_stdout, sys.stdout = sys.stdout, buf
        try:
            rc = helpers.cmd_outdated(args)
        finally:
            sys.stdout = old_stdout
        return rc, buf.getvalue()
    return helpers.cmd_outdated(args), ""


# ── _parse_req_file ──────────────────────────────────────────────────────────

def test_parse_req_file_exact_pin(helpers, tmp_path):
    req = tmp_path / "req.txt"
    req.write_text("mlx-openai-server==1.8.0\nopen-webui==0.6.43\n")
    result = helpers._parse_req_file(str(req))
    assert ("mlx-openai-server", "1.8.0") in result
    assert ("open-webui", "0.6.43") in result


def test_parse_req_file_floor_ceiling(helpers, tmp_path):
    req = tmp_path / "req.txt"
    req.write_text("rich>=13.9,<14\npyyaml>=6.0,<7\n")
    result = helpers._parse_req_file(str(req))
    assert ("rich", "13.9") in result
    assert ("pyyaml", "6.0") in result


def test_parse_req_file_strips_extras(helpers, tmp_path):
    req = tmp_path / "req.txt"
    req.write_text("huggingface_hub[cli]==0.24.0\n")
    result = helpers._parse_req_file(str(req))
    assert ("huggingface_hub", "0.24.0") in result


def test_parse_req_file_unknown_format_skips(helpers, tmp_path, capsys):
    req = tmp_path / "req.txt"
    req.write_text("somepackage~=1.0\n")
    result = helpers._parse_req_file(str(req))
    assert result == []
    captured = capsys.readouterr()
    assert "warning" in captured.err


# ── outdated integration ─────────────────────────────────────────────────────

@requires_venv
def test_porcelain_outdated_package(helpers, tmp_path):
    repo = _make_repo(tmp_path, req_txt="mlx-openai-server==1.8.0\n", req_helpers="", brewfile="")
    brew_json = json.dumps({"formulae": [], "casks": []})
    with patch("urllib.request.urlopen", side_effect=_pypi_mock({"mlx-openai-server": "1.8.1"})), \
         patch("subprocess.run", return_value=MagicMock(returncode=0, stdout=brew_json, stderr="")):
        rc, out = _run_outdated(helpers, repo, porcelain=True)
    assert rc == 0
    data = json.loads(out)
    entry = next(e for e in data["python"] if e["pkg"] == "mlx-openai-server")
    assert entry["installed"] == "1.8.0"
    assert entry["latest"] == "1.8.1"


@requires_venv
def test_porcelain_all_up_to_date(helpers, tmp_path):
    repo = _make_repo(tmp_path, req_txt="mlx-openai-server==1.8.0\n", req_helpers="", brewfile="")
    brew_json = json.dumps({"formulae": [], "casks": []})
    with patch("urllib.request.urlopen", side_effect=_pypi_mock({"mlx-openai-server": "1.8.0"})), \
         patch("subprocess.run", return_value=MagicMock(returncode=0, stdout=brew_json, stderr="")):
        rc, out = _run_outdated(helpers, repo, porcelain=True)
    assert rc == 0
    data = json.loads(out)
    assert data["python"] == []
    assert data["helpers"] == []
    assert data["brew"] == []


@requires_venv
def test_human_mode_no_arrows_when_current(helpers, tmp_path):
    repo = _make_repo(tmp_path, req_txt="mlx-openai-server==1.8.0\n", req_helpers="", brewfile="")
    brew_json = json.dumps({"formulae": [], "casks": []})
    with patch("urllib.request.urlopen", side_effect=_pypi_mock({"mlx-openai-server": "1.8.0"})), \
         patch("subprocess.run", return_value=MagicMock(returncode=0, stdout=brew_json, stderr="")):
        rc, out = _run_outdated(helpers, repo, porcelain=False)
    assert rc == 0
    assert "→" not in out


@requires_venv
def test_pypi_error_exits_one(helpers, tmp_path):
    repo = _make_repo(tmp_path, req_txt="mlx-openai-server==1.8.0\n", req_helpers="", brewfile="")
    with patch("urllib.request.urlopen", side_effect=urllib.error.URLError("network")):
        # Capture stderr too — cmd writes to sys.stderr
        old_err, sys.stderr = sys.stderr, io.StringIO()
        try:
            rc, _ = _run_outdated(helpers, repo, porcelain=True)
            err = sys.stderr.getvalue()
        finally:
            sys.stderr = old_err
    assert rc == 1
    assert "could not reach PyPI" in err
    assert "URLError" in err  # verifies exception class name is wrapped


@requires_venv
def test_brew_failure_exits_one(helpers, tmp_path):
    repo = _make_repo(tmp_path, req_txt="", req_helpers="", brewfile='brew "shellcheck"\n')
    brew_json = json.dumps({"formulae": [], "casks": []})
    with patch("urllib.request.urlopen", side_effect=_pypi_mock({})), \
         patch("subprocess.run", return_value=MagicMock(returncode=1, stdout="", stderr="brew error")):
        old_err, sys.stderr = sys.stderr, io.StringIO()
        try:
            rc, _ = _run_outdated(helpers, repo, porcelain=True)
            err = sys.stderr.getvalue()
        finally:
            sys.stderr = old_err
    assert rc == 1
    assert err.startswith("error: brew outdated failed:")


@requires_venv
def test_porcelain_extras_syntax_no_error(helpers, tmp_path):
    repo = _make_repo(tmp_path, req_txt="huggingface_hub[cli]==0.24.0\n", req_helpers="", brewfile="")
    brew_json = json.dumps({"formulae": [], "casks": []})
    with patch("urllib.request.urlopen", side_effect=_pypi_mock({"huggingface_hub": "0.24.0"})), \
         patch("subprocess.run", return_value=MagicMock(returncode=0, stdout=brew_json, stderr="")):
        rc, out = _run_outdated(helpers, repo, porcelain=True)
    assert rc == 0
    data = json.loads(out)
    assert data["python"] == []


@requires_venv
def test_helpers_floor_pin_in_porcelain(helpers, tmp_path):
    repo = _make_repo(tmp_path, req_txt="", req_helpers="rich>=13.9,<14\n", brewfile="")
    brew_json = json.dumps({"formulae": [], "casks": []})
    with patch("urllib.request.urlopen", side_effect=_pypi_mock({"rich": "13.10.0"})), \
         patch("subprocess.run", return_value=MagicMock(returncode=0, stdout=brew_json, stderr="")):
        rc, out = _run_outdated(helpers, repo, porcelain=True)
    assert rc == 0
    data = json.loads(out)
    entry = next((e for e in data.get("helpers", []) if e["pkg"] == "rich"), None)
    assert entry is not None
    assert entry["installed"] == "13.9"
    assert entry["latest"] == "13.10.0"
