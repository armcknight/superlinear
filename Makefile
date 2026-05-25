BINARY        = .build/release/superlinear
INSTALL_PATH  = $(HOME)/.local/bin/superlinear
PLIST_SRC     = LaunchAgents/com.armcknight.superlinear.plist
PLIST_DEST    = $(HOME)/Library/LaunchAgents/com.armcknight.superlinear.plist
LABEL         = com.armcknight.superlinear
LOG           = $(HOME)/.local/share/superlinear/daemon.log
CONFIG        = $(HOME)/.config/superlinear/config.json

.PHONY: build install load unload reload logs config status

build:
	swift build -c release

install: build
	mkdir -p $(HOME)/.local/bin $(HOME)/.local/share/superlinear $(HOME)/.config/superlinear
	cp $(BINARY) $(INSTALL_PATH)

load: install
	cp $(PLIST_SRC) $(PLIST_DEST)
	launchctl load -w $(PLIST_DEST)
	@echo "Loaded. Check logs with: make logs"

unload:
	-launchctl unload $(PLIST_DEST)

reload: unload load

logs:
	tail -f $(LOG)

config:
	@if [ ! -f $(CONFIG) ]; then \
		echo "Creating example config at $(CONFIG)"; \
		mkdir -p $(HOME)/.config/superlinear; \
		echo '{\n  "workspaces": [\n    {\n      "name": "my-workspace",\n      "apiKey": "lin_api_YOUR_KEY_HERE",\n      "repoPath": "~/Code/my-repo",\n      "teamIds": [],\n      "pollIntervalSeconds": 60\n    }\n  ]\n}' > $(CONFIG); \
	else \
		echo "Config already exists at $(CONFIG)"; \
	fi
	$${EDITOR:-emacs} $(CONFIG)

status:
	@launchctl list | grep $(LABEL) || echo "Not running"
