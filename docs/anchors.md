# Anchors

Other repositories link to these sections, so their addresses must not change. Each section has an explicit anchor, `<a id="…"></a>`, above its heading, so a heading can be renamed without breaking a link. To link to a section from another repository, use its anchor below.

Rules:

- Do not rename or remove an anchor. When a section moves, move its anchor with it. When a section goes away, keep its anchor at the section that replaces it.
- Each new section that other repositories may link to gets an anchor, and a line here.
- `make check-docs`, which CI runs, fails when a link or anchor does not resolve, or when an anchor in `docs/` is not listed here.

## [The life of an issue](lifecycle.md)

| Anchor | Section |
| --- | --- |
| [`lifecycle.md#overview`](lifecycle.md#overview) | Overview: from issue to merge, step by step. |
| [`lifecycle.md#selection`](lifecycle.md#selection) | Selection: which issues superlinear picks, in `new` and `ready` mode. |
| [`lifecycle.md#first-poll`](lifecycle.md#first-poll) | The first poll of a new workspace. |
| [`lifecycle.md#github-issues`](lifecycle.md#github-issues) | GitHub issues: issues you open or comment `/superlinear-do` on. |
| [`lifecycle.md#ready-gate`](lifecycle.md#ready-gate) | The ready gate: blockers, human labels and holds. |
| [`lifecycle.md#agent`](lifecycle.md#agent) | The agent: the queue, the worktree and the prompt. |
| [`lifecycle.md#linear-key`](lifecycle.md#linear-key) | The workspace's Linear key in every Claude session. |
| [`lifecycle.md#pull-request`](lifecycle.md#pull-request) | The pull request, and how the daemon follows it. |
| [`lifecycle.md#reviews`](lifecycle.md#reviews) | Reviews that bring an agent back. |
| [`lifecycle.md#linear-comments`](lifecycle.md#linear-comments) | Comments in Linear that bring an agent back. |
| [`lifecycle.md#conflicts`](lifecycle.md#conflicts) | Conflicts with the base branch. |
| [`lifecycle.md#stacks`](lifecycle.md#stacks) | Stacks: dependent work on open pull requests. |
| [`lifecycle.md#stackable`](lifecycle.md#stackable) | Which issues stack. |
| [`lifecycle.md#no-native-stacks`](lifecycle.md#no-native-stacks) | Why GitHub's native stacks are not used. |
| [`lifecycle.md#never-rewritten`](lifecycle.md#never-rewritten) | Reviewed pull requests are never rewritten. |
| [`lifecycle.md#keeping-stacks-current`](lifecycle.md#keeping-stacks-current) | Keeping a stack current. |
| [`lifecycle.md#limits`](lifecycle.md#limits) | Usage and spending limits: pausing and resuming. |
| [`lifecycle.md#claude-usage-limit`](lifecycle.md#claude-usage-limit) | The Claude usage limit, and `superlinear resume`. |
| [`lifecycle.md#spending-limit`](lifecycle.md#spending-limit) | The GitHub Actions spending limit. |
| [`lifecycle.md#merge`](lifecycle.md#merge) | The merge and completion. |
| [`lifecycle.md#started-issue-sweep`](lifecycle.md#started-issue-sweep) | Started issues the daemon does not follow. |
| [`lifecycle.md#after-merge`](lifecycle.md#after-merge) | What follows a merge. |

## [Planning](planning.md)

| Anchor | Section |
| --- | --- |
| [`planning.md#proposals`](planning.md#proposals) | Proposals and trust levels. |
| [`planning.md#trust-levels`](planning.md#trust-levels) | The trust levels: `auto`, `review` and `never`. |
| [`planning.md#proposal-kinds`](planning.md#proposal-kinds) | The kinds of proposal and their default trust levels. |
| [`planning.md#proposal-rules`](planning.md#proposal-rules) | The rules for applying a proposal. |
| [`planning.md#duplicate-check`](planning.md#duplicate-check) | Duplicate issues: how a new issue is compared with open issues and proposals, and merged. |
| [`planning.md#audit-log`](planning.md#audit-log) | The audit log, and `superlinear proposals`. |
| [`planning.md#daily-planning`](planning.md#daily-planning) | The planning job. |
| [`planning.md#planning-model`](planning.md#planning-model) | The model for planning and answers: Fable, and Opus at Fable's limit. |
| [`planning.md#follow-ups`](planning.md#follow-ups) | Follow-ups from agents. |
| [`planning.md#standup`](planning.md#standup) | Reviewing proposals in Linear. The anchor keeps the name of the command this replaced. |
| [`planning.md#proposal-comments`](planning.md#proposal-comments) | Questions and requests on proposals, answered in Linear. |
| [`planning.md#spec-comments`](planning.md#spec-comments) | Comments on the spec document. |
| [`planning.md#standup-needs-human`](planning.md#standup-needs-human) | Signing off Needs human issues in Linear. |
| [`planning.md#project-updates`](planning.md#project-updates) | Project updates. |

## [Bootstrap](bootstrap.md)

| Anchor | Section |
| --- | --- |
| [`bootstrap.md#components`](bootstrap.md#components) | Components. |
| [`bootstrap.md#manifests`](bootstrap.md#manifests) | Component manifests. |
| [`bootstrap.md#secrets`](bootstrap.md#secrets) | Secrets and where they come from. |
| [`bootstrap.md#needs-human-steps`](bootstrap.md#needs-human-steps) | Steps that need a person. |
| [`bootstrap.md#bootstrap-check`](bootstrap.md#bootstrap-check) | `bootstrap --check`. |

## [Builds](builds.md)

| Anchor | Section |
| --- | --- |
| [`builds.md#ci`](builds.md#ci) | CI. |
| [`builds.md#testflight`](builds.md#testflight) | TestFlight builds: staging builds on demand, and TestFlight uploads by hand with `make deploy-beta`. |
| [`builds.md#nightly-testflight`](builds.md#nightly-testflight) | The old name of `builds.md#testflight`, kept for links to it. |
| [`builds.md#build-numbers`](builds.md#build-numbers) | Build numbers. |
| [`builds.md#release-rule`](builds.md#release-rule) | The release rule: agents never release. |
| [`builds.md#testflight-feedback`](builds.md#testflight-feedback) | TestFlight feedback. |

## [Configuration](configuration.md)

| Anchor | Section |
| --- | --- |
| [`configuration.md#top-level-keys`](configuration.md#top-level-keys) | Top-level keys. |
| [`configuration.md#workspaces`](configuration.md#workspaces) | `workspaces` |
| [`configuration.md#max-concurrent-agents`](configuration.md#max-concurrent-agents) | `maxConcurrentAgents` |
| [`configuration.md#workspace-keys`](configuration.md#workspace-keys) | Workspace keys. |
| [`configuration.md#name`](configuration.md#name) | `name` |
| [`configuration.md#api-key`](configuration.md#api-key) | `apiKey` |
| [`configuration.md#repo-path`](configuration.md#repo-path) | `repoPath` |
| [`configuration.md#team-ids`](configuration.md#team-ids) | `teamIds` |
| [`configuration.md#poll-interval-seconds`](configuration.md#poll-interval-seconds) | `pollIntervalSeconds` |
| [`configuration.md#github-issues`](configuration.md#github-issues) | `githubIssues` |
| [`configuration.md#selection`](configuration.md#selection) | `selection` |
| [`configuration.md#ready-states`](configuration.md#ready-states) | `readyStates` |
| [`configuration.md#human-labels`](configuration.md#human-labels) | `humanLabels` |
| [`configuration.md#autonomy`](configuration.md#autonomy) | `autonomy` |
| [`configuration.md#proposal-expiry-days`](configuration.md#proposal-expiry-days) | `proposalExpiryDays` |
| [`configuration.md#planning`](configuration.md#planning) | `planning` |
| [`configuration.md#stacking`](configuration.md#stacking) | `stacking` |
| [`configuration.md#max-stack-depth`](configuration.md#max-stack-depth) | `maxStackDepth` |
| [`configuration.md#autonomy-levels`](configuration.md#autonomy-levels) | The `autonomy` map and its trust levels. |
| [`configuration.md#planning-keys`](configuration.md#planning-keys) | The `planning` keys. |
| [`configuration.md#config-changes`](configuration.md#config-changes) | Changing the config. |
| [`configuration.md#files`](configuration.md#files) | The files superlinear reads and writes. |

## [Operations](operations.md)

| Anchor | Section |
| --- | --- |
| [`operations.md#install`](operations.md#install) | Installation. |
| [`operations.md#usage`](operations.md#usage) | Usage. |
| [`operations.md#restarts`](operations.md#restarts) | Restarts. |
| [`operations.md#disk-space`](operations.md#disk-space) | Disk space. |
| [`operations.md#status`](operations.md#status) | `superlinear status`. |
| [`operations.md#stats`](operations.md#stats) | `superlinear stats`. |
| [`operations.md#make-targets`](operations.md#make-targets) | Make targets. |
| [`operations.md#releasing`](operations.md#releasing) | Releasing superlinear. |
