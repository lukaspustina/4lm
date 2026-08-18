# The verb contract of 4lm (pdt-adlc ADR 0008).
#
# Migrated from a Makefile on 2026-08-18. `help` is the only target dropped —
# `just --list` builds the listing from these comments.
#
# This repository needed the least adjusting of the six: its `check` was already
# the static, offline, refuting set. So `adlc-verify` is that set under the name
# the ADLC reads, and `check` is an alias rather than something larger — there is
# nothing slower to separate out. `ci` stays a verb of its own and is reachable
# from neither: it runs `brew bundle`, which writes outside the repository, and
# the contract rules that out of a gate.

scripts := "bin/4lm bin/4lm-backend-start.sh bin/4lm-webui-start.sh install.sh uninstall.sh tests/lint-profiles.sh"
plists  := "launchd/com.4lm.backend.plist launchd/com.4lm.webui.plist"
shfmt_opts := "-i 2 -ci"
helpers_python := env_var_or_default("HELPERS_PYTHON", env_var("HOME") + "/.4lm/venv/bin/python")
ci_venv := justfile_directory() / ".venv"

default: adlc-verify

# --- the contract ------------------------------------------------------------

# What the ADLC gate runs: every static check plus the suite. No network, no
# brew, nothing that writes outside the repository.
adlc-verify: lint syntax plist-lint yaml-lint test

# Identical to adlc-verify, and that is not an oversight: everything this
# repository can check without installing something is already in it. When a
# slower check appears, it goes here and the two part company.
check: adlc-verify

# The bats suite, plus pytest when the helpers venv exists.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    bats tests/
    if [ -x "{{helpers_python}}" ]; then
        "{{helpers_python}}" -m pytest tests/python/ -q
    else
        echo "skip: pytest — venv not installed (run just install)"
    fi

# shellcheck + shfmt -d over every script.
lint:
    shellcheck {{scripts}}
    shfmt {{shfmt_opts}} -d {{scripts}}

# --- the other static gates --------------------------------------------------

# bash -n on all scripts + py_compile on the helpers.
syntax:
    #!/usr/bin/env bash
    set -euo pipefail
    for f in {{scripts}}; do bash -n "$f" && echo "OK   $f"; done
    python3 -m py_compile bin/4lm_helpers.py && echo "OK   bin/4lm_helpers.py"

plist-lint:
    plutil -lint {{plists}}
    xmllint --noout {{plists}}

# Validate every profile YAML against the bin/4lm schema.
yaml-lint:
    tests/lint-profiles.sh

# shfmt -w, rewriting the scripts in place.
fmt:
    shfmt {{shfmt_opts}} -w {{scripts}}

# --- setup: these write outside the repository -------------------------------
#
# Unreachable from adlc-verify and check, deliberately.

# Brewfile (+ Brewfile-tui unless backend_only) and pipx ensurepath.
bootstrap backend_only="":
    #!/usr/bin/env bash
    set -euo pipefail
    brew bundle --file=Brewfile
    [ -n "{{backend_only}}" ] || brew bundle --file=Brewfile-tui
    pipx ensurepath

# ./install.sh — pass any value for backend_only to forward --backend-only.
install backend_only="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{backend_only}}" ]; then ./install.sh --backend-only; else ./install.sh; fi

# DESTRUCTIVE — removes ~/.4lm and the chat history.
uninstall:
    ./uninstall.sh

# --- CI legs, run locally ----------------------------------------------------

# Both matrix legs, mirroring .github/workflows/ci.yml.
ci: ci-default ci-backend-only

ci-default: ci-venv
    brew bundle --file=Brewfile
    brew bundle --file=Brewfile-tui
    HELPERS_PYTHON={{ci_venv}}/bin/python just check

ci-backend-only: ci-venv
    brew bundle --file=Brewfile
    HELPERS_PYTHON={{ci_venv}}/bin/python just check

# Build the helpers venv at .venv, matching CI's cache key.
[private]
ci-venv:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -x {{ci_venv}}/bin/python ] || python3.12 -m venv {{ci_venv}}
    {{ci_venv}}/bin/pip install --quiet -r requirements-helpers.txt

# --- models ------------------------------------------------------------------
#
# Network verbs. Never reachable from a gate.

# Download or update every model named in config/profiles/ (backend-aware).
models:
    #!/usr/bin/env bash
    set -euo pipefail
    for yaml in config/profiles/*.yaml; do
      backend=$(awk '/^backend:/{print $2}' "$yaml")
      backend=${backend:-mlx}
      while IFS= read -r model; do
        [ -z "$model" ] && continue
        if [ "$backend" = "ollama" ]; then
          echo "-> ollama pull $model"; ollama pull "$model"
        else
          echo "-> hf download $model"; hf download "$model"
        fi
      done < <(awk '/^[[:space:]]*-[[:space:]]*model_path:/{print $NF}' "$yaml")
    done

# List cached HuggingFace repos (size + revisions).
models-list: _require-hf
    hf cache ls

# Prune orphaned revisions from the HF cache.
models-clean: _require-hf
    hf cache prune

# Remove a cached model: just models-rm mlx-community/GLM-4.7-Flash-8bit
models-rm model: _require-hf
    hf cache rm "{{model}}"

[private]
_require-hf:
    @command -v hf >/dev/null || { echo "hf not found — run: just install" >&2; exit 1; }
