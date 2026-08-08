# superlinear

A macOS launchd daemon that watches [Linear](https://linear.app) for new issues and starts an autonomous [Claude Code](https://claude.com/claude-code) agent for each one.

For every new issue, the daemon creates a git worktree on the issue's branch and runs an agent that plans the work, implements it, commits, and opens a pull request — without a human in the loop.

## Status

This is a personal tool, published as a reference. **It does not run out of the box.** It shells out to a `work` fish function and to Claude Code slash commands that live in the author's dotfiles, not in this repository. See [External dependencies](#external-dependencies).

Read it as a worked example of wiring an issue tracker to an autonomous coding agent. Expect to replace the glue layer with your own.

## How it works

1. `launchd` starts the binary at login and restarts it if it exits.
2. Each configured workspace polls on its own loop, concurrently.
3. Each poll queries the Linear GraphQL API for issues created since the last poll, in the `backlog` or `unstarted` state, optionally filtered by team. Results are paginated 50 at a time.
4. Issue IDs already recorded in the state file are discarded, so an issue is processed once.
5. Each remaining issue is processed concurrently. The daemon writes a fixed prompt to a temporary file, then runs, in the repository directory:

   ```
   work start --headless --prompt-file <prompt> --log-file <log> <issue-branch-name>
   ```

   This creates a worktree at `worktrees/<branch>`, runs `make init`, and pipes the prompt into `claude -p`.
6. The issue ID is written to the state file, which is saved atomically.

The prompt instructs the agent to run `/start`, implement the change, run `/commit`, then run `/pr --autonomous` to open a PR and monitor CI. The agent is told not to pause for confirmation.

Branch names come from Linear's own `branchName` field, so the branch matches what the Linear UI shows and Linear links the PR to the issue automatically.

## Requirements

- macOS 14 or later
- Swift 6 toolchain
- [fish](https://fishshell.com) shell
- [Claude Code](https://claude.com/claude-code) (`claude` on your `PATH`)
- A Linear API key
- `tmux`, if you want `make reset` to clean up leftover sessions

### External dependencies

These are **not** in this repository. Without them the daemon polls correctly but fails at the point it starts an agent.

| Dependency | What it must do |
| --- | --- |
| `work start` fish function | Accept `--headless --prompt-file <path> --log-file <path> <branch>`. Create a git worktree, prepare it, and pipe the prompt file into `claude -p`. |
| `/start` slash command | Read the Linear issue, write a plan, move the issue to In Progress. |
| `/commit` slash command | Stage and commit the agent's work. |
| `/pr --autonomous` slash command | Open a PR without a browser, then watch CI and answer review comments. |

To adapt this, either supply your own `work` function with the same interface, or edit the command string in `Sources/superlinear/IssueProcessor.swift`.

## Install

```sh
make config   # write an example config, then open it in $EDITOR
make load     # build, install, render the LaunchAgent, and start it
```

`make load` renders `LaunchAgents/com.armcknight.superlinear.plist.template` into `~/Library/LaunchAgents/`, substituting your `$HOME`. Edit the template, not the installed copy — `make reload` overwrites the installed copy.

## Configuration

`~/.config/superlinear/config.json`:

```json
{
  "workspaces": [
    {
      "name": "my-workspace",
      "apiKey": "lin_api_YOUR_KEY_HERE",
      "repoPath": "~/Code/my-repo",
      "teamIds": [],
      "pollIntervalSeconds": 60
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

Each workspace entry is one Linear-account-to-repository pairing. List several to watch more than one repository.

## Make targets

| Target | Effect |
| --- | --- |
| `build` | Build the release binary. |
| `install` | Build, then copy the binary to `~/.local/bin`. |
| `load` | Install, render the LaunchAgent, and start it. |
| `unload` | Stop the daemon. |
| `reload` | `unload` then `load`. |
| `logs` | Follow the daemon log. |
| `config` | Create the example config if absent, then open it. |
| `status` | Show whether launchd is running the daemon. |
| `reset` | Delete state and per-issue logs, and kill leftover `superlinear_*` tmux sessions. Every issue is reprocessed on the next poll. |

## Files

| Path | Contents |
| --- | --- |
| `~/.config/superlinear/config.json` | Configuration, including API keys. |
| `~/.local/share/superlinear/state.json` | Last poll time and processed issue IDs, per workspace. |
| `~/.local/share/superlinear/daemon.log` | Daemon output. |
| `~/.local/share/superlinear/logs/<ISSUE-ID>.log` | Agent output for one issue. |

Per-issue logs are written only when the agent exits. `claude -p` buffers its output, so following the file during a run shows nothing.

## Usage

```
superlinear [--config <path>] [--help]
```

Run it directly to test a configuration without installing a LaunchAgent. `--config` overrides the default path.

## Security

Read this before you run the daemon.

- **The agent runs with permission checks disabled.** `work start --headless` invokes `claude -p --dangerously-skip-permissions`. The agent executes commands in your repository without asking. Point it only at repositories where that is acceptable, and only at Linear teams whose issues you trust.
- **Anyone who can file an issue controls the prompt.** Issue titles and bodies reach an agent that has a shell. Treat write access to a watched Linear team as equivalent to shell access.
- **The API key is stored in plaintext**, in `~/.config/superlinear/config.json`. Restrict it: `chmod 600 ~/.config/superlinear/config.json`. The key is never logged and never leaves the machine except as an `Authorization` header to `api.linear.app`.
- **The daemon opens pull requests on its own.** Require review before merge on any repository it touches.

## License

Apache License 2.0. See [LICENSE](LICENSE).
