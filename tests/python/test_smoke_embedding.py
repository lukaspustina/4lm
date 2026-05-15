"""Tests for _is_embedding_model and the embedding-aware smoke routing.

Regression: doctor's smoke test was posting /v1/chat/completions to every
loaded model, producing HTTP 400 for embedding models. Routing now sends
embedding-style ids to /v1/embeddings instead, with a 400-fallback for
edge cases the heuristic misses.
"""
import json
import sys
from io import BytesIO
from pathlib import Path
from unittest.mock import MagicMock, patch
from urllib.error import HTTPError

import pytest

HELPERS_PATH = Path(__file__).parents[2] / "bin"
sys.path.insert(0, str(HELPERS_PATH))

from importlib import import_module
helpers = import_module("4lm_helpers")


# ---------- _is_embedding_model (pure heuristic) -----------------------------


@pytest.mark.parametrize("model_id, expected", [
    ("qwen3-embedding", True),
    ("Qwen3-Embedding-0.6B-4bit-DWQ", True),
    ("text-embedding-3-small", True),
    ("EMBED_MODEL", True),
    ("qwen3-coder-next", False),
    ("gemma4-31b", False),
    ("gpt-oss-120b", False),
])
def test_is_embedding_model(model_id, expected):
    assert helpers._is_embedding_model(model_id) is expected


# ---------- _smoke_one routing -----------------------------------------------


class _FakeResponse:
    def __init__(self, payload: dict):
        self._body = json.dumps(payload).encode()

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


def _fake_console():
    c = MagicMock()
    c.print = MagicMock()
    return c


def test_smoke_one_embedding_model_uses_embeddings_endpoint():
    """Embedding-style id → POST /v1/embeddings, not /v1/chat/completions."""
    captured_urls = []

    def fake_urlopen(req, timeout=None):
        captured_urls.append(req.full_url)
        return _FakeResponse({"data": [{"embedding": [0.1, 0.2, 0.3]}]})

    import urllib.request
    with patch.object(urllib.request, "urlopen", fake_urlopen):
        ok = helpers._smoke_one("http://127.0.0.1:8000", "qwen3-embedding", _fake_console())

    assert ok is True
    assert len(captured_urls) == 1
    assert captured_urls[0].endswith("/v1/embeddings")


def test_smoke_one_chat_model_uses_chat_endpoint():
    """Non-embedding id → POST /v1/chat/completions."""
    captured_urls = []

    def fake_urlopen(req, timeout=None):
        captured_urls.append(req.full_url)
        return _FakeResponse({
            "choices": [{"message": {"content": "ok"}}],
            "usage": {"completion_tokens": 1},
        })

    import urllib.request
    with patch.object(urllib.request, "urlopen", fake_urlopen):
        ok = helpers._smoke_one("http://127.0.0.1:8000", "qwen3-coder-next", _fake_console())

    assert ok is True
    assert len(captured_urls) == 1
    assert captured_urls[0].endswith("/v1/chat/completions")


def test_smoke_one_chat_400_falls_back_to_embeddings():
    """HTTP 400 on /v1/chat/completions → fall back to /v1/embeddings."""
    captured_urls = []

    def fake_urlopen(req, timeout=None):
        captured_urls.append(req.full_url)
        if req.full_url.endswith("/v1/chat/completions"):
            raise HTTPError(req.full_url, 400, "bad", {}, BytesIO(b""))
        return _FakeResponse({"data": [{"embedding": [0.0]}]})

    import urllib.request
    with patch.object(urllib.request, "urlopen", fake_urlopen):
        # Use an id that the heuristic doesn't catch — forces the fallback path.
        ok = helpers._smoke_one("http://127.0.0.1:8000", "mystery-model", _fake_console())

    assert ok is True
    assert captured_urls == [
        "http://127.0.0.1:8000/v1/chat/completions",
        "http://127.0.0.1:8000/v1/embeddings",
    ]


def test_smoke_one_chat_500_does_not_fall_back():
    """Non-400 HTTP errors should not trigger the embeddings fallback."""
    captured_urls = []

    def fake_urlopen(req, timeout=None):
        captured_urls.append(req.full_url)
        raise HTTPError(req.full_url, 500, "internal", {}, BytesIO(b""))

    import urllib.request
    with patch.object(urllib.request, "urlopen", fake_urlopen):
        ok = helpers._smoke_one("http://127.0.0.1:8000", "qwen3-coder-next", _fake_console())

    assert ok is False
    assert captured_urls == ["http://127.0.0.1:8000/v1/chat/completions"]


def test_smoke_one_embedding_empty_response_fails():
    """Embedding endpoint returning empty data → smoke test fails."""
    def fake_urlopen(req, timeout=None):
        return _FakeResponse({"data": []})

    import urllib.request
    with patch.object(urllib.request, "urlopen", fake_urlopen):
        ok = helpers._smoke_one("http://127.0.0.1:8000", "qwen3-embedding", _fake_console())

    assert ok is False
