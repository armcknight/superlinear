# superlinear

A macOS launchd daemon that watches [Linear](https://linear.app) for new issues and starts an autonomous [Claude Code](https://claude.com/claude-code) agent for each one.

For every new issue, the daemon creates a git worktree on the issue's branch and runs an agent that plans the work, implements it, commits, and opens a pull request — without a human in the loop. See [workr](https://github.com/armcknight/workr) for more info, as this is what it uses by default.

## Status

This is a personal tool, published as a reference. It is opinionated about how work gets done, but everything it depends on is now installable — see [External dependencies](#external-dependencies).

## How it works

1. **Selection.** Each configured workspace polls Linear on its own loop for the issues an agent may start on: those created since the last poll, or those moved to Todo. See [Selection](docs/lifecycle.md#selection).
2. **The ready gate.** Issues that another open issue blocks, and issues with a human label such as "Needs human", wait. With `stacking` on, an issue whose one unmerged blocker has an open pull request starts on top of it instead. See [The ready gate](docs/lifecycle.md#ready-gate) and [Stacks](docs/lifecycle.md#stacks).
3. **The agent.** Each ready issue is queued, and up to `maxConcurrentAgents` agents run at once. Each runs `claude -p` in its own worktree, with a prompt to plan, implement, commit, open a pull request and see CI through. See [The agent](docs/lifecycle.md#agent).
4. **Reviews and conflicts.** Review the pull request, or let it conflict with its base branch, and an agent comes back to the same branch to address it. See [Reviews](docs/lifecycle.md#reviews) and [Conflicts](docs/lifecycle.md#conflicts).
5. **The merge.** You merge; superlinear never does. The issue is then marked done and its worktree removed. See [The merge and completion](docs/lifecycle.md#merge).
6. **Planning.** superlinear proposes changes to the plan in Linear, where you accept or reject them, or lets them through on their own by trust level. See [Planning](docs/planning.md).

When the Claude usage limit or the GitHub Actions spending limit stops work, superlinear pauses what cannot succeed and resumes when the limit is lifted. See [Usage and spending limits](docs/lifecycle.md#limits).

Agents outlive the daemon, so restarts, upgrades and config edits do not stop work in flight. See [Operations](docs/operations.md).

## The guide

The details are in [the superlinear guide](docs/index.md):

- [The life of an issue](docs/lifecycle.md): selection and the ready gate, the agent, the pull request, reviews, conflicts, stacks, the merge, completion.
- [Planning](docs/planning.md): proposals and trust levels, the planning job, follow-ups from agents, reviewing proposals in Linear, project updates.
- [Bootstrap](docs/bootstrap.md): components, manifests, secrets, Needs human steps, `bootstrap --check`.
- [Builds](docs/builds.md): CI, staging and TestFlight builds, build numbers, the release rule, TestFlight feedback.
- [Configuration](docs/configuration.md): every config key, and the files superlinear reads and writes.
- [Operations](docs/operations.md): installing and running the daemon, `superlinear status` and `stats`, make targets, releases.

Projects that superlinear works on link to the guide from their READMEs. Link to a section by its stable anchor, listed in [Anchors](docs/anchors.md).

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

Then set up a workspace: see [Configuration](docs/configuration.md). For the launch agent, upgrades and the other commands, see [Operations](docs/operations.md).

## Usage

```
superlinear [--config <path>]
superlinear install
superlinear uninstall
superlinear status [--since <duration>] [--status <names>] [--workspace <names>] [--config <path>]
superlinear stats [--config <path>]
superlinear proposals [--workspace <name>] [--config <path>]
superlinear plan [--workspace <name>] [--config <path>]
superlinear resume
```

With no subcommand it runs the daemon in the foreground. See [Usage](docs/operations.md#usage), [Status](docs/operations.md#status), [Stats](docs/operations.md#stats), [The audit log](docs/planning.md#audit-log) for `proposals`, [The planning job](docs/planning.md#daily-planning) for `plan`, and [Usage and spending limits](docs/lifecycle.md#limits) for `resume`.

## Security

Read this before you run the daemon.

- **The agent runs with permission checks disabled.** `work start --headless` invokes `claude -p --dangerously-skip-permissions`. The agent executes commands in your repository without asking. Point it only at repositories where that is acceptable, and only at Linear teams whose issues you trust.
- **Anyone who can file an issue controls the prompt.** Issue titles and bodies reach an agent that has a shell. Treat write access to a watched Linear team as equivalent to shell access.
- **The API key is stored in plaintext**, in `~/.config/superlinear/config.json`. Restrict it: `chmod 600 ~/.config/superlinear/config.json`. The key is never logged and never leaves the machine except as an `Authorization` header to `api.linear.app`.
- **The daemon opens pull requests on its own.** Require review before merge on any repository it touches.
- **A merge removes the worktree.** Once an issue's pull request merges, `work finish` deletes its worktree and force-deletes its local branch. Do not keep work you want in a worktree the daemon created.

## License

Apache License 2.0. See [LICENSE](LICENSE).
