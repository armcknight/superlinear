# Configuration

The config is `~/.config/superlinear/config.json`. `make config` creates it from the included example and opens it in your editor. It holds your Linear API keys, so it is never tracked in git. `--config <path>` on any command reads another file.

This is a config with every key set, each to its default where it has one:

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
      "selection": "new",
      "readyStates": ["unstarted"],
      "humanLabels": ["Needs human", "Spike"],
      "autonomy": { "addRelation": "auto" },
      "proposalExpiryDays": 7,
      "planning": { "enabled": false },
      "stacking": true,
      "maxStackDepth": 3
    }
  ]
}
```

Only `workspaces`, and each workspace's `name`, `apiKey` and `repoPath`, are required. A key left out has its default.

<a id="top-level-keys"></a>
## Top-level keys

| Key | Default | Example | Description |
| --- | --- | --- | --- |
| <a id="workspaces"></a>`workspaces` | required | `"workspaces": [{ … }]` | The workspaces to watch, at least one: see [Workspace keys](#workspace-keys). |
| <a id="max-concurrent-agents"></a>`maxConcurrentAgents` | `3` | `"maxConcurrentAgents": 5` | How many agents run at once, across all workspaces. Other issues wait in a queue, oldest first. An interrupted agent keeps its place, so it resumes before newer issues start. At least `1`. Planning jobs and comment answers do not count. |

<a id="workspace-keys"></a>
## Workspace keys

Each workspace pairs one Linear workspace with one repository. List several to watch more than one.

| Key | Default | Example | Description |
| --- | --- | --- | --- |
| <a id="name"></a>`name` | required | `"name": "statustician"` | The name in logs and `superlinear status`, and the key of its state. |
| <a id="api-key"></a>`apiKey` | required | `"apiKey": "lin_api_…"` | A Linear personal API key for the workspace. Claude sessions get it too: see [the Linear key](lifecycle.md#linear-key). |
| <a id="repo-path"></a>`repoPath` | required | `"repoPath": "~/Code/statustician"` | The repository agents work in. `~` is expanded. |
| <a id="team-ids"></a>`teamIds` | `[]` | `"teamIds": ["210bd4b4-545d-459e-9e58-4207281ca011"]` | The Linear team IDs to watch. Empty means every team in the workspace. |
| <a id="poll-interval-seconds"></a>`pollIntervalSeconds` | `60` | `"pollIntervalSeconds": 120` | Seconds between polls. |
| <a id="selection"></a>`selection` | `"new"` | `"selection": "ready"` | Which issues start agents: `"new"`, those created since the last poll, or `"ready"`, every issue in `readyStates`. See [Selection](lifecycle.md#selection). |
| <a id="ready-states"></a>`readyStates` | `["unstarted"]` | `"readyStates": ["unstarted", "backlog"]` | In `ready` mode, the Linear state types that mean "build this": any of `triage`, `backlog`, `unstarted`, `started`, `completed`, `canceled` and `duplicate`, usually `unstarted` (Todo). A state name such as `"Todo"` is an error. |
| <a id="human-labels"></a>`humanLabels` | `["Needs human", "Spike"]` | `"humanLabels": ["Needs human"]` | Labels that keep an issue for a person: no agent starts on it. Matched in any case. See [The ready gate](lifecycle.md#ready-gate). |
| <a id="autonomy"></a>`autonomy` | `addRelation` is `"auto"`, the rest `"review"` | `"autonomy": { "createIssue": "auto" }` | The trust level of each kind of proposal. See [below](#autonomy-levels). |
| <a id="proposal-expiry-days"></a>`proposalExpiryDays` | `7` | `"proposalExpiryDays": 14` | Days after which a proposal that waits in Linear with no answer expires, counted from when it was [put in Linear](planning.md#standup). At least `1`. |
| <a id="planning"></a>`planning` | `{ "enabled": false }` | `"planning": { "enabled": true }` | The [planning job](planning.md#daily-planning). See [below](#planning-keys). |
| <a id="stacking"></a>`stacking` | `true` | `"stacking": false` | Whether an issue whose one open blocker has an agent's pull request, not a draft, with CI passing, starts on top of that pull request. See [Stacks](lifecycle.md#stacks). |
| <a id="max-stack-depth"></a>`maxStackDepth` | `3` | `"maxStackDepth": 2` | How many pull requests one stack may hold, the bottom one included. An issue that would make a stack deeper waits for a merge. At least `1`, which stacks nothing. |

<a id="autonomy-levels"></a>
### `autonomy`

A map from a kind of [proposal](planning.md#proposal-kinds) to its trust level. Kinds left out keep their defaults.

```json
"autonomy": {
  "createIssue": "review",
  "editIssue": "review",
  "closeIssue": "review",
  "addRelation": "auto",
  "promoteIssue": "review",
  "changeSpec": "review",
  "postProjectUpdate": "never"
}
```

| Level | What happens |
| --- | --- |
| `"auto"` | Applied at once. It is still listed in `superlinear status` and the [audit log](planning.md#audit-log). |
| `"review"` | [Put in Linear](planning.md#standup) for you to answer. The default for every kind but `addRelation`. |
| `"never"` | Not proposed at all. |

An unknown kind or level is an error, so a misspelt kind cannot leave its default in force unseen. `"standup"`, the old name of `"review"`, is still read.

<a id="planning-keys"></a>
### `planning`

```json
"planning": {
  "enabled": true,
  "specDocumentURL": "https://linear.app/statustician/document/statustician-spec-274852337e82"
}
```

| Key | Default | Description |
| --- | --- | --- |
| `enabled` | `false` | Turns on the [planning job](planning.md#daily-planning) for the workspace. `superlinear plan --workspace <name>` runs it even when this is `false`. |
| `specDocumentURL` | none | The Linear document with the project's spec. The planning job reads it and may propose changes to it, and your [comments on it](planning.md#spec-comments) are answered. |

<a id="config-changes"></a>
## Changing the config

Edits take effect on their own. The daemon reads the file every five seconds. When it changes to a config that loads, the daemon exits and launchd restarts it on the new one; agents in flight carry on. An edit that does not load, such as invalid JSON or a missing key, is logged once and ignored until it is fixed. A daemon run in the foreground only logs that it needs a restart.

<a id="files"></a>
## Files

| Path | Contents |
| --- | --- |
| `~/.config/superlinear/config.json` | The config, with the API keys. |
| `~/.local/share/superlinear/state.json` | For each workspace: the last poll, processed issues, runs in flight, issues awaiting their pull request's merge (with the pull request each is stacked on), blocked and human-labeled issues, proposals and where they wait in Linear, the comments answered, 30 days of what the daemon did, and the last 30 planning jobs. |
| `~/.local/share/superlinear/planning.json` | The jobs that `superlinear plan` ran and the proposals they made, for the daemon to take in. |
| `~/.local/share/superlinear/roadmap.json` | The latest [roadmap](planning.md#roadmap) of each set of workspaces, and the roadmap sessions running now. |
| `~/.local/share/superlinear/audit/<workspace>.jsonl` | Each change superlinear made in Linear, with its proposal and Linear's response. |
| `~/.local/share/superlinear/daemon.lock` | Held by the running daemon, so that a second one exits. |
| `~/.local/share/superlinear/runs/` | Each run's prompt, and its exit status once it ends. A planning job also keeps its context and its proposals file until they are taken in, and a roadmap session its context, its scripts and its roadmap file until it ends. |
| `~/.local/share/superlinear/daemon.log` | The daemon's output. |
| `~/.local/share/superlinear/logs/<ISSUE-ID>.log` | An issue's agent output. A resumed run appends to it. |
| `~/.local/share/superlinear/logs/<ISSUE-ID>.work.log` | The output of `work` for an issue: worktree setup, teardown after the merge, and errors. |
| `~/.local/share/superlinear/logs/planning-<workspace>.log` | The output of the workspace's planning sessions. |
| `~/.local/share/superlinear/logs/roadmap.log` | The output of the roadmap sessions. |
| `~/.local/share/superlinear/logs/comments-<workspace>.log` | The output of the sessions that answer comments. |
| `<worktree>/.superlinear/followups.json` | Work an agent found outside its issue, read when it exits. See [Follow-ups from agents](planning.md#follow-ups). |

Agent logs are written only when the agent exits: `claude -p` keeps its output until then, so a log shows nothing while its agent runs.
