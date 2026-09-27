"""`4lm bench` drives omlx's admin bench API."""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

HELPERS_PATH = Path(__file__).parents[2] / "bin"
sys.path.insert(0, str(HELPERS_PATH))

from importlib import import_module
helpers = import_module("4lm_helpers")

KEY = "0123456789abcdef" * 4
MODELS = ["coder", "qwen3-embedding", "qwen3-reranker"]


class FakeOmlx(BaseHTTPRequestHandler):
    calls: list = []
    swallow_token = False

    def log_message(self, *a):
        pass

    def _json(self, code, payload, headers=None):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        return "session=ok" in (self.headers.get("Cookie") or "")

    def do_GET(self):
        FakeOmlx.calls.append(("GET", self.path))
        if self.path == "/v1/models":
            if self.headers.get("Authorization") != f"Bearer {KEY}":
                return self._json(401, {})
            return self._json(200, {"data": [{"id": m} for m in MODELS]})
        if not self._authed():
            return self._json(401, {"detail": "Admin authentication required"})
        if self.path.startswith("/admin/api/bench/context/"):
            return self._json(200, {"status": "completed", "result": {"measured_tokens": 98304}})
        if self.path.startswith("/admin/api/bench/"):
            return self._json(200, {"status": "completed", "results": [{
                "ttft_ms": 41000.0, "gen_tps": 52.3, "processing_tps": 1600.0,
                "peak_memory_bytes": 150 * 1024**3, "prompt_tokens": 65536,
            }]})
        return self._json(404, {})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        FakeOmlx.calls.append(("POST", self.path, body))
        if self.path == "/admin/api/login":
            if body.get("api_key") != KEY:
                return self._json(401, {})
            return self._json(200, {"success": True}, {"Set-Cookie": "session=ok; Path=/"})
        if not self._authed() and self.path.startswith("/admin/"):
            return self._json(401, {})
        if self.path == "/admin/api/bench/start":
            return self._json(200, {"bench_id": "b1"})
        if self.path == "/admin/api/bench/context/start":
            return self._json(200, {"bench_id": "c1"})
        if self.path == "/v1/chat/completions":
            if self.headers.get("Authorization") != f"Bearer {KEY}":
                return self._json(401, {})
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            # omlx sends a keepalive and a bare role chunk before prefill ends.
            self.wfile.write(b'data: {"model":"keepalive","choices":[{"delta":{"role":"assistant","content":""}}]}\n\n')
            self.wfile.write(b'data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n')
            self.wfile.flush()
            time.sleep(0.2)
            if FakeOmlx.swallow_token:
                # Some models emit their only token as a special token with no text.
                self.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\ndata: [DONE]\n\n')
            else:
                self.wfile.write(b'data: {"choices":[{"delta":{"reasoning_content":"x"}}]}\n\ndata: [DONE]\n\n')
            return
        return self._json(404, {})


@pytest.fixture
def omlx(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    cfg = tmp_path / ".4lm" / "config"
    cfg.mkdir(parents=True)
    (cfg / "api-key").write_text(KEY + "\n")
    FakeOmlx.calls = []
    FakeOmlx.swallow_token = False
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeOmlx)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()


def _args(base_url, **kw):
    a = MagicMock(base_url=base_url, models=[], context=False, json=True,
                  prompt_length=65536, poll_seconds=0.01)
    for k, v in kw.items():
        setattr(a, k, v)
    return a


def _run(args, capsys):
    with patch.object(helpers, "_memory_pressure", return_value={"free_percent": 40}):
        rc = helpers.cmd_bench(args)
    return rc, capsys.readouterr().out


def test_bench_logs_in_with_the_main_key(omlx, capsys):
    rc, _ = _run(_args(omlx), capsys)
    assert rc == 0
    logins = [c for c in FakeOmlx.calls if c[:2] == ("POST", "/admin/api/login")]
    assert logins and logins[0][2]["api_key"] == KEY


def test_bench_skips_embedding_and_reranker(omlx, capsys):
    rc, out = _run(_args(omlx), capsys)
    assert rc == 0
    starts = [c[2] for c in FakeOmlx.calls if c[:2] == ("POST", "/admin/api/bench/start")]
    assert [s["model_id"] for s in starts] == ["coder"]
    assert starts[0]["prompt_lengths"] == [65536]


def test_bench_json_maps_results(omlx, capsys):
    rc, out = _run(_args(omlx), capsys)
    assert rc == 0
    report = json.loads(out)
    row = report["models"][0]
    assert row["model"] == "coder"
    assert row["cold_ttft_ms"] == 41000.0
    assert row["decode_tps"] == 52.3
    assert row["peak_memory_gib"] == 150.0
    assert row["warm_ttft_ms"] >= 200  # first token, not the keepalive/role chunks
    assert row["max_context_window"] is None
    assert report["memory_pressure_before"] == {"free_percent": 40}


def test_context_bench_runs_only_with_flag(omlx, capsys):
    _run(_args(omlx), capsys)
    assert not [c for c in FakeOmlx.calls if c[:2] == ("POST", "/admin/api/bench/context/start")]

    FakeOmlx.calls = []
    rc, out = _run(_args(omlx, context=True), capsys)
    assert rc == 0
    assert json.loads(out)["models"][0]["max_context_window"] == 98304


def test_bench_fails_fast_without_key(omlx, tmp_path, capsys):
    (tmp_path / ".4lm" / "config" / "api-key").unlink()
    rc, _ = _run(_args(omlx), capsys)
    assert rc != 0
    assert not FakeOmlx.calls


def test_memory_pressure_parses_free_percentage():
    out = "The system has 274877906944 (16777216 pages with a page size of 16384).\n" \
          "System-wide memory free percentage: 37%\n"
    with patch("subprocess.run", return_value=MagicMock(stdout=out, returncode=0)):
        assert helpers._memory_pressure() == {"free_percent": 37}


def test_context_bench_asks_for_the_largest_target(omlx, capsys):
    _run(_args(omlx, context=True), capsys)
    starts = [c[2] for c in FakeOmlx.calls if c[:2] == ("POST", "/admin/api/bench/context/start")]
    assert starts[0]["target_tokens"] == 524288


def test_bench_reloads_the_model_last(omlx, capsys):
    _run(_args(omlx, context=True), capsys)
    posts = [c[1] for c in FakeOmlx.calls if c[0] == "POST"]
    assert posts[-1] == "/v1/chat/completions"


def test_warm_ttft_counts_a_bare_finish_chunk(omlx, capsys):
    FakeOmlx.swallow_token = True
    rc, out = _run(_args(omlx), capsys)
    assert rc == 0
    assert json.loads(out)["models"][0]["warm_ttft_ms"] >= 200
