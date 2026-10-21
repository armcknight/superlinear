# The life of an issue

How an issue in Linear becomes a merged pull request: which issues superlinear picks, how an agent works on one, and what happens to its pull request until the issue is done.

<a id="overview"></a>
## Overview

1. `launchd` starts the daemon at login and restarts it if it exits.
2. Each configured workspace polls on its own loop, concurrently.
3. Each poll asks the Linear GraphQL API for the issues an agent might start on, optionally filtered by team, 25 at a time. Which ones depends on the workspace's `selection`: see [Selection](#selection).
4. Issues already recorded in the state file are discarded, so an issue is processed once. So are issues blocked by another open issue and issues with a human label, which wait in the state file and are checked again each poll: see [The ready gate](#ready-gate).
5. Each remaining issue is recorded as processed and queued, and an agent starts on it when a slot is free: see [The agent](#agent).
6. When the agent exits, the issue waits for its pull request to merge: see [The pull request](#pull-request).
7. Reviews and conflicts bring an agent back to the same branch: see [Reviews](#reviews) and [Conflicts](#conflicts).
8. With [`stacking`](configuration.md#stacking) on, an issue whose one unmerged blocker has an open pull request starts on top of it, and the daemon keeps its pull request current with the one below: see [Stacks](#stacks).
9. When the pull request merges, the issue is done: see [The merge and completion](#merge).

<a id="selection"></a>
## Selection

Each workspace picks its issues in one of two modes, set by [`selection`](configuration.md#selection).

- **`new`**, the default: issues created since the last poll, in the `backlog` or `unstarted` state, oldest first. Suits a workspace where filing an issue means "build this".
- **`ready`**: every open issue whose state type is in [`readyStates`](configuration.md#ready-states) — `unstarted`, which is Todo, by default — however old. They start urgent first and no priority last, then by project sort order, milestone sort order and issue sort order, as Linear orders them; an issue outside a project or milestone comes after those in one. When its agent starts, the issue moves to its team's first `started` state, such as In Progress. Suits a planned roadmap: issues wait in Backlog, and moving one to Todo is how you, or an accepted [proposal](planning.md#standup), say "build this". This costs one query per poll, which brings each issue's blockers along.

<a id="first-poll"></a>
**First poll:** a workspace with no state — just added to the config, or after `make reset` — in `new` mode takes its first poll as the starting point, logs that once, and starts no issue created before it. Without that, its first poll would start an agent for every open issue in the workspace. In `ready` mode the first poll starts every ready issue, which is what Todo means there.

<a id="ready-gate"></a>
## The ready gate

In both modes, an issue the selection finds starts only when nothing holds it back:

- **Blockers:** an issue that another issue blocks, through a Linear "blocks" relation, does not start while that issue is not completed, canceled or marked a duplicate. It waits in the state file as blocked, and starts on the first poll after its last blocker is closed. With [`stacking`](configuration.md#stacking) on, an issue whose last open blocker has an open pull request from an agent may start on top of that pull request instead: see [Stacks](#stacks).
- **Human labels:** an issue with a label in [`humanLabels`](configuration.md#human-labels) — "Needs human" or "Spike" by default, in any case — never starts an agent. Should the label come off, it starts like any other issue. These issues are for you: `superlinear status` lists them under "Needs human", and [marking one Done in Linear](planning.md#standup-needs-human) makes the issues it blocks ready.
- **Holds:** to hold an issue back, move it to Backlog; moving it to Todo again releases it.
- **Moving on:** a waiting issue moved out of the states an agent starts from, or archived, stops waiting.

`superlinear status` lists waiting issues under "Blocked", with their open blockers, and "Needs human", with their human labels, as of the daemon's last poll. In `new` mode each poll fetches the waiting issues again, in one more query when there are any; in `ready` mode the ready query brings them.

<a id="agent"></a>
## The agent

Each issue that passes the gate is queued, in the order the selection gives: the Todo order in Linear is the only queue order. While fewer than [`maxConcurrentAgents`](configuration.md#max-concurrent-agents) agents run, the issue queued longest ago starts. The poll does not wait for agents: the next one runs on schedule however long they take.

To start an agent, the daemon picks a Claude session ID, writes the prompt to a file, then runs, in the repository directory:

```
work start --headless --prompt-file <prompt> --log-file <log> --session-id <uuid> <issue-branch-name>
```

This creates a worktree at `worktrees/<branch>`, runs `make init`, and pipes the prompt into `claude -p` under that session ID. Agents work on Opus: the daemon sets `ANTHROPIC_MODEL=opus` for them, whatever the default model in Claude's settings is. The planning job and the sessions that answer comments run on [Fable](planning.md#planning-model). Branch names come from Linear's own `branchName` field, so the branch matches what the Linear UI shows.

The prompt instructs the agent to run `/armcknight-claude:start`, implement the change, run `/armcknight-claude:commit`, then run `/armcknight-claude:pr --autonomous` to open a pull request and see CI through. The agent is told not to pause for confirmation. The target repository's `CLAUDE.md` tells it how the project is built and tested. The prompt also has the issue's comments, read when the issue is queued, so the agent does not depend on what `linctl issue get` prints. Before an agent starts, your comments on the issue are answered, or change its description: see [Comments on every issue](planning.md#issue-comments).

<a id="linear-key"></a>Every Claude session that superlinear starts gets its workspace's Linear key: agents, the [planning job](planning.md#daily-planning) and the sessions that [answer comments](planning.md#proposal-comments). The daemon sets `LINCTL_API_KEY` in the session's environment to the workspace's [`apiKey`](configuration.md#api-key), in place of any key in the daemon's own environment, so `linctl` reads that workspace without an `.envrc`. A repository's `.envrc`, loaded by `direnv exec`, may still set its own. The key goes only in the environment: never in a prompt, a log, an argument or the state file. The small session that checks whether the [Claude usage limit](#claude-usage-limit) was lifted belongs to no workspace and gets no key.

The run — issue, branch, session ID, and the process running it — is kept in the state file until the agent exits. Agents outlive the daemon: see [Restarts](operations.md#restarts).

<a id="pull-request"></a>
## The pull request

When the agent exits, the issue waits in the state file for its pull request. Each poll runs `gh pr list --head <branch> --state all` in the repository for every waiting issue:

- **Merged:** see [The merge and completion](#merge).
- **Open:** the next poll checks again — unless you have reviewed it or commented on it, or it conflicts with its base branch. See [Reviews](#reviews) and [Conflicts](#conflicts).
- **Closed without a merge**, or **no pull request:** the daemon logs it and stops watching. The worktree stays for you to inspect. If there is no pull request, and the agent did not stop at the [Claude usage limit](#claude-usage-limit), your next comment on the issue brings an agent back: see [Comments in Linear](#linear-comments).

Each poll also attaches the pull requests opened from an issue's branch to the issue in Linear, from the first poll after the pull request is opened, so the link is there whether or not Linear's GitHub integration is set up for the repository.

superlinear never merges. Require review before merge on every repository it works on: see [Security](../README.md#security).

<a id="reviews"></a>
## Reviews

Review a pull request the daemon is watching, or comment in its conversation, and an agent comes back to address it. Each poll reads the reviews and the conversation comments on the open pull request of every issue awaiting its merge, in one listing. A review counts when:

- it is from the GitHub user `gh` is signed in as,
- it was submitted after the issue's last agent started, and
- it asks for something: changes requested, a comment review — including one made only of comments on lines of code — or an approval with a note. An approval with nothing written, a draft review and a dismissed review do not count.

A comment in the pull request's conversation, outside any review, counts the same way: when it is from that user, was made after the issue's last agent started, and has something written in it. A comment that starts with an @-mention, such as `@sentry review`, is addressed to a bot or to another person, so it does not count. Agents run as you and post such comments themselves. A reply in the thread of an earlier review, made outside a new review, is a review of its own on GitHub, submitted when you reply, so it counts as a new comment review.

The issue then goes back in the queue, once for all the reviews and comments that came in. Its agent runs in the same worktree, on the same branch, under a new Claude session, with a prompt that lists those reviews and comments, with a link to each comment, and tells it to read every review, its inline comments and their replies, and every conversation comment, satisfy the points not yet addressed, answer questions in the pull request description, commit, push and see CI through. It does not reply on GitHub. When it ends, the issue waits for its merge again, and only reviews and comments made after that agent started bring it back. Reviews and comments from other people and from bots, such as Seer, are left alone: the first agent already handles bots' reviews.

Issues already awaiting their merge when you upgrade to a version that follows reviews take their pull request's newest commit as the starting point: a review submitted after the last push still starts an agent, and older reviews, which the agent may have addressed, do not.

<a id="linear-comments"></a>
### Comments in Linear

Your requests in comments on the Linear issue bring an agent back too. Each poll reads the comments on the issues whose agents have ended, and on those you commented on. Only comments from the API key's user count, and not superlinear's own replies, which start with `*Written by superlinear.*`. A short read-only session first decides what each comment is: see [Comments on every issue](planning.md#issue-comments). A question gets a reply in Linear, and a note such as "thanks" nothing. A request for a change brings an agent back:

- **The issue has an open pull request:** a request queues the same agent that a review does, in the same worktree, under a new Claude session. Its prompt has your comment and the issue's other comments. The agent also reads the reviews, so the comment and any new review are handled together. It makes the change the comment asks for, or answers a question in the pull request description. It writes no comments on GitHub or in Linear.
- **The last agent ended without a pull request:** a request on the issue, while it is in a started state, queues a new agent in the issue's worktree. Its prompt has the comment. The agent does what the comment asks, and opens a pull request if it changed anything. An agent that stopped at the Claude usage limit is resumed instead, as described in that section. Issues whose agents ended without a pull request before an upgrade count too, from the time each one was started.
- **An agent is running:** a question gets a reply with what is known now. A request waits, and the agent is not stopped. When it ends, if it opened a pull request, the review agent handles the request. If it did not, a new agent does. `superlinear status` lists the requests that wait.

Comments on proposals and on the spec document are answered instead: see [Questions and requests in comments](planning.md#proposal-comments). Comments on other issues of the watched teams are answered, or change the issue, by its state, as that section says. Each comment is handled once for each version of its text: an edited comment brings an agent back again, and its prompt has the old and the new text. At the first poll after an upgrade, only comments made after the issue's last agent started count.

<a id="conflicts"></a>
## Conflicts

When the base branch moves on and an open pull request the daemon is watching no longer merges cleanly, an agent comes back to merge the base branch in. Each poll reads GitHub's mergeable state for those pull requests, in the listing that brings their reviews. For one that conflicts, the daemon fetches the base branch from `origin`, then queues the issue. Its agent runs in the same worktree, on the same branch, under a new Claude session, with a prompt to merge `origin/<base>` into the branch, resolve each conflict so that both sides' changes stay, build and test, commit the merge, push and see CI through. It does not rebase, force-push or comment on GitHub.

Reviews come first: if a review also needs an agent, that agent goes first, and the conflict waits for the poll after it ends. The conflict also waits for a poll that can read the reviews, so the review baseline stays correct; a conflict run does not count reviews as addressed.

Each conflict gets one agent. The daemon records the heads of the branch and of the base when it queues the agent. If the pull request still conflicts with the same heads after the agent ends, the daemon logs that once and starts no other agent until one of the two branches moves. GitHub works out the mergeable state in the background after a push, so a pull request it has not yet checked waits for a later poll.

<a id="stacks"></a>
## Stacks

When an issue's blocker has an open pull request that waits for your review, its dependents wait too, although the code they need exists. With the workspace key [`stacking`](configuration.md#stacking), on by default, dependent work starts on top of the blocker's branch, as a pull request that targets that branch. You review and merge bottom-up; superlinear never merges.

<a id="stackable"></a>
### Which issues stack

An issue is **stackable** when:

- every blocker is completed, canceled or marked a duplicate, except exactly one;
- that one's agent has ended, and its pull request is open, not a draft, with CI passing; and
- the resulting stack is no deeper than [`maxStackDepth`](configuration.md#max-stack-depth) pull requests, the bottom one included, 3 by default.

A stackable issue starts like a ready issue, with these differences. Its branch is created from the blocker's branch on `origin`, fetched first, and `work start` adopts it, so the worktree begins at the lower pull request's head. The prompt says that the work is stacked on the blocker's pull request, which is not merged yet and can change, and tells the agent to open its pull request against that branch, and never to rebase, force-push, or merge the default branch in. An issue with two or more unmerged blockers waits as before, whatever their pull requests. So does one whose blocker's pull request is a draft, has CI failing or running, or would make the stack too deep; the daemon logs why, once. The blocker's pull request is looked up once per poll per blocker, for the few blocked issues that could stack.

`superlinear status` shows each pull request under the one it stacks on, indented, with "stacked on #n". Its "Waiting on you" orders them by stack, bottom first.

<a id="no-native-stacks"></a>
### Why not GitHub's native stacks

GitHub's stacked pull requests, in public preview with the `gh stack` extension, were considered and not used. When a lower pull request in a native stack merges, GitHub rebases the pull requests above it and force-pushes their branches, from the server, with no setting to turn that off: the changelog says the pull requests above a merged layer "stay open and automatically rebase and retarget", and the "Rebase stack" action "force-pushes each rebased branch". That rewrites commits you may have reviewed, and the review comments on them. superlinear's rule is the opposite, so its stacks are plain pull requests that target the lower branch, and the `gh stack` extension is not needed. GitHub does the one thing a plain stack needs: when a pull request merges and its branch is deleted, as with "automatically delete head branches" on, it retargets the open pull requests that targeted that branch to the merged pull request's base, without rewriting them. The daemon retargets them itself when the branch stays.

<a id="never-rewritten"></a>
### Reviewed pull requests are never rewritten

A pull request the daemon watches is never rebased or force-pushed, by superlinear or by GitHub on superlinear's behalf, whether or not it has reviews. It is brought up to date by merging its base branch into it, so that its commits, and your comments on them, stay as you saw them in GitHub. Agents are told the same.

<a id="keeping-stacks-current"></a>
### Keeping a stack current

Each poll looks at every stacked pull request whose agent has ended, lower ones first, so that a change low in the stack reaches each pull request above it in the same poll:

- **The lower branch moves**, after a review response, a conflict merge, or a push: the daemon merges the lower branch into the upper one, in its worktree, with a merge commit, and pushes. If the merge conflicts, it is aborted, and a [conflict agent](#conflicts) resolves it on the upper pull request, with the lower branch as the base; the daemon tries once per pair of heads, as for any base.
- **The lower pull request merges:** the upper pull request now targets what the lower one targeted, the default branch or the next branch down. GitHub retargets it when the lower branch is deleted; when it is not, the daemon runs `gh pr edit --base`. The repositories squash-merge, so the upper branch still holds the lower branch's original commits. The daemon merges the new base into it, a merge commit, never a rebase, which leaves only the upper pull request's own changes in its diff. Its issue's blocker is completed in Linear by the merge.
- **The lower pull request is closed without a merge:** the upper pull request becomes a draft, its issue goes back to Blocked in `superlinear status`, with why, and `superlinear status` lists the draft under "Draft pull requests" for a decision: reopen the lower pull request, and the upper one leaves draft; retarget the upper one by hand, and the daemon treats it as merged below; or close it.
- Conflict detection compares each stacked pull request with its own base, the lower branch, not with the default branch.

The daemon pushes to the upper branch itself for these merges, with a plain push, and only to branches it made. Agents never force-push. A pull request the daemon just pushed to is not checked for conflicts until the next poll, as GitHub's state is of before the push.

<a id="limits"></a>
## Usage and spending limits

superlinear sets no budgets of its own. The limits are the ones you set with the providers: your Claude plan's usage limit, and the GitHub Actions spending limit in your GitHub settings. When one of them stops work, superlinear sees it, stops the work that cannot succeed, loses none, and continues when the limit is lifted. There is no config key for this.

<a id="claude-usage-limit"></a>
### The Claude usage limit

When a session — an agent for a new issue, a review or a conflict — ends with Claude's usage limit message, such as `You've hit your session limit · resets 2:30am (America/Anchorage)` or `Claude AI usage limit reached|<time>`, the daemon:

- Pauses every Claude session, in all workspaces, as they share one Claude login: until the reset time in the message, or for one hour when it gives none.
- Records the stopped session as interrupted, not failed. It keeps its session ID, and counts neither as a resume nor as a failed launch.
- Starts no session while paused, the [planning job](planning.md#daily-planning) included; its trigger holds, so it starts after the pause. Queued and blocked issues keep their places and their order. GitHub work that needs no Claude — linking and checking pull requests, reviews, moving issues to Done — goes on.
- Every 15 minutes while paused, runs one very small session (`claude -p` with a one-word prompt and no tools), at a cost of a few tokens. When it answers, the limit was lifted, as when you bought more usage: the pause ends at once. When it gives the limit message again, the pause goes on, until its new reset time.
- Ends the pause at once on [`superlinear resume`](operations.md#usage).
- When the pause ends — at the reset time, after a check, or on `superlinear resume` — resumes the interrupted sessions first, with their session IDs, then the queue in its usual order. A resumed session that hits the limit again at once pauses everything again, until the new reset time; nothing retries in a loop.

Fable's own usage limit does not pause sessions: the planning job and comment answers go on [on Opus](planning.md#planning-model) until it resets.

A daemon from before this pause took an agent that the limit stopped for one that ended without a pull request, and dropped it. Each poll's [started-issue sweep](#started-issue-sweep) finds such agents again from the end of their logs in `~/.local/share/superlinear/logs/<issue>.log`:

- A started issue the daemon queued, with no run or merge watch and no pull request from its branch, whose log ends with the limit message, is queued again ahead of the others. It resumes the newest Claude session of its worktree, so uncommitted work there carries on, or starts a new session on the same branch when there is none. It is not a new start: the issue is not moved in Linear again.
- An issue awaiting its merge whose log ends with the limit message, and whose pull request's latest review from you asks for changes and came before that log, gets one more agent for its reviews: the stopped agent was answering them, and the old daemon counted them as answered.

Each log is recovered once: an agent whose relaunch fails before it writes its log again is not queued again for the same message. If the limit is still on, the relaunched session ends with the limit message, and the pause above takes over.

<a id="spending-limit"></a>
### The GitHub Actions spending limit

When the limit is used up, or a payment fails, GitHub starts no jobs in private repositories: their check runs fail at once with an annotation saying the job was not started because of the spending limit or a billing problem. Public repositories' standard runners are free, so this applies only to private ones. At each poll, for a private repository, the daemon reads the annotations of the failed runs of open pull requests' branches and of the default branch, once per run attempt, and, for runs stopped this way:

- Shows the pull request's CI state as "CI not started: GitHub spending limit", not "CI failing", in [`superlinear status`](operations.md#status).
- Proposes no issue for such a run on the default branch, as it does for [failing CI](planning.md#follow-ups).
- Tells agents, in their prompts, that such CI is not a failure to fix. Agents go on working: the limit stops CI, not Claude, and agents run the tests locally before they push.
- Once an hour, reruns the failed jobs of the newest stopped run (`gh run rerun <id> --failed`). When its jobs start, you have raised the limit or the month has changed: it reruns the failed jobs of the other stopped runs, newest first, at most one for each branch.
- Reads the stopped runs again at each poll. A run you rerun by hand that starts its jobs counts like the hourly rerun: the others are rerun, and the stop ends. A run that no longer fails, as after you reran it and it passed, leaves the list; when none is left, the stop ends. Between polls, `superlinear status` shows the last poll's view.

### Where pauses show

`superlinear status` begins with one line for each active pause, such as `Claude usage limit: paused until 15:00 (next check 14:15), 3 sessions waiting` and `GitHub Actions spending limit: CI not started in 2 repositories since 10:12`. A macOS notification is posted when a pause starts, and one when it ends. Each workspace's Risks section lists the active pauses and the work they hold back. Both pauses are kept in the state file, so a restarted daemon keeps them.

<a id="merge"></a>
## The merge and completion

When the pull request merges, the issue moves to its team's first completed state in Linear, unless it is already completed, canceled or marked a duplicate, and `work finish <branch>` removes the worktree and the local branch. If Linear cannot be updated, the next poll tries again. With Linear's GitHub integration installed for the repository, Linear moves the issue to done when the pull request merges, by default; without it, the daemon does.

A task is completed only when both its pull request is merged and its Linear issue is done.

<a id="started-issue-sweep"></a>
### Issues the daemon does not follow

The same goes for started issues the daemon is not following — work done by hand, or by agents from before a state reset. Each poll matches issues In Progress or In Review to pull requests by branch, links them, and marks an issue done once its pull request has merged, unless a pull request on its branch is still open or the issue was moved back into progress after the merge. Their worktrees are left alone. This needs an API key with write access; with a read-only key it logs the refusal once.

<a id="after-merge"></a>
## After the merge

The merge starts the next part of the project's life:

- The [planning job](planning.md#daily-planning) reads the merged changes and proposes what follows from them.
- The owner ships them to testers with the next [TestFlight build](builds.md#testflight), made by hand.
