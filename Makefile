BINARY        = .build/release/superlinear
INSTALL_PATH  = $(HOME)/.local/bin/superlinear
PLIST_SRC     = LaunchAgents/com.armcknight.superlinear.plist.template
PLIST_DEST    = $(HOME)/Library/LaunchAgents/com.armcknight.superlinear.plist
LABEL         = com.armcknight.superlinear
LOG           = $(HOME)/.local/share/superlinear/daemon.log
STATE         = $(HOME)/.local/share/superlinear/state.json
LOGS_DIR      = $(HOME)/.local/share/superlinear/logs
CONFIG        = $(HOME)/.config/superlinear/config.json

.PHONY: build install load unload reload logs config status reset

build:
	swift build -c release

install: build
	mkdir -p $(HOME)/.local/bin $(HOME)/.local/share/superlinear $(HOME)/.config/superlinear
	cp $(BINARY) $(INSTALL_PATH)

load: install
	mkdir -p $(HOME)/Library/LaunchAgents
	sed 's|__HOME__|$(HOME)|g' $(PLIST_SRC) > $(PLIST_DEST)
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

reset:
	rm -f $(STATE)
	rm -f $(LOGS_DIR)/*.log
	-tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^superlinear_' | xargs -I{} tmux kill-session -t {}
	@echo "State, logs, and tmux sessions cleared. Daemon will reprocess all issues on next poll."

status:
	@launchctl list | grep $(LABEL) || echo "Not running"
