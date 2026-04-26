SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := check

SCRIPTS    := bin/4lm bin/4lm-backend-start.sh bin/4lm-webui-start.sh install.sh uninstall.sh tests/lint-profiles.sh
PLISTS     := launchd/com.4lm.backend.plist launchd/com.4lm.webui.plist
SHFMT_OPTS := -i 2 -ci

.PHONY: check bootstrap install uninstall lint fmt syntax test plist-lint yaml-lint help

check: lint syntax plist-lint yaml-lint test ## Run all gates (default)

bootstrap: ## Install required tools from Brewfile + pipx ensurepath
	brew bundle --file=Brewfile
	pipx ensurepath

install: ## Run ./install.sh
	./install.sh

uninstall: ## Run ./uninstall.sh — DESTRUCTIVE, removes ~/.4lm and chat history
	./uninstall.sh

lint: ## shellcheck + shfmt -d on all scripts
	shellcheck $(SCRIPTS)
	shfmt $(SHFMT_OPTS) -d $(SCRIPTS)

fmt: ## shfmt -w (rewrites scripts in place)
	shfmt $(SHFMT_OPTS) -w $(SCRIPTS)

syntax: ## bash -n on all scripts (literal SDD R37)
	@for f in $(SCRIPTS); do bash -n $$f && echo "OK   $$f"; done

test: ## Run the bats suite
	bats tests/

plist-lint: ## plutil -lint + xmllint --noout on all plists
	plutil -lint $(PLISTS)
	xmllint --noout $(PLISTS)

yaml-lint: ## Validate every profile YAML against the bin/4lm schema
	tests/lint-profiles.sh

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'
