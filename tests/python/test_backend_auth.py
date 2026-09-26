"""Helper calls to /v1/* carry the API key."""
import json
import sys
from io import BytesIO
from pathlib import Path
from unittest.mock import MagicMock, patch

HELPERS_PATH = Path(__file__).parents[2] / "bin"
sys.path.insert(0, str(HELPERS_PATH))

from importlib import import_module
helpers = import_module("4lm_helpers")

KEY = "0123456789abcdef" * 4


def _seed_key(home: Path) -> None:
    cfg = home / ".4lm" / "config"
    cfg.mkdir(parents=True)
    (cfg / "api-key").write_text(KEY + "\n")


def _response(payload: dict) -> MagicMock:
    resp = MagicMock()
    resp.read.return_value = json.dumps(payload).encode()
    resp.__enter__.return_value = resp
    return resp


def test_backend_headers_with_key(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    _seed_key(tmp_path)
    assert helpers._backend_headers() == {"Authorization": f"Bearer {KEY}"}


def test_backend_headers_without_key(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    assert helpers._backend_headers() == {}


def test_smoke_sends_key_on_every_request(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    _seed_key(tmp_path)
    seen = []

    def fake_urlopen(req, timeout=None):
        seen.append(req)
        if req.full_url.endswith("/v1/models"):
            return _response({"data": [{"id": "coder"}]})
        return _response({"choices": [{"message": {"content": "hi"}}]})

    with patch("urllib.request.urlopen", side_effect=fake_urlopen):
        args = MagicMock(base_url="http://127.0.0.1:8000")
        assert helpers.cmd_smoke(args) == 0

    assert len(seen) == 2
    for req in seen:
        assert req.get_header("Authorization") == f"Bearer {KEY}"


def test_diag_probe_sends_key(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    _seed_key(tmp_path)
    seen = []

    def fake_urlopen(req, timeout=None):
        seen.append(req)
        raise OSError("stop after the probe")

    with patch("urllib.request.urlopen", side_effect=fake_urlopen):
        try:
            helpers.cmd_diag(MagicMock(backend_port="8000", log_dir=str(tmp_path)))
        except Exception:
            pass

    assert seen, "diag made no HTTP request"
    assert seen[0].get_header("Authorization") == f"Bearer {KEY}"
