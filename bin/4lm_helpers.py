#!/usr/bin/env python3
"""4lm_helpers — Python helper commands for the 4lm bash script."""

__version__ = "0.4.0"

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def normalize(name: str) -> str:
    """Strip org prefix, lowercase, iteratively remove quantization suffixes."""
    if "/" in name:
        name = name.split("/")[-1]
    name = name.lower()
    suffixes = [
        "-instruct", "-it", "-mlx", "-4bit", "-8bit", "-q4", "-q8",
        "-fp8", "-bf16", "-gguf", "-mxfp4", "-nvfp4", "-awq", "-gptq",
    ]
    changed = True
    while changed:
        changed = False
        for s in suffixes:
            if name.endswith(s):
                name = name[: -len(s)]
                changed = True
    return name


def _build_lm_index(lm: dict[str, Any]) -> dict[str, list[dict]]:
    """Index community benchmarks by normalized model name, sorted by tok/s desc."""
    index: dict[str, list[dict]] = {}
    for b in lm.get("benchmarks", []):
        if b.get("tokSOut") is None:
            continue
        h = b["hardware"]
        key = normalize(b["model"].get("hfId", ""))
        hw = h.get("chipVariant") or h.get("gpuName") or h.get("chipFamily") or "?"
        index.setdefault(key, []).append({"tps": b["tokSOut"], "hw": hw})
    for key in index:
        index[key].sort(key=lambda x: -x["tps"])
    return index


def _community_str(lm_index: dict, name: str, col_width: int = 22) -> str:
    best = lm_index.get(normalize(name), [None])[0]
    if best:
        return f"{best['tps']:.1f} ({best['hw'][:14]})"
    return "—"


def cmd_recommend(args: argparse.Namespace) -> int:
    from rich.console import Console
    from rich.table import Table
    from rich import box

    try:
        with open(args.rec_file) as f:
            rec = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"error: cannot read {args.rec_file}: {e}", file=sys.stderr)
        return 1

    try:
        with open(args.lm_file) as f:
            lm = json.load(f)
    except (OSError, json.JSONDecodeError):
        lm = {}

    all_models = rec.get("models", [])
    system = rec.get("system", {})
    lm_index = _build_lm_index(lm)

    active_norms = {
        normalize(p) for p in args.active_paths.split(",") if p.strip()
    }

    # Map normalized name → (rank, model_dict) — first (best-ranked) match wins
    active_rank: dict[str, tuple[int, dict]] = {}
    for i, m in enumerate(all_models, 1):
        norm = normalize(m["name"])
        if norm in active_norms and norm not in active_rank:
            active_rank[norm] = (i, m)

    limit = int(args.limit)
    top_models = all_models[:limit]
    top_norms = {normalize(m["name"]) for m in top_models}

    # Build main table
    console = Console()
    chip = system.get("cpu_name", "Apple Silicon")
    mem = system.get("total_ram_gb", 0)

    table = Table(
        box=box.SIMPLE_HEAD,
        title=f"4lm Recommendations ({chip} · {mem:.0f} GB)",
        show_edge=False,
        pad_edge=False,
    )
    table.add_column("#", justify="right", style="dim", no_wrap=True)
    table.add_column("Model", no_wrap=True)
    table.add_column("Cat", no_wrap=True)
    table.add_column("Score", justify="right")
    table.add_column("Params", justify="right")
    table.add_column("Mem", justify="right")
    table.add_column("tps*", justify="right")
    table.add_column("Community", no_wrap=True)
    table.add_column("Fit")

    FIT_STYLE = {"Perfect": "green", "Good": "yellow"}

    def add_row(rank: int, m: dict, marker: str = " ") -> None:
        short = m["name"].split("/")[-1]
        if len(short) > 34:
            short = short[:32] + "…"
        fit = m.get("fit_level", "?")
        fit_styled = f"[{FIT_STYLE[fit]}]{fit}[/]" if fit in FIT_STYLE else fit
        comm = _community_str(lm_index, m["name"])
        table.add_row(
            f"{rank}{marker}",
            short,
            (m.get("category") or "?")[:10],
            f"{m.get('score', 0):.1f}",
            str(m.get("parameter_count", "?")),
            f"{m.get('memory_required_gb', 0):.1f}G",
            f"{m.get('estimated_tps', 0):.1f}",
            comm,
            fit_styled,
        )

    any_marked = False
    for i, m in enumerate(top_models, 1):
        norm = normalize(m["name"])
        is_active = norm in active_rank
        if is_active:
            any_marked = True
        marker = "[green]*[/]" if is_active else " "
        add_row(i, m, marker)

    # Active profile models that didn't make the top-N
    extras = [
        (rank, m)
        for norm, (rank, m) in sorted(active_rank.items(), key=lambda x: x[1][0])
        if norm not in top_norms
    ]

    console.print(table)

    if extras:
        any_marked = True
        console.print("  [dim]── active profile ──[/]")
        extra_table = Table(
            box=None, show_header=False, show_edge=False, pad_edge=False
        )
        for _ in range(9):
            extra_table.add_column()
        for rank, m in extras:
            extra_table.add_row(
                f"{rank}[green]*[/]",
                m["name"].split("/")[-1][:34],
                (m.get("category") or "?")[:10],
                f"{m.get('score', 0):.1f}",
                str(m.get("parameter_count", "?")),
                f"{m.get('memory_required_gb', 0):.1f}G",
                f"{m.get('estimated_tps', 0):.1f}",
                _community_str(lm_index, m["name"]),
                m.get("fit_level", "?"),
            )
        console.print(extra_table)

    lm_count = sum(len(v) for v in lm_index.values())
    console.print(f"\n  [dim]* estimated MLX tok/s (llmfit)[/]")
    console.print(
        f"  [dim]  Community: best UNIFIED tok/s from localmaxxing.com "
        f"({lm_count} benchmarks fetched; — = no data yet)[/]"
    )
    if any_marked:
        console.print("  [dim]* = in active profile[/]")
    console.print()
    return 0


def _hf_is_cached(hf_cache_dir: str, repo: str) -> bool:
    """Cache-complete check matching hf_is_cached() in bin/4lm.

    Requirements:
      1. refs/main exists with a SHA.
      2. snapshots/<sha>/ exists and is non-empty.
      3. blobs/ has no *.incomplete files.
    Size-agnostic: small models (e.g. embeddings <1GB) pass.
    """
    slug = "models--" + repo.replace("/", "--")
    base = Path(hf_cache_dir) / "hub" / slug
    ref_file = base / "refs" / "main"
    if not ref_file.is_file():
        return False
    sha = ref_file.read_text().strip()
    if not sha:
        return False
    snap_dir = base / "snapshots" / sha
    if not snap_dir.is_dir():
        return False
    if not any(snap_dir.iterdir()):
        return False
    blobs = base / "blobs"
    if not blobs.is_dir():
        return False
    return not any(f.name.endswith(".incomplete") for f in blobs.iterdir())


def cmd_models_list(args: argparse.Namespace) -> int:
    import subprocess

    import yaml
    from rich.console import Console
    from rich.table import Table

    profiles_dir = Path(args.profiles_dir)
    hf_cache_dir = args.hf_cache_dir

    # Parse all profile YAMLs
    entries: list[dict] = []  # {model_path, backend, profile}
    for yaml_path in sorted(profiles_dir.glob("*.yaml")):
        try:
            with open(yaml_path) as f:
                data = yaml.safe_load(f)
        except yaml.YAMLError as e:
            print(f"error: failed to parse {yaml_path.name}: {e}", file=sys.stderr)
            return 1
        if not isinstance(data, dict):
            continue
        backend = data.get("backend", "omlx")
        profile = yaml_path.stem
        for model in data.get("models", []):
            mp = model.get("model_path", "")
            if mp:
                entries.append({"model_path": mp, "backend": backend, "profile": profile})

    # Deduplicate by model_path, collecting all profiles per model
    seen: dict[str, dict] = {}  # model_path -> {backend, profiles: list}
    for e in entries:
        mp = e["model_path"]
        if mp not in seen:
            seen[mp] = {"backend": e["backend"], "profiles": []}
        seen[mp]["profiles"].append(e["profile"])

    # Build set of locally-present ollama models once
    ollama_cached: set[str] = set()
    _ob = subprocess.run(["which", "ollama"], capture_output=True, text=True)
    if _ob.returncode == 0:
        _ol = subprocess.run(["ollama", "list"], capture_output=True, text=True)
        for _line in _ol.stdout.splitlines()[1:]:
            _parts = _line.split()
            if _parts:
                ollama_cached.add(_parts[0])

    console = Console()
    table = Table(title="4lm Models", show_edge=False, pad_edge=False)
    table.add_column("Model", no_wrap=True)
    table.add_column("Backend", no_wrap=True)
    table.add_column("Profiles")
    table.add_column("Cached", justify="center")

    for mp, info in seen.items():
        be = info["backend"]
        if be == "omlx":
            profs = ", ".join(info["profiles"])
        else:
            profs = ", ".join(f"{p} ({be})" for p in info["profiles"])
        if be == "ollama":
            cached_str = "[green]✓[/]" if mp in ollama_cached else "[yellow]—[/]"
        elif _hf_is_cached(hf_cache_dir, mp):
            cached_str = "[green]✓[/]"
        else:
            cached_str = "[yellow]—[/]"
        table.add_row(mp, be, profs, cached_str)

    # Unreferenced HF models
    seen_paths = set(seen.keys())
    unreferenced: list[tuple[str, str]] = []

    hf_bin = subprocess.run(["which", "hf"], capture_output=True, text=True)
    if hf_bin.returncode == 0:
        r = subprocess.run(
            ["hf", "cache", "list", "--format", "agent"],
            capture_output=True, text=True,
        )
        for line in r.stdout.splitlines():
            parts = line.split("\t")
            if not parts or not parts[0].startswith("model/"):
                continue
            repo = parts[0][len("model/"):]
            if repo not in seen_paths:
                unreferenced.append((repo, "hf"))

    for name in ollama_cached:
        if name not in seen_paths:
            unreferenced.append((name, "ollama"))

    for repo, src in unreferenced:
        table.add_row(f"[dim]{repo}[/]", f"[dim]{src}[/]", "[dim](unreferenced)[/]", "[dim]~[/]")

    if table.row_count == 0:
        console.print("No cached models found.")
        return 0

    console.print(table)
    return 0


def is_orphaned(worker_pid: str, log_entries: list[str], window_admissions: int) -> bool:
    return any(worker_pid in line for line in log_entries) and window_admissions == 0


def _smoke_one(base_url: str, model_id: str, console: "Console") -> bool:
    import time
    import urllib.error
    import urllib.request

    payload = json.dumps({
        "model": model_id,
        "messages": [{"role": "user", "content": "hi"}],
        "max_tokens": 128,
        "stream": False,
    }).encode()
    req = urllib.request.Request(
        f"{base_url}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read())
        ms = int((time.time() - t0) * 1000)
        msg = result.get("choices", [{}])[0].get("message", {})
        content = (msg.get("content") or "").strip()
        thinking = (msg.get("thinking") or "").strip()
        completion_tokens = result.get("usage", {}).get("completion_tokens", 0)
        if content or thinking or completion_tokens > 0:
            console.print(f"  [green]✓[/] smoke test: {model_id} responded in {ms}ms")
            return True
        console.print(f"  [yellow]warn:[/] smoke test: empty response from {model_id}")
        return False
    except urllib.error.HTTPError as e:
        console.print(f"  [yellow]warn:[/] smoke test: HTTP {e.code} from {model_id}")
        return False
    except (urllib.error.URLError, OSError) as e:
        ms = int((time.time() - t0) * 1000)
        console.print(f"  [yellow]warn:[/] smoke test: {model_id} failed after {ms}ms ({type(e).__name__})")
        return False


def cmd_smoke(args: argparse.Namespace) -> int:
    import urllib.error
    import urllib.request

    from rich.console import Console

    console = Console()
    base_url = args.base_url

    try:
        with urllib.request.urlopen(f"{base_url}/v1/models", timeout=5) as resp:
            data = json.loads(resp.read())
        models = data.get("data", [])
        if not models:
            console.print("  [yellow]warn:[/] smoke test: no models loaded")
            return 1
    except (urllib.error.URLError, OSError) as e:
        console.print(f"  [yellow]warn:[/] smoke test: cannot reach backend ({type(e).__name__})")
        return 1

    failed = 0
    for model in models:
        if not _smoke_one(base_url, model["id"], console):
            failed += 1
    return 1 if failed else 0


def cmd_diag(args: argparse.Namespace) -> int:
    import re
    import time
    import urllib.error
    import urllib.request
    from datetime import datetime, timedelta

    from rich.console import Console

    console = Console()

    # ── HTTP probe ──────────────────────────────────────────────────────────
    url = f"http://127.0.0.1:{args.backend_port}/v1/models"
    t0 = time.time()
    try:
        with urllib.request.urlopen(url, timeout=3) as resp:
            data = json.loads(resp.read())
        ms = int((time.time() - t0) * 1000)
        model_count = len(data.get("data", []))
        console.print(f"[bold]Backend[/]")
        console.print(f"  {url} — [green]OK[/] ({ms}ms, {model_count} models loaded)")
    except (urllib.error.URLError, OSError) as e:
        console.print(f"[bold]Backend[/]")
        console.print(f"  {url} — [yellow]unreachable[/]: could not reach backend ({type(e).__name__})")

    # ── Log analysis ────────────────────────────────────────────────────────
    log_path = Path(args.log_file)
    if not log_path.exists() or log_path.stat().st_size == 0:
        console.print(f"\nNo log data found at {log_path}")
        return 0

    admit_pat = re.compile(r"BatchScheduler admitted uid=(\w+)")
    finish_pat = re.compile(r"BatchScheduler.*uid=(\w+).*finished")
    worker_pat = re.compile(r"worker pid=(\d+)")

    cutoff = datetime.now() - timedelta(minutes=10)
    # admits: uid -> timestamp (for recent admits only)
    recent_admits: dict[str, datetime] = {}
    finished_uids: set[str] = set()
    worker_pids: set[str] = set()
    all_admit_uids: set[str] = set()
    log_lines: list[str] = []

    with open(log_path) as f:
        for line in f:
            line = line.rstrip()
            log_lines.append(line)
            # extract timestamp prefix
            ts_str = line[:19] if len(line) >= 19 else ""
            try:
                ts = datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S")
            except ValueError:
                ts = datetime.min

            m = admit_pat.search(line)
            if m:
                uid = m.group(1)
                all_admit_uids.add(uid)
                if ts >= cutoff:
                    recent_admits[uid] = ts

            m = finish_pat.search(line)
            if m:
                finished_uids.add(m.group(1))

            m = worker_pat.search(line)
            if m:
                worker_pids.add(m.group(1))

    # In-flight: recent admits without matching finish
    inflight = {uid: ts for uid, ts in recent_admits.items() if uid not in finished_uids}

    console.print(f"\n[bold]In-flight inference (admitted, not yet finished, last 10 min)[/]")
    if inflight:
        for uid, ts in sorted(inflight.items(), key=lambda x: x[1]):
            console.print(f"  {ts.strftime('%Y-%m-%d %H:%M:%S')}  uid={uid}")
    else:
        console.print("  (none)")

    console.print(f"\n[bold]Backend worker processes[/]")
    if worker_pids:
        for pid in sorted(worker_pids):
            console.print(f"  pid={pid}")
    else:
        console.print("  (none)")

    window_admissions = len(all_admit_uids)
    orphaned = {pid for pid in worker_pids if is_orphaned(pid, log_lines, window_admissions)}

    if orphaned:
        console.print(f"\n[bold]Orphaned workers[/]")
        for pid in sorted(orphaned):
            console.print(f"  pid={pid}")

    return 0


def _parse_req_file(path: str) -> list[tuple[str, str]]:
    """Parse a requirements file; return (name, version) for ==X and >=X pins."""
    import re as _re

    result = []
    try:
        lines = Path(path).read_text().splitlines()
    except OSError:
        return result
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # Strip extras bracket: huggingface_hub[cli] → huggingface_hub
        name = _re.split(r"[=<>!~\[]", line)[0].rstrip()
        if "==" in line:
            ver = line.split("==", 1)[1].split(",")[0].split(";")[0].strip()
            result.append((name, ver))
        elif ">=" in line:
            ver = line.split(">=", 1)[1].split(",")[0].strip()
            result.append((name, ver))
        else:
            print(f"warning: skipping unrecognised pin format: {line!r}", file=sys.stderr)
    return result


def cmd_outdated(args: argparse.Namespace) -> int:
    import re as _re
    import subprocess
    import urllib.error
    import urllib.request

    repo_dir = Path(args.repo_dir)
    porcelain = getattr(args, "porcelain", False)

    python_pkgs = _parse_req_file(str(repo_dir / "requirements.txt"))
    helpers_pkgs = _parse_req_file(str(repo_dir / "requirements-helpers.txt"))

    py_outdated: list[dict] = []
    helpers_outdated: list[dict] = []

    for source_pkgs, dest in [(python_pkgs, py_outdated), (helpers_pkgs, helpers_outdated)]:
        for pkg, ver in source_pkgs:
            url = f"https://pypi.org/pypi/{pkg}/json"
            try:
                with urllib.request.urlopen(url, timeout=10) as resp:
                    data = json.loads(resp.read())
                latest = data["info"]["version"]
            except urllib.error.URLError as e:
                print(f"error: could not reach PyPI ({type(e).__name__})", file=sys.stderr)
                return 1
            if latest != ver:
                dest.append({"pkg": pkg, "installed": ver, "latest": latest})

    brew_outdated: list[dict] = []
    brewfile_formulae: set[str] = set()
    brewfile_path = repo_dir / "Brewfile"
    if brewfile_path.exists():
        for line in brewfile_path.read_text().splitlines():
            m = _re.match(r'^brew\s+"([^"]+)"', line)
            if m:
                brewfile_formulae.add(m.group(1))

    if brewfile_formulae:
        r = subprocess.run(
            ["brew", "outdated", "--json=v2"],
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            print(f"error: brew outdated failed: {r.stderr}", file=sys.stderr)
            return 1
        brew_data = json.loads(r.stdout)
        for formula in brew_data.get("formulae", []):
            name = formula.get("name", "")
            if name in brewfile_formulae:
                brew_outdated.append({
                    "formula": name,
                    "installed": (formula.get("installed_versions") or ["?"])[0],
                    "latest": formula.get("current_version", "?"),
                })

    if porcelain:
        print(json.dumps({"python": py_outdated, "helpers": helpers_outdated, "brew": brew_outdated}))
        return 0

    from rich.console import Console
    from rich.table import Table

    console = Console()
    table = Table(title="4lm Outdated", show_edge=False, pad_edge=False)
    table.add_column("Package")
    table.add_column("Kind")
    table.add_column("Installed")
    table.add_column("Latest")

    py_outdated_map = {e["pkg"]: e for e in py_outdated}
    for pkg, ver in python_pkgs:
        if pkg in py_outdated_map:
            table.add_row(pkg, "python", py_outdated_map[pkg]["installed"],
                          f"[yellow]→ {py_outdated_map[pkg]['latest']}[/]")
        else:
            table.add_row(pkg, "python", ver, "")

    helpers_outdated_map = {e["pkg"]: e for e in helpers_outdated}
    for pkg, ver in helpers_pkgs:
        if pkg in helpers_outdated_map:
            table.add_row(pkg, "helpers", helpers_outdated_map[pkg]["installed"],
                          f"[yellow]→ {helpers_outdated_map[pkg]['latest']}[/]")
        else:
            table.add_row(pkg, "helpers", ver, "")

    brew_outdated_map = {e["formula"]: e for e in brew_outdated}
    for formula in sorted(brewfile_formulae):
        if formula in brew_outdated_map:
            e = brew_outdated_map[formula]
            table.add_row(formula, "brew", e["installed"],
                          f"[yellow]→ {e['latest']}[/]")
        else:
            table.add_row(formula, "brew", "[green]✓[/]", "")

    console.print(table)
    return 0


def cmd_hello(args: argparse.Namespace) -> int:
    print("hello from 4lm_helpers")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="4lm_helpers",
        description="Python helper commands for 4lm",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("hello", help="smoke-test command")

    p_rec = sub.add_parser("recommend", help="display model recommendations")
    p_rec.add_argument("rec_file", help="llmfit JSON output file")
    p_rec.add_argument("lm_file", help="localmaxxing benchmarks JSON file")
    p_rec.add_argument("active_paths", help="comma-separated active profile model paths")
    p_rec.add_argument("limit", help="number of top models to display")

    p_ml = sub.add_parser("models-list", help="list models across profiles")
    p_ml.add_argument("profiles_dir", help="path to profiles directory")
    p_ml.add_argument("hf_cache_dir", help="HuggingFace cache root (~/.cache/huggingface)")

    p_smoke = sub.add_parser("smoke", help="send a minimal inference request to verify the backend end-to-end")
    p_smoke.add_argument("base_url", help="backend base URL (e.g. http://127.0.0.1:8080)")

    p_diag = sub.add_parser("diag", help="show backend diagnostics and log analysis")
    p_diag.add_argument("log_file", help="path to backend.log")
    p_diag.add_argument("backend_port", help="backend HTTP port")

    p_out = sub.add_parser("outdated", help="check for outdated Python and Homebrew packages")
    p_out.add_argument("repo_dir", help="path to 4lm repo root")
    p_out.add_argument("--porcelain", action="store_true", help="emit JSON instead of rich table")

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "hello":
        return cmd_hello(args)
    if args.command == "recommend":
        return cmd_recommend(args)
    if args.command == "models-list":
        return cmd_models_list(args)
    if args.command == "smoke":
        return cmd_smoke(args)
    if args.command == "diag":
        return cmd_diag(args)
    if args.command == "outdated":
        return cmd_outdated(args)

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
