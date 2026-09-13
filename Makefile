PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
COMPLETIONDIR ?= $(PREFIX)/share/bash-completion/completions

.PHONY: install uninstall check check-router release

install:
	install -Dm755 keenetic-policy.sh "$(DESTDIR)$(BINDIR)/keenetic-policy"
	install -Dm644 completions/keenetic-policy.bash "$(DESTDIR)$(COMPLETIONDIR)/keenetic-policy"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/keenetic-policy"
	rm -f "$(DESTDIR)$(COMPLETIONDIR)/keenetic-policy"

check:
	bash -n keenetic-policy.sh tests/integration.sh tests/router-contract.sh scripts/build-release.sh completions/keenetic-policy.bash
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck keenetic-policy.sh tests/integration.sh tests/router-contract.sh scripts/build-release.sh completions/keenetic-policy.bash; else echo "shellcheck not found; skipping"; fi
	./tests/integration.sh

check-router:
	./tests/router-contract.sh

release:
	./scripts/build-release.sh
