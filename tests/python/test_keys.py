"""`4lm key` manages omlx sub keys over the loopback admin API."""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

HELPERS_PATH = Path(__file__).parents[2] / "bin"
sys.path.insert(0, str(HELPERS_PATH))

from importlib import import_module
helpers = import_module("4lm_helpers")

KEY = "0123456789abcdef" * 4


class FakeAdmin(BaseHTTPRequestHandler):
    calls: list = []
    sub_keys: list = []

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

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}")

    def _authed(self):
        return "session=ok" in (self.headers.get("Cookie") or "")

    def do_GET(self):
        FakeAdmin.calls.append(("GET", self.path))
        if not self._authed():
            return self._json(401, {})
        if self.path == "/admin/api/global-settings":
            return self._json(200, {"auth": {"api_key": KEY, "sub_keys": FakeAdmin.sub_keys}})
        return self._json(404, {})

    def do_POST(self):
        body = self._body()
        FakeAdmin.calls.append(("POST", self.path, body))
        if self.path == "/admin/api/login":
            if body.get("api_key") != KEY:
                return self._json(401, {})
            return self._json(200, {"success": True}, {"Set-Cookie": "session=ok; Path=/"})
        if not self._authed():
            return self._json(401, {})
        if self.path == "/admin/api/sub-keys":
            entry = {"key": body["key"], "name": body.get("name", ""), "created_at": "2026-10-02T10:00:00"}
            FakeAdmin.sub_keys.append(entry)
            return self._json(200, {"success": True, "sub_key": entry})
        return self._json(404, {})

    def do_DELETE(self):
        body = self._body()
        FakeAdmin.calls.append(("DELETE", self.path, body))
        if not self._authed():
            return self._json(401, {})
        for i, sk in enumerate(FakeAdmin.sub_keys):
            if sk["key"] == body.get("key"):
                FakeAdmin.sub_keys.pop(i)
                return self._json(200, {"success": True})
        return self._json(404, {"detail": "Sub key not found"})


@pytest.fixture
def admin(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    cfg = tmp_path / ".4lm" / "config"
    cfg.mkdir(parents=True)
    (cfg / "api-key").write_text(KEY + "\n")
    FakeAdmin.calls = []
    FakeAdmin.sub_keys = [{"key": "a" * 64, "name": "existing", "created_at": "2026-09-30T08:00:00"}]
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeAdmin)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()


def _key(base_url, *argv):
    args = helpers.build_parser().parse_args(["key", base_url, *argv])
    return helpers.cmd_key(args)


def test_create_prints_only_the_new_key_on_stdout(admin, capsys):
    rc = _key(admin, "create", "pdt-utilities")
    out, err = capsys.readouterr()
    assert rc == 0
    new = out.strip()
    assert len(new) == 64 and all(c in "0123456789abcdef" for c in new)
    assert out == new  # nothing but the key, and no newline to paste along
    assert "pdt-utilities" in err
    posted = [c[2] for c in FakeAdmin.calls if c[:2] == ("POST", "/admin/api/sub-keys")]
    assert posted == [{"key": new, "name": "pdt-utilities"}]


def test_create_logs_in_with_the_main_key(admin, capsys):
    _key(admin, "create", "x")
    logins = [c[2] for c in FakeAdmin.calls if c[:2] == ("POST", "/admin/api/login")]
    assert logins == [{"api_key": KEY}]


def test_create_refuses_a_duplicate_name(admin, capsys):
    rc = _key(admin, "create", "existing")
    out, err = capsys.readouterr()
    assert rc != 0
    assert out == ""
    assert "existing" in err
    assert not [c for c in FakeAdmin.calls if c[:2] == ("POST", "/admin/api/sub-keys")]


@pytest.mark.parametrize("name", ["", "a b", "x;rm", "ä", "n" * 65])
def test_create_rejects_bad_names(admin, capsys, name):
    rc = _key(admin, "create", name)
    assert rc != 0
    assert not FakeAdmin.calls


def test_list_shows_names_but_never_full_keys(admin, capsys):
    rc = _key(admin, "list")
    out, _ = capsys.readouterr()
    assert rc == 0
    assert "existing" in out
    assert "a" * 64 not in out
    assert KEY not in out


def test_revoke_deletes_by_name(admin, capsys):
    rc = _key(admin, "revoke", "existing")
    assert rc == 0
    deletes = [c[2] for c in FakeAdmin.calls if c[:2] == ("DELETE", "/admin/api/sub-keys")]
    assert deletes == [{"key": "a" * 64}]
    assert FakeAdmin.sub_keys == []


def test_revoke_unknown_name_fails_without_deleting(admin, capsys):
    rc = _key(admin, "revoke", "nope")
    _, err = capsys.readouterr()
    assert rc != 0
    assert "nope" in err
    assert not [c for c in FakeAdmin.calls if c[0] == "DELETE"]


def test_key_fails_fast_without_main_key(admin, tmp_path, capsys):
    (tmp_path / ".4lm" / "config" / "api-key").unlink()
    rc = _key(admin, "list")
    assert rc != 0
    assert not FakeAdmin.calls
