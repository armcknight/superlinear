# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The owner's comments on every issue of the watched teams are handled,
  not only those on proposals and on issues superlinear works on. A short
  read-only session decides whether a comment is a question, a request for
  a change, or a note that needs nothing, and the issue's state decides
  what happens: on an open issue, such as one labeled `Needs human`, a
  question gets an answer and a request changes the description; while an
  agent runs, a question gets a reply and a request waits for the next
  agent, which is never stopped; on an issue with an open pull request, a
  request goes to a review agent; on a done, canceled or duplicate issue, a
  request becomes a `createIssue` proposal linked in the reply. A note gets
  no reply. Each comment queued gets a 👀 reaction, replies on issues that
  are not proposals add the label `superlinear: replied`, and `superlinear
  status` lists the requests that wait for an agent. Comments from other
  users, and on teams not watched, are logged once. The first poll after
  the upgrade handles the comments the old rule skipped.

- `superlinear roadmap [--workspace <names>] [--json]` shows the
  ordered plan across every workspace: a table of steps, each with its
  issues and who does it, an agent or you; the waits between workspaces,
  read from identifiers of another workspace's team in descriptions; what
  you must do now, with the step it unblocks; and notes for triage. A
  read-only Claude session on the planning model orders the work;
  superlinear makes sure each open issue is in one step, and that each issue
  with a human label, in Triage, with a proposal waiting for you, or with a
  pull request waiting on you, is yours and listed under "Now, for you". The
  command only shows the roadmap the daemon built; it builds nothing. The
  daemon builds it when it starts and has none, and the planning job
  rebuilds it at its end. `superlinear status` begins with when it was last
  built and how many actions it lists.

- Agents, the planning job and the sessions that answer the owner's comments
  get the workspace's Linear key in `LINCTL_API_KEY`,
  in place of any key in the daemon's environment, so `linctl` reads the
  right workspace without an `.envrc`.
- The planning job and the comment answer sessions may read the workspace's
  Linear issues with `linctl issue get`, `list` and `search`, and no `linctl`
  command that writes. A comment answer's prompt has the issues of the
  workspace that the comment or the proposal names, so "is this a duplicate
  of TEM-22?" needs no tool call.
- A new issue is compared with the open issues and proposals by an agent,
  for the same work in other words, not by its title alone. This replaces
  the close-title match. The candidates are the open issues that Linear's
  search finds for its title, and the team's pending and rejected proposed
  issues. A duplicate is merged, not dropped: what it adds to an open issue
  becomes an `editIssue` proposal for that issue, and what it adds to a
  pending proposal goes into it. A new issue that may be a duplicate is
  proposed for review, with a comment on it that links each candidate. Mark
  it a duplicate of one in Linear, and superlinear rejects it, names that
  issue in the reason, and proposes to add its text to that issue.
- The planning job and the sessions that answer the owner's comments run
  on Fable. When Fable's own usage limit is reached, they run on Opus until
  it resets: the stopped planning job resumes in its session on Opus, and a
  stopped comment answer runs again on Opus. The daemon keeps the reset time
  in the state file and uses Fable again after it. `superlinear status`
  shows the limit while it holds.
- `superlinear stats` shows how many sessions answered the owner's comments,
  and the tokens, cache reads and agent time they used.
- `superlinear stats` shows how many planning jobs ran, and the tokens, cache
  reads and agent time they used.
- superlinear answers the owner's comments in Linear. A question or a
  request on a pending proposal, on the proposed issue or in the thread of
  the proposal's comment, gets a read-only Claude session. Its answer is
  posted as a reply that starts with `*Written by superlinear.*`. A request
  for a change can also edit the proposal, which still waits for an answer.
  The reply keeps the label `superlinear: proposed` on the issue. A comment
  on an issue with an open pull request queues a review agent with the
  comment. A comment on a started issue whose agent ended without a pull
  request queues a new agent. A comment on the spec document is answered
  the same way, and a request to change the spec becomes a `changeSpec`
  proposal. An agent's first prompt has the issue's comments. Each comment
  is handled once for each version of its text. At the first poll after the
  upgrade, only comments made after the issue's last proposal or agent
  start count.
- An agent answers the comments you write in a pull request's
  conversation, not only your reviews. A comment from the user `gh` is
  signed in as, made after the issue's last agent started, queues the same
  review agent; a comment and a review together queue one agent. Its
  prompt lists the reviews and comments that queued it, with a link to
  each comment. `superlinear status` shows "new feedback" on a pull request
  whose review or comment waits for an agent.
- Proposals are reviewed in Linear. A `createIssue` proposal is created at
  once in the team's Triage state, labeled `superlinear` and `superlinear:
  proposed`, with its reason and source; accepting it from Triage approves
  it, declining it rejects it, so it is not proposed again. A team with
  Triage off has it turned on when the API key may, or takes the issue in
  Backlog, where moving it or removing the label approves it. An edit, a
  closure, a relation or a promotion is a comment on its issue, with the
  reason, source and diff; 👍 from the API key's user applies it, 👎
  rejects it, and the comment's first line then says which, with the time.
  A spec change is a Triage issue labeled `superlinear: spec` with the
  diff, applied to the document when accepted. A proposal whose target
  changed since is asked again in a new comment. Expiry counts from when
  the proposal was put in Linear; an expired comment says so, an expired
  Triage issue is canceled with a note. At the first poll after the
  upgrade, every pending proposal in the state file goes to Linear. The
  trust level is now `review`; `standup` in a config still reads as it.
- `superlinear status` takes over what the standup still had: "Waiting on
  you" orders the open pull requests by the work they hold back, the bottom
  of each stack first, and counts the proposals waiting in Linear with a
  link to each; "Done autonomously" lists what the daemon did since
  `--since` (default `24h`): agents started, finished, failed or stopped,
  reviews addressed, conflicts resolved, issues completed, proposals
  applied with `auto`; "Risks" lists the active pauses, CI failing on the
  default branch and a low GitHub rate limit.
- Stacks: dependent work on open pull requests. With the workspace key
  `stacking`, on by default, an issue whose one unmerged blocker has an open pull request
  from an agent, not a draft, with CI passing, starts on top of it: its
  branch is created from the blocker's branch, and its pull request
  targets that branch, within `maxStackDepth` pull requests, 3 by default.
  GitHub's native stacks are not used, as they rebase and force-push the
  pull requests above a merged one: a watched pull request is never
  rewritten. Each poll keeps stacks current, bottom-up: a lower branch
  that moved is merged into the pull requests above it with a merge commit
  and pushed, a conflict goes to a conflict agent, a merged lower pull
  request has the next base retargeted and merged in, and one closed
  without a merge makes the pull requests above it drafts, their issues
  back to Blocked, for a decision. `superlinear status`
  lists each pull request under the one it stacks on.
- `superlinear status --status <names>` shows only the named sections,
  comma-separated or repeated: `awaiting-review` (what waits on you),
  `drafts`, `running`, `addressing-review`, `resolving-conflicts`,
  `interrupted`, `queued`, `blocked`, `needs-human`, `open-pull-requests`,
  `merged`, `no-pull-request`, `completed`, `closed`, `done`, `risks` and
  `stale`. `--workspace <names>` shows only the named workspaces,
  comma-separated or repeated, instead of every configured one.
- Pause and resume at the provider limits. When a Claude session ends at
  the Claude plan's usage limit, every Claude session pauses, in all
  workspaces, until the reset time in the message, or for an hour when it
  gives none. The stopped session is recorded as interrupted, keeping its
  session ID and using no retry, and resumes first when the pause ends.
  Queued issues keep their places, and GitHub work goes on. Every 15
  minutes a one-word session with no tools checks whether the limit was
  lifted early; `superlinear resume`, which the standup offers too, ends
  the pause at once. In private repositories, CI runs that the GitHub
  Actions spending limit kept from starting are told apart from failures by
  their annotations, shown as "CI not started: GitHub spending limit", and
  not given to agents to fix; one is rerun each hour, and once its jobs
  start, or those of a run you reran by hand, the others are rerun, newest
  first, one per branch. `superlinear
  status` shows a line for each active pause, the standup lists them under
  Risks, and a macOS notification marks when each starts and ends.
- The planning job. For each workspace with `planning.enabled`, a poll
  that finds the default branch moved since the last job, or an issue
  completed since it ended, runs a headless Claude session in the default
  branch's worktree, given why it runs, the commits merged since the last
  job with their pull requests and issues, the issues completed since,
  the watched teams' open issues with their projects, milestones,
  relations and labels, and the spec document. The session writes
  proposals to a JSON file: closures of issues the changes did, edits of
  managed blocks, relations and duplicates, new issues for gaps, spec
  changes and promotions to Todo. The daemon checks them against what the
  session was given, stores them through the proposal store's rules, and
  records the job's token use. Like an agent, a job survives a daemon
  restart. `superlinear plan [--workspace W]` runs one now, and the
  standup offers to when something changed since the last, with that
  job's token use.
- The [`armcknight/templatr`](https://github.com/armcknight/templatr)
  repository: the component manifest format
  (`component.toml`) with its JSON Schema and a validator, and the first
  component, `apple-app`, with shared `test` and `beta` fastlane lanes for
  iOS, tvOS and macOS and a `stage` lane for iOS, a Makefile fragment whose
  `deploy-beta` target cuts a release candidate and uploads it to TestFlight
  by hand, and a scaffold whose workflows call `ios-ci.yml`, `ota-refresh.yml`
  and `ota-cleanup.yml` from `armcknight/workflows` for pull request tests and
  on-demand staging builds. A manifest's secret can be `local`: kept in the
  owner's Keychain, never set as a GitHub secret. CI validates the manifests
  against the guide's `docs/anchors.md` and checks the links. The guide's
  components, manifests, TestFlight builds and build numbers sections are
  filled in.

- The superlinear guide, in `docs/`: the life of an issue, planning,
  bootstrap, builds, configuration and operations. The README is now an
  overview that links to it. Each section that other repositories link to
  has a stable anchor, listed in `docs/anchors.md`. `make check-docs`, which
  CI runs, checks that the relative links and anchors resolve.

- `superlinear standup`, an interactive review in the terminal: what
  superlinear did since the last standup; pull requests waiting on you,
  those holding back the most work first, by stack; pending proposals to
  approve, edit in `$EDITOR`, reject with a reason, or defer; issues that
  need a human, those blocking the most first, to mark done or record a
  decision on; the plan for today, to hold, reorder, or promote from the
  backlog; and risks: CI failing on the default branch
  and a low GitHub rate limit. Decisions are applied at the end and
  recorded in `~/.local/share/superlinear/standup.json`, which the daemon
  reads at each poll. `--print` shows the main sections without prompts. A
  workspace's `planning.specDocumentURL` names a document that decisions
  are added to. `superlinear status` shows the last standup and what waits
  for one.

- A store for proposed changes to Linear, with trust levels, provenance and
  an audit log. Each proposal — a new issue, an edit, a closure, a relation,
  a promotion from Backlog to Todo, a spec change or a project update — is
  kept in the state file with its target, change, reason, source and
  status. The workspace's `autonomy` config sets each kind to `auto`,
  applied at once, `standup`, kept for review, or `never`; only relations
  are `auto` by default. Pending proposals expire after
  `proposalExpiryDays`, 7 by default. Issues superlinear creates get the
  `superlinear` label and a "Source" line; in other issues it edits only a
  managed block between `<!-- superlinear -->` markers, never one labelled
  `superlinear: hands off`, and never one changed since the proposal. A new
  issue like an open one, or a change rejected before, is not proposed
  again. Each applied change goes in
  `~/.local/share/superlinear/audit/<workspace>.jsonl`, and `superlinear
  proposals [--workspace W]` lists pending and recent proposals.
- Agents' follow-ups become proposals. Every agent prompt tells the agent
  to leave bugs and missing work outside its issue in
  `.superlinear/followups.json` in its worktree, which git ignores, rather
  than fix them or create Linear issues. When the agent exits, each entry
  becomes a `createIssue` proposal, or an `addRelation` one when an open
  issue matches, with the agent's session, issue and pull request as its
  source. A malformed file is logged and kept. Failing CI on the default
  branch makes one proposal per failing workflow, and `TODO` or `FIXME`
  lines added by a merged pull request make one each.
- A `selection` key per workspace: `"new"`, the default, starts agents for
  issues created since the last poll, as before; `"ready"` starts them for
  every open issue in one of the workspace's `readyStates` (default
  `["unstarted"]`, which is Todo; a value that is not a Linear state type is
  a config error), whenever it was created, urgent first and
  no priority last, then by project, milestone and issue sort order. In
  `ready` mode, an issue moves to its team's first started state when its
  agent starts, so moving an issue from Backlog to Todo is how you say "build
  this".
- In both modes, an issue that another open issue blocks waits until its last
  blocker is completed or canceled, and an issue with a label in the new
  `humanLabels` key (default `["Needs human", "Spike"]`) never starts an
  agent. Each poll checks the waiting issues again. `superlinear status`
  lists them under "Blocked", with their blockers, and "Needs human", with
  their labels.

- `superlinear status` ends with its own version and binary, and the
  daemon's pid, version, binary and start time, or that the daemon is not
  running. It warns when the daemon's binary was replaced after the daemon
  started. Then, under "Polls", each workspace shows when its last poll
  ended, whether it failed, and when the next one is due. The daemon writes `daemon.json` when it starts,
  and the poll times into the state file.

- A daemon running a local build restarts within a minute of `make install`
  replacing its binary, as one running the cask does after `brew upgrade`.

- An open pull request that conflicts with its base branch brings an agent
  back to merge the base branch in. Each poll reads GitHub's mergeable state
  for the pull requests of issues awaiting their merge. For one that
  conflicts, an agent in the same worktree merges `origin/<base>`, resolves
  the conflicts, tests, commits the merge, pushes and sees CI through,
  without rebasing or force-pushing. A review that needs an agent goes first.
  Each pair of branch and base heads gets one agent, so a conflict that an
  agent could not resolve waits until either branch moves. `superlinear
  status` lists these agents under "Resolving conflicts", and marks
  conflicting pull requests under "Awaiting review".

- `superlinear status` lists stale branches and worktrees per workspace:
  local branches whose pull request merged or closed, and worktrees under
  `worktrees/` whose agent ended without opening one. Each shows whether it
  has a worktree, its last commit's age, and the commits removing it would
  lose. The summary counts them.

- Your reviews on an agent's pull request bring an agent back to address
  them. Each poll reads the reviews on the open pull request of every issue
  awaiting its merge, and a review from the GitHub user `gh` is signed in as,
  submitted after the issue's last agent started, queues a new agent in the
  same worktree. It reads every review and inline comment, implements what
  they ask for, commits, pushes and sees CI through, without replying on
  GitHub. Approvals with nothing written, drafts and dismissed reviews are
  ignored, as are reviews from anyone else. For issues already awaiting their
  merge before the upgrade, reviews count from the date of the pull
  request's head commit, looked up once through GitHub's REST API. `superlinear status` lists these runs,
  running or queued, under their own "Addressing review" section, and their
  pull requests under "Awaiting review" as "agent addressing review" in place
  of GitHub's review state.

### Removed

- `superlinear standup`, with its holds, queue order, decisions and
  `~/.local/share/superlinear/standup.json`. Review and triage happen in
  Linear: mark a Needs human issue Done there and its dependents become
  ready; move an issue to Backlog to hold it; the Todo order is the queue
  order. The planning job no longer waits to be offered: it runs when the
  default branch moves or an issue is completed, and `superlinear plan`
  runs it now.

### Changed

- The summary that ended `superlinear status` is now its own command,
  `superlinear stats`: the counts of each section across workspaces, the
  measures per pull request with medians and histograms, the totals over
  every tracked task, and the figures by project. `status` no longer reads
  the Claude transcripts or diffs the open branches, and lists the CI runs
  only to find CI failing on the default branch, so it is quicker; `stats`
  does, and warns when a local base branch is ahead of origin.
- Agents work on Opus. The daemon sets `ANTHROPIC_MODEL=opus` for them, as
  `work` passes no model and the default in Claude's settings can be another.
- A pending proposal expires `proposalExpiryDays` after the first standup
  that showed it, not after it was made.
- The first poll of a workspace with no state, in `new` mode, starts nothing
  created before it, rather than an agent for every open issue in the
  workspace. The same goes after `make reset`.

### Fixed

- A comment in a pull request's conversation that starts with an
  @-mention, such as the `@sentry review` an agent posts as you, no longer
  queues a review agent that has nothing to do.

- A reply to a comment has the line `*Written by superlinear.*` and its
  note on a change only one time, also when the session copies them from
  superlinear's earlier replies in the thread.

- The daemon no longer crashes when it reads the token use of a session
  with no subagents, such as the one that answers a comment. It crashed
  at every restart, before any comment was answered.

- Proposals reach Linear again. Linear's `duplicate` state type, which every
  team has, failed the decoding of a team's states, so no proposal could be
  put in Linear. A state type Linear adds later is now `unknown` rather than
  an error, except in `readyStates`. An issue marked a duplicate counts as
  closed, as a canceled one does: it blocks nothing, and a proposed issue
  marked a duplicate is rejected.
- Agents that the Claude usage limit stopped while a daemon from before the
  pause ran are found again: a started issue with no pull request whose
  agent log ends at the limit is queued first and resumes its worktree's
  newest Claude session, and a pull request whose review agent stopped
  there gets one more agent for your latest change request.
- `make install` restarts a daemon that launchd runs from the installed path,
  with `launchctl kickstart -k`. launchd's own restart of the replaced binary
  could fail with `OS_REASON_CODESIGNING` and leave the daemon down.
- A pull request already attached to its Linear issue, as by hand or before
  the daemon kept records of its links, is recorded as linked. Linear refuses
  to attach it again, so the daemon tried and failed every poll.
- While a GitHub rate limit is used up, polls skip their GitHub work until it
  resets, logging once when the pause starts and once when it ends, instead
  of failing and logging at every step of every poll. Linear work goes on.
  `superlinear status` shows one line saying until when, instead of a warning
  per workspace.
- Each poll lists a repository's pull requests once, and its open ones with
  their reviews and head commits once more when a watched pull request is
  open.
  Before, it ran one `gh pr list` per watched branch and per running agent
  every poll, which with dozens of open pull requests used up GitHub's 5,000
  GraphQL points an hour and left agents and `superlinear status` rate
  limited.
- `make install` replaces the binary with a new file instead of overwriting
  it, which made macOS kill it on launch while the daemon ran it.

## [1.13.0] 2026-10-12

### Added

- The status summary shows a histogram for each measure, in place of the mean,
  with the minimum beside the median and maximum.
- Open pull requests are measured locally with `git diff --shortstat`, from
  the later of the fork points off the local base branch and off
  `origin/<base>`. When agents forked off unpushed local commits, which GitHub
  counts as part of each pull request, the workspace warns to push the base
  branch, and the summary says how many pull requests are affected.

## [1.12.0] 2026-10-12

### Added

- `superlinear status` ends with a summary: the number of projects and of
  items in each section across workspaces; the total, mean, median and maximum
  per agent pull request of lines added and removed, files changed, tokens,
  cache reads, agent time and CI time; totals over all tracked tasks; and the
  same figures per project. Tokens and agent time come from the Claude
  transcripts of each issue's branch, CI time from `gh run list`.

## [1.11.0] 2026-10-11

### Added

- Agents' build output is freed. When an agent ends, the daemon runs
  `work clean` on its worktree, removing its SwiftPM `.build` directories and
  Xcode DerivedData while keeping the worktree. At startup it cleans every
  worktree whose agent is not running and whose build output has been idle
  for an hour, and the DerivedData of worktrees since removed. Needs workr
  1.2.0. Before, nothing removed either until a merge, and DerivedData not
  even then, so the disk filled with tens of gigabytes.

## [1.10.0] 2026-10-11

### Added

- `superlinear status` lists every open pull request that belongs to a Linear
  issue of a configured workspace, whether or not the daemon tracks the issue:
  non-drafts under "Awaiting review" with their review state (not reviewed,
  changes requested, or approved) and CI state, drafts under "Draft pull
  requests". A pull request belongs to an issue when its branch or title names
  the issue's identifier and the workspace's Linear has that issue. These
  sections replace the tasks' "Open pull requests" when they can be listed.

## [1.9.0] 2026-10-11

### Added

- Each poll also follows started issues the daemon is not tracking, such as
  work done by hand or by agents from before a state reset. It matches issues
  In Progress or In Review to the repository's pull requests by branch, links
  them, and marks an issue done once its pull request has merged — but not
  while a pull request on its branch is open, nor if the issue moved back into
  progress after the merge. Worktrees for these issues are left in place.
  Failures that would repeat every poll, such as a read-only API key, are
  logged once.

## [1.8.0] 2026-10-11

### Added

- Each pull request an agent opens is linked to its Linear issue, as an
  attachment, within a poll of being opened — while the agent is still
  running, not only once it ends. Each URL is linked once. Issues used to get
  a link only from Linear's GitHub integration, which left none where the
  integration is not set up for the repository.

## [1.7.0] 2026-10-11

### Added

- Config edits take effect without a reload. The daemon checks the config file
  every five seconds, and when it changes to one that loads, exits so launchd
  restarts it on the new config; agents in flight carry on. An edit that does
  not load is logged once and ignored, so a half-saved file does not stop the
  daemon. A daemon run in the foreground only logs that a restart is needed.

## [1.6.0] 2026-10-11

### Added

- `superlinear status` lists each workspace's tasks: agents running, queued or
  interrupted, open pull requests with their URLs, and completed tasks. A task
  counts as completed only once its pull request is merged and its Linear
  issue is done; a merged pull request whose issue is still open is listed
  apart, so it is not mistaken for finished work. Pull requests come from
  `gh`, matched to issues by branch.
  `status` reads the state file and Linear only, so it runs beside the
  daemon and takes no daemon lock.

## [1.5.2] 2026-10-11

### Fixed

- An unknown command or option is an error, with exit status 64 and the usage.
  It used to be ignored and the daemon run in the foreground, so a command this
  version lacks, such as `superlinear status`, started a second daemon.
- Only one daemon runs at a time. A second exits at once, naming the first, via
  a lock on `~/.local/share/superlinear/daemon.lock`.
- A launch that fails, as when the disk is full, leaves the issue queued. It
  goes to the back of the queue and launches pause for a minute; after ten
  failed launches the issue is dropped with a message in the log. A failed
  launch used to drop the issue at once while it stayed marked processed, so a
  full disk emptied the whole queue.

## [1.5.1] 2026-10-09

### Fixed

- The daemon log shows each line as it is written. Under launchd, output went
  to the log file block-buffered, so lines appeared only when the buffer
  filled, minutes late or not before a restart.
- The repository ignores `worktrees/`, where `work start` puts the worktrees
  of agents working on superlinear itself.

## [1.5.0] 2026-10-09

### Added

- Each poll checks the pull requests opened by agents that have exited. When
  one merges, the daemon marks the issue done in Linear and removes its
  worktree and local branch with `work finish`. A closed pull request, or an
  agent that opened none, ends the watch and leaves the worktree in place.

## [1.4.0] 2026-10-09

### Added

- `maxConcurrentAgents` limits how many agents run at once across all
  workspaces, defaulting to 3. New issues wait in a queue kept in the state
  file and start oldest first as agents finish, so a first poll over a long
  backlog no longer starts an agent for every issue at once. An interrupted
  agent goes back in the queue at its original place.

## [1.3.0] 2026-10-09

### Changed

- The daemon follows `brew upgrade` and `brew uninstall` by itself. It checks
  the Homebrew link it was started through every minute: when an upgrade
  repoints it, the daemon exits and launchd restarts it on the new version, and
  when the link has been gone for five minutes, the daemon removes its own
  launch agent. A daemon running a local build does not watch.

### Removed

- `superlinear install --from-homebrew` and `uninstall --from-homebrew`. They
  were for cask hooks, which never shipped: Homebrew 7 deprecates cask flight
  blocks and sandboxes their replacements away from launchd. The 1.2.0 notes
  that describe those hooks did not hold for 1.2.0.

## [1.2.0] 2026-10-09

### Added

- Agents survive daemon restarts, and interrupted ones are resumed. Each agent
  gets a Claude session ID, and its run is kept in the state file until it
  exits. A restarted daemon waits for agents still running, records those that
  finished while it was down, and continues interrupted ones with
  `work start --headless --resume`. Needs workr 1.1.0.
- `make install` builds with semver build metadata, so `superlinear --version`
  prints e.g. `1.1.0+d0a4bc2` for a local build, with `.dirty` appended when the
  working tree had uncommitted or untracked changes. Releases print the bare
  version.

### Changed

- A poll starts agents without waiting for them, so new issues are picked up
  on schedule while earlier agents are still working. An issue counts as
  processed from the moment its agent starts.
- The daemon runs `work` directly instead of through `fish -c`, so a stale
  `work` fish function can no longer shadow workr. fish is no longer a
  dependency.
- The daemon reads `$HOME` for its config, state and logs, falling back to the
  account's home directory.
- A local build takes precedence over Homebrew. `superlinear install` from the
  Homebrew binary leaves an agent that runs an existing local build in place;
  pass `--force` to replace it. `make install` warns when another
  `superlinear` shadows `~/.local/bin` in your `PATH`.

### Fixed

- The state file is read back correctly. Dates were written as ISO 8601 and
  read as numbers, so every load failed and each restart started from empty
  state, sending agents again to every backlog issue.
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
