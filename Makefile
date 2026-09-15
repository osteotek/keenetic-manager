PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
COMPLETIONDIR ?= $(PREFIX)/share/bash-completion/completions

.PHONY: install uninstall check check-router release

install:
	install -Dm755 keenetic "$(DESTDIR)$(BINDIR)/keenetic"
	install -Dm644 completions/keenetic.bash "$(DESTDIR)$(COMPLETIONDIR)/keenetic"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/keenetic"
	rm -f "$(DESTDIR)$(COMPLETIONDIR)/keenetic"

check:
	bash -n keenetic tests/integration.sh tests/router-contract.sh scripts/build-release.sh completions/keenetic.bash
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck keenetic tests/integration.sh tests/router-contract.sh scripts/build-release.sh completions/keenetic.bash; else echo "shellcheck not found; skipping"; fi
	./tests/integration.sh

check-router:
	./tests/router-contract.sh

release:
	./scripts/build-release.sh
