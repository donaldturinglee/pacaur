PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
DESTDIR ?=

.PHONY: install uninstall

install: pacaur
	install -d -- "$(DESTDIR)$(BINDIR)"
	install -m 755 -- pacaur "$(DESTDIR)$(BINDIR)/pacaur"

uninstall:
	rm -f -- "$(DESTDIR)$(BINDIR)/pacaur"
