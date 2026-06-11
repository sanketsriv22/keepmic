PREFIX ?= $(shell [ -d /opt/homebrew/bin ] && [ -w /opt/homebrew/bin ] && echo /opt/homebrew || echo /usr/local)
BINDIR := $(PREFIX)/bin
AGENT_PLIST := $(HOME)/Library/LaunchAgents/com.keepmic.agent.plist

.PHONY: build install install-bin uninstall clean

build:
	swift build -c release

install: build install-bin
	@if [ -f "$(AGENT_PLIST)" ] && [ "$$(id -u)" != "0" ]; then \
		echo "Restarting the keepmic agent with the new binary..."; \
		"$(BINDIR)/keepmic" run; \
	else \
		echo ""; \
		echo "Installed $(BINDIR)/keepmic"; \
		echo "Start the background agent with: keepmic run"; \
	fi

# Copy the already-built binary only — lets non-Homebrew users do:
#   make build && sudo make install-bin && keepmic run
install-bin:
	install -d "$(BINDIR)"
	install ".build/release/keepmic" "$(BINDIR)/keepmic"

uninstall:
	-"$(BINDIR)/keepmic" quit 2>/dev/null || keepmic quit 2>/dev/null || true
	rm -f "$(BINDIR)/keepmic"

clean:
	swift package clean
