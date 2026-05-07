import http.server
import io
import subprocess
import sys
import threading
from datetime import datetime, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent.parent
HELPERS = REPO_ROOT / "bin" / "4lm_helpers.py"
FIXTURES = Path(__file__).parent / "fixtures"


def run_diag(log_file, port):
    return subprocess.run(
        [sys.executable, str(HELPERS), "diag", str(log_file), str(port)],
        capture_output=True,
        text=True,
    )


def _make_log(tmp_path, lines):
    p = tmp_path / "backend.log"
    p.write_text("\n".join(lines) + "\n")
    return p


def _ts(minutes_ago=0):
    return (datetime.now() - timedelta(minutes=minutes_ago)).strftime(
        "%Y-%m-%d %H:%M:%S"
    )


def test_inflight_one_remaining(tmp_path):
    log = _make_log(tmp_path, [
        f"{_ts(5)} INFO BatchScheduler admitted uid=aaa1 (client)",
        f"{_ts(4)} INFO BatchScheduler admitted uid=bbb2 (client)",
        f"{_ts(3)} INFO BatchScheduler admitted uid=ccc3 (client)",
        f"{_ts(2)} INFO BatchScheduler uid=aaa1 finished (tokens=10)",
        f"{_ts(1)} INFO BatchScheduler uid=bbb2 finished (tokens=20)",
    ])
    result = run_diag(log, 19999)
    assert result.returncode == 0
    out = result.stdout
    assert "In-flight" in out
    assert "ccc3" in out


def test_orphaned_worker():
    result = run_diag(FIXTURES / "backend.log", 19999)
    assert result.returncode == 0
    assert "99999" in result.stdout
    assert "Orphaned" in result.stdout


def test_all_finished_no_orphan_section(tmp_path):
    # All admits have matching finishes, no worker pid lines → no orphan section
    log = _make_log(tmp_path, [
        f"{_ts(5)} INFO BatchScheduler admitted uid=x1 (client)",
        f"{_ts(4)} INFO BatchScheduler uid=x1 finished (tokens=5)",
        f"{_ts(3)} INFO BatchScheduler admitted uid=x2 (client)",
        f"{_ts(2)} INFO BatchScheduler uid=x2 finished (tokens=8)",
    ])
    result = run_diag(log, 19999)
    assert result.returncode == 0
    assert "Orphaned" not in result.stdout


def test_missing_log():
    result = run_diag(FIXTURES / "nonexistent.log", 19999)
    assert result.returncode == 0
    assert "No log data found" in result.stdout


def test_empty_log(tmp_path):
    log = tmp_path / "empty.log"
    log.write_text("")
    result = run_diag(log, 19999)
    assert result.returncode == 0
    assert "No log data found" in result.stdout


def test_http_probe_unreachable():
    result = run_diag(FIXTURES / "backend.log", 19998)
    assert result.returncode == 0
    assert "unreachable" in result.stdout


def test_http_probe_ok():
    # Start a minimal HTTP server that returns a /v1/models response.
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = b'{"data": [{"id": "m1"}, {"id": "m2"}]}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    t = threading.Thread(target=server.handle_request, daemon=True)
    t.start()

    result = run_diag(FIXTURES / "backend.log", port)
    t.join(timeout=2)
    server.server_close()

    assert result.returncode == 0
    assert "OK" in result.stdout
    assert "2 models loaded" in result.stdout
