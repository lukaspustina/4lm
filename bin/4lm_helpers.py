#!/usr/bin/env python3
"""4lm_helpers — Python helper commands for the 4lm bash script."""

__version__ = "0.1.0"

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
    """Two-condition cache check matching hf_is_cached() in bin/4lm."""
    slug = "models--" + repo.replace("/", "--")
    base = Path(hf_cache_dir) / "hub" / slug
    if not (base / "refs" / "main").is_file():
        return False
    blobs = base / "blobs"
    if not blobs.is_dir():
        return False
    total = sum(f.stat().st_size for f in blobs.iterdir() if f.is_file())
    return total >= 1_073_741_824


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
        backend = data.get("backend", "mlx")
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

    console = Console()
    table = Table(title="4lm Models", show_edge=False, pad_edge=False)
    table.add_column("Model", no_wrap=True)
    table.add_column("Backend", no_wrap=True)
    table.add_column("Profiles")
    table.add_column("Cached", justify="center")

    for mp, info in seen.items():
        be = info["backend"]
        # Annotate profile names with backend when not mlx (backward compat)
        if be == "mlx":
            profs = ", ".join(info["profiles"])
        else:
            profs = ", ".join(f"{p} ({be})" for p in info["profiles"])
        if be == "ollama":
            cached_str = "[dim]~[/]"
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

    ollama_bin = subprocess.run(["which", "ollama"], capture_output=True, text=True)
    if ollama_bin.returncode == 0:
        r = subprocess.run(["ollama", "list"], capture_output=True, text=True)
        for line in r.stdout.splitlines()[1:]:  # skip header
            name = line.split()[0] if line.split() else ""
            if name and name not in seen_paths:
                unreferenced.append((name, "ollama"))

    for repo, src in unreferenced:
        table.add_row(f"[dim]{repo}[/]", f"[dim]{src}[/]", "[dim](unreferenced)[/]", "[dim]~[/]")

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

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
