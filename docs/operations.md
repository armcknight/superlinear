# Operations

How to install and run the daemon, and what it does to keep going: restarts, disk space, and the status report.

<a id="install"></a>
## Installation

From the Homebrew tap:

```sh
brew install --cask armcknight/tools/superlinear
superlinear install     # register the launch agent
```

Or from a checkout:

```sh
make init     # trust the third-party taps, then install the Brewfile
make config   # write an example config, then open it in $EDITOR
make load     # build, install into ~/.local/bin, then register the agent
```

`superlinear install` writes `~/Library/LaunchAgents/com.armcknight.superlinear.plist` and loads it, pointing the agent at whichever binary you ran it from. Re-running it reloads. `superlinear uninstall` stops the agent and removes it. With the cask, the daemon follows Homebrew itself: within a minute of `brew upgrade` it exits and launchd restarts it on the new version, and a few minutes after `brew uninstall` it removes its own agent. A daemon running a local build restarts the same way within a minute of `make install` replacing its binary. Agents in flight carry on through the restart.

If both installs are present, the local build wins. `superlinear install` from the Homebrew binary leaves an agent that runs an existing local build in place; pass `--force` to replace it. The agent runs one binary, so a new build of the other kind does not restart the daemon: to switch, run `superlinear install` from the binary to switch to. `superlinear status` shows which binary the daemon runs. `superlinear --version` tells them apart: a local build appends the commit, as in `1.1.0+d0a4bc2`, plus `.dirty` when the working tree had uncommitted or untracked changes.

The agent is generated rather than checked in because launchd expands neither `~` nor `$HOME` inside a plist — every path in it has to be absolute, so no single file can serve every machine. The cask cannot do this either: Homebrew has no launchd support for casks, and the `service` stanza installs to `~/Library/Services`, which is the Services menu, not an agent.

<a id="usage"></a>
## Usage

```
superlinear [--config <path>]
superlinear install
superlinear uninstall
superlinear status [--since <duration>] [--config <path>]
superlinear proposals [--workspace <name>] [--config <path>]
superlinear plan [--workspace <name>] [--config <path>]
superlinear resume
```

With no subcommand it runs the daemon in the foreground, which is how to test a configuration without registering a launch agent. `--config` overrides the default path, `--version` prints the version, and `--help` prints this.

`superlinear resume` ends a pause of Claude sessions at the usage limit at once, as after you buy more usage or change plans before the reset time. It signals a running daemon, which starts the waiting sessions at once; with no daemon running, it lifts the pause in the state file. See [Usage and spending limits](lifecycle.md#limits).

<a id="restarts"></a>
## Restarts

Agents outlive the daemon, so restarting it — an upgrade, a config edit, `make reload`, a crash — does not stop work in flight. On start, the daemon checks each run left in the state file:

- **Still running:** it waits for that process and records the run finished when it exits.
- **Finished while the daemon was down:** a small wrapper around `work` leaves its exit status in a file, so the run is recorded finished.
- **Interrupted**, as by a reboot: it goes back in the queue at its original place. When it starts, it runs `work start --headless --resume <uuid>`, which continues the same Claude session with a prompt to work out where it stopped and carry on. If Claude had not saved the session yet, it starts again under the same ID instead. A run interrupted three times is abandoned, with a message in the daemon log.
- **Queued and never started:** it stays in the queue.

<a id="disk-space"></a>
## Disk space

Agents' builds fill the disk fast: a SwiftPM `.build` directory or an Xcode DerivedData directory per worktree, often gigabytes each. The daemon frees them with `work clean`, which keeps the worktree:

- **As it goes:** when an agent ends — its work pushed and its pull request opened — its worktree's `.build` and DerivedData are removed.
- **At startup:** every worktree of a configured repository whose agent is not running is cleaned if its build output has been idle for an hour, so one you are using by hand is spared, and the DerivedData of worktrees since removed goes too. The daemon restarts on every upgrade, config edit and login, so anything missed is caught then.
- **On merge:** `work finish` removes the worktree whole, with its DerivedData.

<a id="status"></a>
## Status

`superlinear status` lists, for each workspace, what waits on you, then the tasks the daemon tracks, grouped by where they stand, then what it did on its own and what puts the work at risk:

| Section | Meaning |
| --- | --- |
| Waiting on you | Every open, non-draft pull request whose branch or title names an issue in the workspace's Linear, tracked by the daemon or not, those holding back the most work first: the open issues their issues block, directly and indirectly, and the pull requests stacked on them, each stack bottom first. Shows whether it is stacked on another, the review state — not reviewed, changes requested, approved, agent addressing review, or agent resolving conflicts — whether it conflicts with its base branch, the CI state, how many issues it blocks, and the URL. Pull requests an agent is working on come last. Then the number of [proposals waiting in Linear](planning.md#standup), labeled `superlinear: proposed`, with a link to each. |
| Draft pull requests | The same, for drafts, with the CI state. |
| Running | An agent works on the issue now. Shows its pid and log. |
| Addressing review | An agent addresses your review of the issue's pull request, or is queued to. Shows the pull request, and the pid and log once it runs. An interrupted one is listed as interrupted, and resumes like any other. |
| Resolving conflicts | An agent merges the base branch into the branch of the issue's pull request, which conflicts with it, or is queued to. Shows the pull request, and the pid and log once it runs. |
| Interrupted | The agent stopped without finishing, as at a reboot. The daemon resumes it when it next starts. |
| Queued | Waiting for a free agent slot, or for a pause at the Claude usage limit to end. A session the limit stopped says so; it resumes first. |
| Open pull requests | The agent finished and its pull request is open. Shown only when open pull requests could not be listed for review; otherwise they appear above. |
| Merged, issue not done | The pull request is merged, but the Linear issue is not in a completed state. |
| Finished without a pull request | The agent ended, but no pull request is open or merged, and the issue is still open. |
| Completed | The pull request is merged and the Linear issue is done. |
| Closed without a merge | The issue was closed in Linear without a merged pull request. |
| Done autonomously | What the daemon did on its own since `--since` (a number and a unit: `24h`, the default, `7d`, `90m`), oldest first: agents started, finished, failed or stopped; reviews addressed; conflicts resolved; issues completed in Linear after their merge; and proposals applied with `auto`. Not merged pull requests: superlinear never merges, so you know what you merged. |
| Risks | The active [pauses](lifecycle.md#limits) with the work they hold back, CI failing on the default branch, and GitHub's rate limit when less than a fifth of it is left. |
| Stale branches and worktrees | Local branches no longer needed: their pull request merged, or closed without a merge, or, for a worktree under `worktrees/` with no agent running or queued, none was opened. The base branch, branches with an open pull request, and branches of your own without such a worktree are never listed. Each shows its worktree if it has one, its last commit's age, and the commits removing it would lose: for a merged or closed pull request, those made after its head, as a squash merge leaves the rest on no remote branch; otherwise those no remote branch has. `work finish <branch>` removes the branch and its worktree. |

After the workspaces comes a summary:

- **Counts:** the number of projects, and of items in each section above, across all workspaces, the proposals in Linear among them.
- **Out of sync:** for each workspace whose open pull requests fork off local commits not yet pushed, how many do.
- **Per pull request:** the total, median, minimum and maximum of each measure, and a histogram of its values in 16 equal ranges from minimum to maximum, over the agents' pull requests — those of finished tasks that are open or merged, and the open ones listed for review. The measures are lines added and removed and files changed; tokens, cache reads and agent time, from the Claude transcripts; and CI time.
- **All tracked tasks:** the tokens, cache reads, agent time and CI time of every task, with or without a pull request.
- **By project:** each workspace's tasks, pull requests, lines, tokens, agent time and CI time.

When a [pause](lifecycle.md#limits) is active, the report begins with one line for it.

The report ends with this command's version and binary, then the daemon's: its pid, version, binary and start time, or that it is not running. It warns when the daemon's binary has been replaced since the daemon started. Last, under **Polls**, each workspace shows when its last poll ended, whether it failed, and when the next one is due, or, once that time has passed, that it is polling now. Each workspace polls on its own loop, which waits its `pollIntervalSeconds` after each poll ends, so each has its own times.

Lines and files of an open pull request come from `git diff --shortstat` in the local repository, measured from the later of two fork points: where the branch left the local base branch, and where it left `origin/<base>`. An agent forks off the local base, so when that is ahead of GitHub's, GitHub counts the unpushed commits as part of each pull request. The workspace then shows a warning to push the base branch. Merged pull requests, and branches found neither locally nor on `origin`, use GitHub's numbers.

Tokens are input, cache writes included, plus output; cache reads, much cheaper, are shown apart. The transcripts are found under `~/.claude/projects` by the name of the agent's worktree branch, so they count also after the worktree is removed. Each message counts once, and subagents' tokens count too. Agent time is the time between consecutive entries in the main session's transcripts, leaving out gaps over 30 minutes, as while the Mac slept. CI time is the start-to-end time of the branch's finished GitHub Actions runs, from `gh run list`; a dash means the repository has no runs. A dash in the tokens column means no transcripts were found.

A task is completed only when both its pull request is merged and its Linear issue is done. With Linear's GitHub integration installed for the repository, Linear moves the issue to done when the pull request merges, by default. Without it, the daemon marks the issue done itself on a later poll.

The command reads the state file, asks Linear for the state of each issue the daemon processed and of each issue an open pull request names, and runs `gh pr list` in each repository for the pull requests, their reviews, checks and sizes, `gh run list` for the CI runs, and `gh api rate_limit` for the rate limit. Where a repository requires no review, the review state comes from the latest reviews: an approval or a change request, or else not reviewed. It needs `gh` signed in. Issues archived in Linear drop out of the list. If Linear or GitHub is out of reach, it prints a warning and shows only the agents in flight.

<a id="make-targets"></a>
## Make targets

| Target | Effect |
| --- | --- |
| `init` | Trust the third-party taps, then install the [Brewfile](../Brewfile). Run by `work start` in each new worktree, so it is idempotent. |
| `build` | Build the release binary. |
| `test` | Run the unit tests. |
| `check-docs` | Check that the relative links and anchors in the README and `docs/` resolve, and that `docs/anchors.md` lists every anchor. CI runs it. |
| `install` | Build with the git commit in the version, then copy the binary to `~/.local/bin`. Warns when another `superlinear` shadows it in `PATH`. |
| `load` | Install, then register and start the launch agent. |
| `unload` | Stop the launch agent and remove it. |
| `reload` | `unload` then `load`. |
| `logs` | Follow the daemon log. |
| `config` | Create the example config if absent, then open it. |
| `status` | Show whether launchd is running the daemon. |
| `reset` | Delete state, run records and per-issue logs, and kill leftover `superlinear_*` tmux sessions. The next poll starts over as for a new workspace: see [First poll](lifecycle.md#first-poll). Agents already running are not stopped. |
| `patch` | Bump the version and commit. Also `minor`, `major`. |
| `deploy` | Tag and push the current version, shipping the stable cask. Also `deploy-beta` for an RC. |

`make help` prints this list too.

<a id="releasing"></a>
## Releasing superlinear

A person releases superlinear, as any project: see [the release rule](builds.md#release-rule).

```sh
make patch      # or minor / major — bumps Sources/superlinear/Version.swift
make deploy     # tag and push, which ships the cask
```

The tag triggers the release workflow, which checks the tag against the version in source, builds, Developer ID signs and notarizes, then bumps `Casks/superlinear.rb` in the tap. `make deploy-beta` cuts a release candidate into the `superlinear-rc` cask instead.

Signing is on because launchd starts this binary, not your shell. An unsigned CLI is fine when a shell runs it; a quarantined binary launched by launchd is not.
