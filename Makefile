SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := check

SCRIPTS := bin/4lm bin/4lm-backend-start.sh bin/4lm-webui-start.sh install.sh
PLISTS  := launchd/com.4lm.backend.plist launchd/com.4lm.webui.plist

.PHONY: check lint fmt test plist-lint help

check: lint plist-lint test ## Run all gates: lint, plist-lint, test (default)

lint: ## shellcheck + shfmt -d on all scripts
	shellcheck $(SCRIPTS)
	shfmt -d $(SCRIPTS)

fmt: ## shfmt -w (rewrites scripts in place)
	shfmt -w $(SCRIPTS)

test: ## Run the bats suite (covers profile YAML validation via bin/4lm)
	bats tests/

plist-lint: ## plutil -lint + xmllint --noout on all plists
	plutil -lint $(PLISTS)
	xmllint --noout $(PLISTS)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'
