# Configuration

```sh
make config
```

Creates `~/.config/superlinear/config.json` from the included example and opens it in your editor. The config is never tracked in git: keep your API keys local.

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
      "githubIssues": false,
      "selection": "ready",
      "readyStates": ["unstarted"],
      "humanLabels": ["Needs human", "Spike"],
      "stacking": true
    }
  ]
}
```

Each workspace entry is one Linear-account-to-repository pairing. List several to watch more than one repository.

<a id="top-level-keys"></a>
## Top-level keys

| Key | Required | Description |
| --- | --- | --- |
| <a id="workspaces"></a>`workspaces` | yes | The workspaces to watch, at least one. See [Workspace keys](#workspace-keys). |
| <a id="max-concurrent-agents"></a>`maxConcurrentAgents` | no | How many agents run at once across all workspaces. Further issues wait in a queue, kept in the state file, and start oldest first as running agents finish. An interrupted agent keeps its place, so it resumes before newer issues start. Defaults to `3`. |

<a id="workspace-keys"></a>
## Workspace keys

| Key | Required | Description |
| --- | --- | --- |
| <a id="name"></a>`name` | yes | Label for logs. Also the key under which state is stored. |
| <a id="api-key"></a>`apiKey` | yes | Linear personal API key. |
| <a id="repo-path"></a>`repoPath` | yes | Repository the agent works in. `~` is expanded. |
| <a id="team-ids"></a>`teamIds` | no | Linear team IDs to watch. Empty or absent means all teams. Defaults to `[]`. |
| <a id="poll-interval-seconds"></a>`pollIntervalSeconds` | no | Seconds between polls. Defaults to `60`. |
| <a id="github-issues"></a>`githubIssues` | no | Also work on the repository's GitHub issues that you open or comment `/superlinear-do` on. See [GitHub issues](lifecycle.md#github-issues). Defaults to `false`. |
| <a id="selection"></a>`selection` | no | `"new"` to start issues created since the last poll, or `"ready"` to start every issue in `readyStates`. See [Selection](lifecycle.md#selection). Defaults to `"new"`. |
| <a id="ready-states"></a>`readyStates` | no | Linear state types that mean "build this" in `ready` mode: any of `triage`, `backlog`, `unstarted`, `started`, `completed` and `canceled`, usually the first three. Any other value, such as a state name like `"Todo"`, is an error. Defaults to `["unstarted"]`, which is Todo. |
| <a id="human-labels"></a>`humanLabels` | no | Names of labels that keep an issue for a person: no agent starts on it. Matched in any case. See [The ready gate](lifecycle.md#ready-gate). Defaults to `["Needs human", "Spike"]`. |
| <a id="autonomy"></a>`autonomy` | no | The trust level of each kind of proposal: a map from kind to `"auto"`, `"review"` or `"never"`. Kinds left out keep their defaults. An unknown kind or level is a config error, so a misspelt kind does not leave its default in force unseen. See [Proposals and trust levels](planning.md#proposals). |
| <a id="proposal-expiry-days"></a>`proposalExpiryDays` | no | Days after which a pending proposal expires, counted from when it was [put in Linear](planning.md#standup). Defaults to `7`. |
| <a id="planning"></a>`planning` | no | Planning settings. `planning.enabled` turns on the [planning job](planning.md#daily-planning); it defaults to `false`. `planning.specDocumentURL` is the URL of the Linear document holding the project's spec, which the planning job reads and may propose changes to. |
| <a id="stacking"></a>`stacking` | no | Whether an issue whose one unmerged blocker has an open pull request from an agent, not a draft, with CI passing, starts on top of that pull request's branch, as a pull request that targets it. See [Stacks](lifecycle.md#stacks). Defaults to `true`. |
| <a id="max-stack-depth"></a>`maxStackDepth` | no | How many pull requests a stack may hold, the bottom one included; an issue that would make a stack deeper waits for a merge. At least `1`, which stacks nothing. Defaults to `3`. |

For example, to apply new issues at once and never post project updates:

```json
"autonomy": { "createIssue": "auto", "postProjectUpdate": "never" }
```

<a id="config-changes"></a>
## Changing the config

Edits take effect on their own. The daemon checks the file every five seconds; when it changes to a config that loads, the daemon exits and launchd restarts it on the new one, with agents in flight carrying on. An edit that does not load — invalid JSON, a missing key, no workspaces — is logged once and ignored until fixed. A daemon run in the foreground only logs that a restart is needed.

`--config <path>` on any command overrides the default path.

<a id="files"></a>
## Files

| Path | Contents |
| --- | --- |
| `~/.config/superlinear/config.json` | Configuration, including API keys. |
| `~/.local/share/superlinear/state.json` | Last poll time, processed issue IDs, runs in flight, issues awaiting their pull request's merge, with the pull request each is stacked on, blocked and human-labeled issues, proposals with where they wait in Linear, 30 days of what the daemon did, for `superlinear status`, and the last 30 planning jobs, per workspace. |
| `~/.local/share/superlinear/planning.json` | Per workspace, the planning jobs `superlinear plan` ran and the proposals they stored, for the daemon to take in. |
| `~/.local/share/superlinear/audit/<workspace>.jsonl` | Each change superlinear applied in Linear, with the proposal and Linear's response. |
| `~/.local/share/superlinear/daemon.lock` | Held by the running daemon, so a second one exits. |
| `~/.local/share/superlinear/runs/` | Each run's prompt, and its exit status once it ends. A planning job also keeps what it was given and the proposals file its session writes, until it is taken in. |
| `~/.local/share/superlinear/daemon.log` | Daemon output. |
| `~/.local/share/superlinear/logs/<ISSUE-ID>.log` | Agent output for one issue. A resumed run appends to it. |
| `~/.local/share/superlinear/logs/planning-<workspace>.log` | Output of the workspace's planning sessions, appended across jobs. |
| `~/.local/share/superlinear/logs/<ISSUE-ID>.work.log` | Output of `work` itself for one issue, such as worktree setup, teardown after the merge, and errors. |
| `<worktree>/.superlinear/followups.json` | Work an agent found outside its issue, read when it exits. See [Follow-ups from agents](planning.md#follow-ups). |

Per-issue logs are written only when the agent exits. `claude -p` buffers its output, so following the file during a run shows nothing.
