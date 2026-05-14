SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := check

SCRIPTS        := bin/4lm bin/4lm-backend-start.sh bin/4lm-webui-start.sh install.sh uninstall.sh tests/lint-profiles.sh
PLISTS         := launchd/com.4lm.backend.plist launchd/com.4lm.webui.plist
SHFMT_OPTS     := -i 2 -ci
HELPERS_PYTHON ?= $(HOME)/.4lm/venv/bin/python


.PHONY: check bootstrap install uninstall lint fmt syntax test plist-lint yaml-lint models models-list models-clean models-rm help

check: lint syntax plist-lint yaml-lint test ## Run all gates (default)

bootstrap: ## Install required tools from Brewfile (+ Brewfile-tui unless BACKEND_ONLY=1) + pipx ensurepath
	brew bundle --file=Brewfile
ifeq ($(strip $(BACKEND_ONLY)),)
	brew bundle --file=Brewfile-tui
endif
	pipx ensurepath

install: ## Run ./install.sh (forwards --backend-only when BACKEND_ONLY=1)
ifeq ($(strip $(BACKEND_ONLY)),)
	./install.sh
else
	./install.sh --backend-only
endif

uninstall: ## Run ./uninstall.sh — DESTRUCTIVE, removes ~/.4lm and chat history
	./uninstall.sh

lint: ## shellcheck + shfmt -d on all scripts
	shellcheck $(SCRIPTS)
	shfmt $(SHFMT_OPTS) -d $(SCRIPTS)

fmt: ## shfmt -w (rewrites scripts in place)
	shfmt $(SHFMT_OPTS) -w $(SCRIPTS)

syntax: ## bash -n on all scripts + py_compile on helpers
	@for f in $(SCRIPTS); do bash -n $$f && echo "OK   $$f"; done
	python3 -m py_compile bin/4lm_helpers.py && echo "OK   bin/4lm_helpers.py"

test: ## Run the bats suite + pytest (if venv installed)
	bats tests/
	@if [ -x "$(HELPERS_PYTHON)" ]; then \
	  $(HELPERS_PYTHON) -m pytest tests/python/ -q; \
	else \
	  echo "skip: pytest — venv not installed (run make install)"; \
	fi

plist-lint: ## plutil -lint + xmllint --noout on all plists
	plutil -lint $(PLISTS)
	xmllint --noout $(PLISTS)

yaml-lint: ## Validate every profile YAML against the bin/4lm schema
	tests/lint-profiles.sh

models: ## Download/update all models in config/profiles/ (backend-aware, idempotent)
	@for yaml in config/profiles/*.yaml; do \
	  backend=$$(awk '/^backend:/{print $$2}' "$$yaml"); \
	  backend=$${backend:-mlx}; \
	  while IFS= read -r model; do \
	    [ -z "$$model" ] && continue; \
	    if [ "$$backend" = "ollama" ]; then \
	      echo "→ ollama pull $$model"; ollama pull "$$model"; \
	    else \
	      echo "→ hf download $$model"; hf download "$$model"; \
	    fi; \
	  done < <(awk '/^[[:space:]]*-[[:space:]]*model_path:/{print $$NF}' "$$yaml"); \
	done

models-list: ## List cached HuggingFace repos (size + revisions)
	@command -v hf >/dev/null || { echo "hf not found — run: make install" >&2; exit 1; }
	hf cache ls

models-clean: ## Prune orphaned revisions from the HF cache (safe housekeeping)
	@command -v hf >/dev/null || { echo "hf not found — run: make install" >&2; exit 1; }
	hf cache prune

models-rm: ## Remove a cached model — pass MODEL=<repo> (e.g. mlx-community/GLM-4.7-Flash-8bit)
	@command -v hf >/dev/null || { echo "hf not found — run: make install" >&2; exit 1; }
	@[[ -n "$(MODEL)" ]] || { echo "Usage: make models-rm MODEL=<repo>" >&2; exit 1; }
	hf cache rm "$(MODEL)"

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'
