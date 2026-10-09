# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `make install` builds with semver build metadata, so `superlinear --version`
  prints e.g. `1.1.0+d0a4bc2` for a local build, with `.dirty` appended when the
  working tree had uncommitted or untracked changes. Releases print the bare
  version.

### Changed

- A local build takes precedence over Homebrew. `superlinear install` from the
  Homebrew binary leaves an agent that runs an existing local build in place;
  pass `--force` to replace it. `make install` warns when another
  `superlinear` shadows `~/.local/bin` in your `PATH`.

### Fixed

- `brew uninstall --cask superlinear` removes the launch agent, and
  `brew upgrade` restarts a registered daemon on the new version. Before, an
  uninstall left an agent that launchd retried every 30 seconds, and an upgrade
  left the old version running. The upgrade to this release already restarts
  the daemon; `brew uninstall` cleans up once this release is installed.
- `superlinear install` from Homebrew points the agent at
  `/opt/homebrew/bin/superlinear` instead of the versioned Caskroom directory,
  which `brew upgrade` deletes. Before, the agent stopped starting after an
  upgrade until `superlinear install` ran again. Run it once more to move an
  existing agent to the new path.

## [1.1.0] 2026-10-08

### Changed

- The agent prompt runs the plugin's commands by its new name,
  `/armcknight-claude:start`, `:commit` and `:pr`. The plugin was renamed from
  `claude-armcknight` in its 0.2.0, because Claude Code now reserves plugin
  names that start with `claude-`. Install it as
  `claude plugin install armcknight-claude@armcknight`, and uninstall the old
  one; with only the old one installed, the agent's commands do not exist.

## [1.0.1] 2026-08-10

### Fixed

- First published build. The 1.0.0 release was tagged but its CI release job
  failed before publishing (a signing-pipeline bug); 1.0.1 ships the Developer
  ID signed, notarized binary.

## [1.0.0] 2026-08-10

First tagged release. `superlinear` is a macOS launchd daemon that watches
Linear for new issues and starts an autonomous Claude Code agent for each one.

### Added
- The daemon: each configured workspace polls Linear on its own concurrent
  loop for issues in the `backlog` or `unstarted` state (optionally filtered by
  team), and processes each new issue once, recording it in an atomically-saved
  state file so it is never picked up twice.
- Per-issue automation via `work start --headless --prompt-file <prompt>
  --log-file <log> <branch>` (see workr): a worktree is created on the issue's
  Linear `branchName`, `make init` runs, and the prompt is piped into
  `claude -p`. The agent is told to plan, implement, commit and open a PR with
  no human in the loop.
- `superlinear install` / `uninstall` — generate and register (or remove) the
  launchd agent from a templated plist, so the daemon starts at login and
  restarts on exit.
- Configuration at `~/.config/superlinear/config.json`; runtime state under
  `~/.local/share/superlinear`.
- SIGINT-killable; kills stale duplicate tmux sessions from prior runs.
- `make init` with a Brewfile that installs the runtime dependencies (fish,
  tmux, Claude Code, workr, `linctl`, `direnv`, `gh`).
- Distribution as a Developer ID-signed, notarized binary through the
  `armcknight/homebrew-tools` tap; `ci.yml` and `release.yml` delegate to
  `armcknight/workflows`' reusable SwiftPM pipelines.
- CI coverage for config loading, state handling, issue decoding, and the shell
  wrapper.

### License
- Apache-2.0.
