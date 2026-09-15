PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
COMPLETIONDIR ?= $(PREFIX)/share/bash-completion/completions
ZSH_COMPLETIONDIR ?= $(PREFIX)/share/zsh/site-functions

.PHONY: install uninstall check check-router release

install:
	install -d "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(COMPLETIONDIR)" "$(DESTDIR)$(ZSH_COMPLETIONDIR)"
	install -m 755 keenetic "$(DESTDIR)$(BINDIR)/keenetic"
	install -m 644 completions/keenetic.bash "$(DESTDIR)$(COMPLETIONDIR)/keenetic"
	install -m 644 completions/_keenetic "$(DESTDIR)$(ZSH_COMPLETIONDIR)/_keenetic"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/keenetic"
	rm -f "$(DESTDIR)$(COMPLETIONDIR)/keenetic"
	rm -f "$(DESTDIR)$(ZSH_COMPLETIONDIR)/_keenetic"

check:
	bash -n keenetic tests/integration.sh tests/router-contract.sh scripts/build-release.sh completions/keenetic.bash
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck keenetic tests/integration.sh tests/router-contract.sh scripts/build-release.sh completions/keenetic.bash; else echo "shellcheck not found; skipping"; fi
	@if command -v zsh >/dev/null 2>&1; then zsh -n completions/_keenetic; else echo "zsh not found; skipping zsh completion syntax check"; fi
	./tests/integration.sh

check-router:
	./tests/router-contract.sh

release:
	./scripts/build-release.sh
