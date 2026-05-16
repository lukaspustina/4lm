import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent.parent
HELPERS = REPO_ROOT / "bin" / "4lm_helpers.py"
FIXTURES = Path(__file__).parent / "fixtures"


def run_models_list(profiles_dir, hf_cache_dir):
    result = subprocess.run(
        [sys.executable, str(HELPERS), "models-list", str(profiles_dir), str(hf_cache_dir)],
        capture_output=True,
        text=True,
    )
    return result


def _make_hf_cache(base: Path, repo: str, blobs_gb: float = 0) -> None:
    """Create a fake HF cache entry for repo (e.g. 'mlx-community/Foo-4bit').

    Mirrors the layout _hf_is_cached() expects: refs/main with a SHA,
    snapshots/<sha>/ with at least one entry, and blobs/ free of *.incomplete.
    """
    slug = "models--" + repo.replace("/", "--")
    sha = "abc123"
    root = base / "hub" / slug
    (root / "refs").mkdir(parents=True, exist_ok=True)
    (root / "refs" / "main").write_text(sha)
    (root / "snapshots" / sha).mkdir(parents=True, exist_ok=True)
    (root / "snapshots" / sha / "config.json").write_text("{}")
    blobs = root / "blobs"
    blobs.mkdir(parents=True, exist_ok=True)
    if blobs_gb > 0:
        # Write a sparse file of the right apparent size
        blob = blobs / "fake"
        blob.write_bytes(b"\x00" * int(blobs_gb * 1024 * 1024 * 1024))


def test_deduplication(tmp_path):
    result = run_models_list(FIXTURES, tmp_path)
    assert result.returncode == 0
    # mlx-community/Shared-8bit appears in both profiles — must appear only once
    lines = [l for l in result.stdout.splitlines() if "Shared-8bit" in l]
    assert len(lines) == 1


def test_cached_full(tmp_path):
    _make_hf_cache(tmp_path, "mlx-community/Foo-4bit", blobs_gb=1.1)
    result = run_models_list(FIXTURES, tmp_path)
    assert result.returncode == 0
    assert "✓" in result.stdout


def test_partial_download_not_cached(tmp_path):
    # An in-flight HF download leaves a *.incomplete blob — _hf_is_cached
    # must treat the model as not cached even if refs/main and snapshots/<sha>/
    # already exist.
    _make_hf_cache(tmp_path, "mlx-community/Foo-4bit", blobs_gb=0.1)
    slug = "models--mlx-community--Foo-4bit"
    (tmp_path / "hub" / slug / "blobs" / "pending.incomplete").write_bytes(b"")
    result = run_models_list(FIXTURES, tmp_path)
    assert result.returncode == 0
    lines = [l for l in result.stdout.splitlines() if "Foo-4bit" in l]
    assert lines
    assert "—" in lines[0]


def test_not_in_cache(tmp_path):
    result = run_models_list(FIXTURES, tmp_path)
    assert result.returncode == 0
    lines = [l for l in result.stdout.splitlines() if "Foo-4bit" in l]
    assert lines
    assert "—" in lines[0]


def test_empty_profiles_dir(tmp_path):
    profiles = tmp_path / "profiles"
    profiles.mkdir()
    cache = tmp_path / "cache"
    cache.mkdir()
    result = run_models_list(profiles, cache)
    assert result.returncode == 0
    # With no profiles and an empty cache, the helper prints a friendly empty
    # state instead of a header-only table.
    assert "No cached models found." in result.stdout


def test_bad_yaml(tmp_path):
    profiles = tmp_path / "profiles"
    profiles.mkdir()
    (profiles / "bad.yaml").write_text(": invalid: yaml: [\n")
    result = run_models_list(profiles, tmp_path)
    assert result.returncode != 0
    assert result.stderr
    assert "bad.yaml" in result.stderr
