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
    """Create a fake HF cache entry for repo (e.g. 'mlx-community/Foo-4bit')."""
    slug = "models--" + repo.replace("/", "--")
    refs = base / "hub" / slug / "refs"
    refs.mkdir(parents=True, exist_ok=True)
    (refs / "main").write_text("abc123")
    blobs = base / "hub" / slug / "blobs"
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
    # refs/main exists but blobs < 1 GB
    _make_hf_cache(tmp_path, "mlx-community/Foo-4bit", blobs_gb=0.1)
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
    # Headers must be present even with zero data rows
    for col in ("Model", "Backend", "Profiles", "Cached"):
        assert col in result.stdout


def test_bad_yaml(tmp_path):
    profiles = tmp_path / "profiles"
    profiles.mkdir()
    (profiles / "bad.yaml").write_text(": invalid: yaml: [\n")
    result = run_models_list(profiles, tmp_path)
    assert result.returncode != 0
    assert result.stderr
    assert "bad.yaml" in result.stderr
