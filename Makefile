SHELL   := bash
SCRIPTS := bin/4lm bin/4lm-backend-start.sh bin/4lm-webui-start.sh install.sh
PLISTS  := launchd/com.4lm.backend.plist launchd/com.4lm.webui.plist

.PHONY: lint fmt test check

lint:
	shellcheck $(SCRIPTS)
	shfmt -d $(SCRIPTS)

fmt:
	shfmt -w $(SCRIPTS)

test:
	bats tests/

check: lint
	bash -n $(SCRIPTS)
	plutil -lint $(PLISTS)
	xmllint --noout $(PLISTS)
	bats tests/
