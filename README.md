# superlinear

A macOS launchd daemon that watches [Linear](https://linear.app) for new issues and starts an autonomous [Claude Code](https://claude.com/claude-code) agent for each one.

For every new issue, the daemon creates a git worktree on the issue's branch and runs an agent that plans the work, implements it, commits, and opens a pull request — without a human in the loop. See [workr](https://github.com/armcknight/workr) for more info, as this is what it uses by default.

## Status

This is a personal tool, published as a reference. It is opinionated about how work gets done, but everything it depends on is now installable — see [External dependencies](#external-dependencies).

## How it works

1. `launchd` starts the binary at login and restarts it if it exits.
2. Each configured workspace polls on its own loop, concurrently.
3. Each poll queries the Linear GraphQL API for issues created since the last poll, in the `backlog` or `unstarted` state, optionally filtered by team. Results are paginated 50 at a time.
4. Issue IDs already recorded in the state file are discarded, so an issue is processed once.
5. Each remaining issue is recorded as processed and queued. While fewer than `maxConcurrentAgents` agents run, the oldest queued issue starts. The poll does not wait for agents — the next one runs on schedule however long they take. It picks a Claude session ID, writes the prompt to a file, then runs, in the repository directory:

   ```
   work start --headless --prompt-file <prompt> --log-file <log> --session-id <uuid> <issue-branch-name>
   ```

   This creates a worktree at `worktrees/<branch>`, runs `make init`, and pipes the prompt into `claude -p` under that session ID.
6. The run — issue, branch, session ID, and the process running it — is kept in the state file until the agent exits.
7. When the agent exits, the issue waits in the state file for its pull request. Each poll runs `gh pr list --head <branch> --state all` in the repository for every waiting issue:
   - **Merged:** the issue moves to its team's first completed state in Linear, unless it is already completed or canceled, and `work finish <branch>` removes the worktree and the local branch. If Linear cannot be updated, the next poll tries again.
   - **Open:** the next poll checks again — unless you have reviewed it, or it conflicts with its base branch. See [Reviews](#reviews) and [Conflicts](#conflicts).
   - **Closed without a merge**, or **no pull request:** the daemon logs it and stops watching. The worktree stays for you to inspect.

### GitHub issues

A workspace with `"githubIssues": true` also takes work from its repository's GitHub issues, with `gh` signed in as you. Each poll lists the repository's open issues, newest 1,000, and queues the ones you asked for:

- **Issues you open**, from the first poll with the option on. Issues you opened before then are left alone, so turning it on does not start an agent on every old issue.
- **Issues anyone opened, yours included, on which you comment a line starting with `/superlinear-do`.** Comments from anyone else do nothing.

Each issue is processed once, as Linear's are, and shares the same queue and agent limit. Its run is named `GH-<number>`, on the branch `github/gh-<number>`. Its agent reads the issue with `gh issue view`, implements, commits, and opens a pull request with `/armcknight-claude:pr --autonomous`, putting `Closes #<number>` in the description. Nothing is linked or updated in Linear. When the pull request merges, the daemon closes the issue as completed if GitHub has not already, then removes the worktree. If GitHub cannot be reached, the daemon logs it once and goes on with Linear. Your reviews on its pull request bring an agent back, as for a Linear issue's (see [Reviews](#reviews)), and that agent reads the issue from GitHub too.

### Reviews

Review a pull request the daemon is watching, and an agent comes back to address it. Each poll reads the reviews on the open pull request of every issue awaiting its merge. A review counts when:

- it is from the GitHub user `gh` is signed in as,
- it was submitted after the issue's last agent started, and
- it asks for something: changes requested, a comment review — including one made only of comments on lines of code — or an approval with a note. An approval with nothing written, a draft review and a dismissed review do not count.

The issue then goes back in the queue. Its agent runs in the same worktree, on the same branch, under a new Claude session, with a prompt to read every review and its inline comments, satisfy the points not yet addressed, commit, push and see CI through. It does not reply on GitHub. When it ends, the issue waits for its merge again, and only reviews submitted after that agent started bring it back. Reviews from other people and from bots, such as Seer, are left alone: the first agent already handles bots' reviews.

Issues already awaiting their merge when you upgrade to a version that follows reviews take their pull request's newest commit as the starting point: a review submitted after the last push still starts an agent, and older reviews, which the agent may have addressed, do not.

### Conflicts

When the base branch moves on and an open pull request the daemon is watching no longer merges cleanly, an agent comes back to merge the base branch in. Each poll reads GitHub's mergeable state for those pull requests, in the listing that brings their reviews. For one that conflicts, the daemon fetches the base branch from `origin`, then queues the issue. Its agent runs in the same worktree, on the same branch, under a new Claude session, with a prompt to merge `origin/<base>` into the branch, resolve each conflict so that both sides' changes stay, build and test, commit the merge, push and see CI through. It does not rebase, force-push or comment on GitHub.

Reviews come first: if a review also needs an agent, that agent goes first, and the conflict waits for the poll after it ends. The conflict also waits for a poll that can read the reviews, so the review baseline stays correct; a conflict run does not count reviews as addressed.

Each conflict gets one agent. The daemon records the heads of the branch and of the base when it queues the agent. If the pull request still conflicts with the same heads after the agent ends, the daemon logs that once and starts no other agent until one of the two branches moves. GitHub works out the mergeable state in the background after a push, so a pull request it has not yet checked waits for a later poll.

### Disk space

Agents' builds fill the disk fast: a SwiftPM `.build` directory or an Xcode DerivedData directory per worktree, often gigabytes each. The daemon frees them with `work clean`, which keeps the worktree:

- **As it goes:** when an agent ends — its work pushed and its pull request opened — its worktree's `.build` and DerivedData are removed.
- **At startup:** every worktree of a configured repository whose agent is not running is cleaned if its build output has been idle for an hour, so one you are using by hand is spared, and the DerivedData of worktrees since removed goes too. The daemon restarts on every upgrade, config edit and login, so anything missed is caught then.
- **On merge:** `work finish` removes the worktree whole, with its DerivedData.

### Restarts

Agents outlive the daemon, so restarting it — an upgrade, a config edit, `make reload`, a crash — does not stop work in flight. On start, the daemon checks each run left in the state file:

- **Still running:** it waits for that process and records the run finished when it exits.
- **Finished while the daemon was down:** a small wrapper around `work` leaves its exit status in a file, so the run is recorded finished.
- **Interrupted**, as by a reboot: it goes back in the queue at its original place. When it starts, it runs `work start --headless --resume <uuid>`, which continues the same Claude session with a prompt to work out where it stopped and carry on. If Claude had not saved the session yet, it starts again under the same ID instead. A run interrupted three times is abandoned, with a message in the daemon log.
- **Queued and never started:** it stays in the queue.

The prompt instructs the agent to run `/armcknight-claude:start`, implement the change, run `/armcknight-claude:commit`, then run `/armcknight-claude:pr --autonomous` to open a PR and monitor CI. The agent is told not to pause for confirmation.

Branch names come from Linear's own `branchName` field, so the branch matches what the Linear UI shows. Each poll also attaches the pull requests opened from an issue's branch to the issue in Linear, from the first poll after the PR is opened, so the link is there whether or not Linear's GitHub integration is set up for the repository.

The same goes for started issues the daemon is not following — work done by hand, or by agents from before a state reset. Each poll matches issues In Progress or In Review to pull requests by branch, links them, and marks an issue done once its pull request has merged, unless a pull request on its branch is still open or the issue was moved back into progress after the merge. Their worktrees are left alone. This needs an API key with write access; with a read-only key it logs the refusal once.

## Requirements

`make init` installs everything Homebrew can provide — tmux, Claude Code, workr, and the `linctl`, `direnv` and `gh` that the agent's slash commands need. The daemon uses `gh` itself too, to find merged pull requests, so it must be signed in to GitHub. See the [Brewfile](Brewfile).

Supply the rest yourself:

- macOS 14 or later
- Swift 6 toolchain, from Xcode
- A Linear API key
- The [`armcknight-claude` plugin](https://github.com/armcknight/armcknight-claude), which Homebrew cannot install — see [External dependencies](#external-dependencies)
- Target repositories with a `make init` target and a `CLAUDE.md` describing the project

`make init` trusts the two third-party taps in the Brewfile before bundling. Homebrew refuses to load formulae from untrusted taps, and `brew bundle` aborts on the first one it meets without installing anything at all. `work start` runs `make init` in every new worktree, so it is written to be idempotent.

### External dependencies

The daemon does the polling. Everything after that — the worktree, and the work itself — is delegated to two other projects. Without them the daemon polls correctly but fails at the point it starts an agent.

| Dependency | Provides | Install |
| --- | --- | --- |
| [workr](https://github.com/armcknight/workr) | `work start --headless --prompt-file <path> --log-file <path> <branch>`, which creates the worktree, prepares it, and pipes the prompt into `claude -p`. | `brew install --cask armcknight/tools/work` |
| [armcknight-claude](https://github.com/armcknight/armcknight-claude) | The `start`, `commit` and `pr` slash commands the prompt drives. | `claude plugin marketplace add armcknight/armcknight-claude` then `claude plugin install armcknight-claude@armcknight` |

The `armcknight-claude` plugin also needs `linctl`, `direnv` and `gh` to talk to Linear and GitHub. Its README lists them, with a Brewfile.

To substitute your own tooling, put a `work` executable with the same interface on the agent's PATH, or edit the prompts in `Sources/superlinear/AgentRunner.swift`, which is where the command names live. Resuming needs `--session-id` and `--resume`, from workr 1.1.0.

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

## Configuration

```sh
make config
```

Creates `~/.config/superlinear/config.json` from the included example and opens it in your editor. The config is never tracked in git — keep your API keys local.

```json
{
  "maxConcurrentAgents": 3,
  "workspaces": [
    {
      "name": "my-workspace",
      "apiKey": "lin_api_YOUR_KEY_HERE",
      "repoPath": "~/Code/my-repo",
      "teamIds": [],
      "pollIntervalSeconds": 60,
      "githubIssues": false
    }
  ]
}
```

| Key | Required | Description |
| --- | --- | --- |
| `name` | yes | Label for logs. Also the key under which state is stored. |
| `apiKey` | yes | Linear personal API key. |
| `repoPath` | yes | Repository the agent works in. `~` is expanded. |
| `teamIds` | no | Linear team IDs to watch. Empty or absent means all teams. Defaults to `[]`. |
| `pollIntervalSeconds` | no | Seconds between polls. Defaults to `60`. |
| `githubIssues` | no | Also work on the repository's GitHub issues that you open or comment `/superlinear-do` on. See [GitHub issues](#github-issues). Defaults to `false`. |

`maxConcurrentAgents`, at the top level beside `workspaces`, limits how many agents run at once across all workspaces. It defaults to `3`. Further issues wait in a queue, kept in the state file, and start oldest first as running agents finish. An interrupted agent keeps its place, so it resumes before newer issues start.

Each workspace entry is one Linear-account-to-repository pairing. List several to watch more than one repository.

Edits take effect on their own. The daemon checks the file every five seconds; when it changes to a config that loads, the daemon exits and launchd restarts it on the new one, with agents in flight carrying on. An edit that does not load — invalid JSON, a missing key, no workspaces — is logged once and ignored until fixed. A daemon run in the foreground only logs that a restart is needed.

## Releasing

```sh
make patch      # or minor / major — bumps Sources/superlinear/Version.swift
make deploy     # tag and push, which ships the cask
```

The tag triggers the release workflow, which checks the tag against the version in source, builds, Developer ID signs and notarizes, then bumps `Casks/superlinear.rb` in the tap. `make deploy-beta` cuts a release candidate into the `superlinear-rc` cask instead.

Signing is on because launchd starts this binary, not your shell. An unsigned CLI is fine when a shell runs it; a quarantined binary launched by launchd is not.

## Make targets

| Target | Effect |
| --- | --- |
| `init` | Trust the third-party taps, then install the [Brewfile](Brewfile). Run by `work start` in each new worktree, so it is idempotent. |
| `build` | Build the release binary. |
| `test` | Run the unit tests. |
| `install` | Build with the git commit in the version, then copy the binary to `~/.local/bin`. Warns when another `superlinear` shadows it in `PATH`. |
| `load` | Install, then register and start the launch agent. |
| `unload` | Stop the launch agent and remove it. |
| `reload` | `unload` then `load`. |
| `logs` | Follow the daemon log. |
| `config` | Create the example config if absent, then open it. |
| `status` | Show whether launchd is running the daemon. |
| `reset` | Delete state, run records and per-issue logs, and kill leftover `superlinear_*` tmux sessions. Every issue is reprocessed on the next poll. Agents already running are not stopped. |
| `patch` | Bump the version and commit. Also `minor`, `major`. |
| `deploy` | Tag and push the current version, shipping the stable cask. Also `deploy-beta` for an RC. |

`make help` prints this list too.

## Files

| Path | Contents |
| --- | --- |
| `~/.config/superlinear/config.json` | Configuration, including API keys. |
| `~/.local/share/superlinear/state.json` | Last poll time, processed issue IDs, runs in flight, and issues awaiting their pull request's merge, per workspace. |
| `~/.local/share/superlinear/daemon.lock` | Held by the running daemon, so a second one exits. |
| `~/.local/share/superlinear/runs/` | Each run's prompt, and its exit status once it ends. |
| `~/.local/share/superlinear/daemon.log` | Daemon output. |
| `~/.local/share/superlinear/logs/<ISSUE-ID>.log` | Agent output for one issue. A resumed run appends to it. |
| `~/.local/share/superlinear/logs/<ISSUE-ID>.work.log` | Output of `work` itself for one issue, such as worktree setup, teardown after the merge, and errors. |

Per-issue logs are written only when the agent exits. `claude -p` buffers its output, so following the file during a run shows nothing.

## Usage

```
superlinear [--config <path>]
superlinear install
superlinear uninstall
superlinear status [--config <path>]
```

With no subcommand it runs the daemon in the foreground, which is how to test a configuration without registering a launch agent. `--config` overrides the default path, `--version` prints the version, and `--help` prints this.

### Status

`superlinear status` lists, for each workspace, the open pull requests that belong to a Linear issue, then the tasks the daemon tracks, grouped by where they stand:

| Section | Meaning |
| --- | --- |
| Awaiting review | Every open, non-draft pull request whose branch or title names an issue in the workspace's Linear, tracked by the daemon or not. Shows the review state — not reviewed, changes requested, approved, agent addressing review, or agent resolving conflicts — whether it conflicts with its base branch, the CI state, and the URL. |
| Draft pull requests | The same, for drafts, with the CI state. |
| Running | An agent works on the issue now. Shows its pid and log. |
| Addressing review | An agent addresses your review of the issue's pull request, or is queued to. Shows the pull request, and the pid and log once it runs. An interrupted one is listed as interrupted, and resumes like any other. |
| Resolving conflicts | An agent merges the base branch into the branch of the issue's pull request, which conflicts with it, or is queued to. Shows the pull request, and the pid and log once it runs. |
| Interrupted | The agent stopped without finishing, as at a reboot. The daemon resumes it when it next starts. |
| Queued | Waiting for a free agent slot. |
| Open pull requests | The agent finished and its pull request is open. Shown only when open pull requests could not be listed for review; otherwise they appear above. |
| Merged, issue not done | The pull request is merged, but the Linear issue is not in a completed state. |
| Finished without a pull request | The agent ended, but no pull request is open or merged, and the issue is still open. |
| Completed | The pull request is merged and the Linear issue is done. |
| Closed without a merge | The issue was closed in Linear without a merged pull request. |
| Stale branches and worktrees | Local branches no longer needed: their pull request merged, or closed without a merge, or, for a worktree under `worktrees/` with no agent running or queued, none was opened. The base branch, branches with an open pull request, and branches of your own without such a worktree are never listed. Each shows its worktree if it has one, its last commit's age, and the commits removing it would lose: for a merged or closed pull request, those made after its head, as a squash merge leaves the rest on no remote branch; otherwise those no remote branch has. `work finish <branch>` removes the branch and its worktree. |

After the workspaces comes a summary:

- **Counts:** the number of projects, and of items in each section above, across all workspaces.
- **Out of sync:** for each workspace whose open pull requests fork off local commits not yet pushed, how many do.
- **Per pull request:** the total, median, minimum and maximum of each measure, and a histogram of its values in 16 equal ranges from minimum to maximum, over the agents' pull requests — those of finished tasks that are open or merged, and the open ones listed for review. The measures are lines added and removed and files changed; tokens, cache reads and agent time, from the Claude transcripts; and CI time.
- **All tracked tasks:** the tokens, cache reads, agent time and CI time of every task, with or without a pull request.
- **By project:** each workspace's tasks, pull requests, lines, tokens, agent time and CI time.

The report ends with this command's version and binary, then the daemon's: its pid, version, binary and start time, or that it is not running. It warns when the daemon's binary has been replaced since the daemon started. Last, under **Polls**, each workspace shows when its last poll ended, whether it failed, and when the next one is due, or, once that time has passed, that it is polling now. Each workspace polls on its own loop, which waits its `pollIntervalSeconds` after each poll ends, so each has its own times.

Lines and files of an open pull request come from `git diff --shortstat` in the local repository, measured from the later of two fork points: where the branch left the local base branch, and where it left `origin/<base>`. An agent forks off the local base, so when that is ahead of GitHub's, GitHub counts the unpushed commits as part of each pull request. The workspace then shows a warning to push the base branch. Merged pull requests, and branches found neither locally nor on `origin`, use GitHub's numbers.

Tokens are input, cache writes included, plus output; cache reads, much cheaper, are shown apart. The transcripts are found under `~/.claude/projects` by the name of the agent's worktree branch, so they count also after the worktree is removed. Each message counts once, and subagents' tokens count too. Agent time is the time between consecutive entries in the main session's transcripts, leaving out gaps over 30 minutes, as while the Mac slept. CI time is the start-to-end time of the branch's finished GitHub Actions runs, from `gh run list`; a dash means the repository has no runs. A dash in the tokens column means no transcripts were found.

A task is completed only when both its pull request is merged and its Linear issue is done. With Linear's GitHub integration installed for the repository, Linear moves the issue to done when the pull request merges, by default. Without it, the daemon marks the issue done itself on a later poll.

The command reads the state file, asks Linear for the state of each issue the daemon processed and of each issue an open pull request names, and runs `gh pr list` in each repository for the pull requests, their reviews, checks and sizes, and `gh run list` for the CI runs. Where a repository requires no review, the review state comes from the latest reviews: an approval or a change request, or else not reviewed. It needs `gh` signed in. Issues archived in Linear drop out of the list. If Linear or GitHub is out of reach, it prints a warning and shows only the agents in flight.

## Security

Read this before you run the daemon.

- **The agent runs with permission checks disabled.** `work start --headless` invokes `claude -p --dangerously-skip-permissions`. The agent executes commands in your repository without asking. Point it only at repositories where that is acceptable, and only at Linear teams whose issues you trust.
- **Anyone who can file an issue controls the prompt.** Issue titles and bodies reach an agent that has a shell. Treat write access to a watched Linear team as equivalent to shell access.
- **The API key is stored in plaintext**, in `~/.config/superlinear/config.json`. Restrict it: `chmod 600 ~/.config/superlinear/config.json`. The key is never logged and never leaves the machine except as an `Authorization` header to `api.linear.app`.
- **The daemon opens pull requests on its own.** Require review before merge on any repository it touches.
- **A merge removes the worktree.** Once an issue's pull request merges, `work finish` deletes its worktree and force-deletes its local branch. Do not keep work you want in a worktree the daemon created.

## License

Apache License 2.0. See [LICENSE](LICENSE).
