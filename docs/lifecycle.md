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
8. When the pull request merges, the issue is done: see [The merge and completion](#merge).

<a id="selection"></a>
## Selection

Each workspace picks its issues in one of two modes, set by [`selection`](configuration.md#selection).

- **`new`**, the default: issues created since the last poll, in the `backlog` or `unstarted` state, oldest first. Suits a workspace where filing an issue means "build this".
- **`ready`**: every open issue whose state type is in [`readyStates`](configuration.md#ready-states) — `unstarted`, which is Todo, by default — however old. They start urgent first and no priority last, then by project sort order, milestone sort order and issue sort order, as Linear orders them; an issue outside a project or milestone comes after those in one. When its agent starts, the issue moves to its team's first `started` state, such as In Progress. Suits a planned roadmap: issues wait in Backlog, and moving one to Todo is how you, or a [standup](planning.md#standup), say "build this". This costs one query per poll, which brings each issue's blockers along.

<a id="first-poll"></a>
**First poll:** a workspace with no state — just added to the config, or after `make reset` — in `new` mode takes its first poll as the starting point, logs that once, and starts no issue created before it. Without that, its first poll would start an agent for every open issue in the workspace. In `ready` mode the first poll starts every ready issue, which is what Todo means there.

<a id="ready-gate"></a>
## The ready gate

In both modes, an issue the selection finds starts only when nothing holds it back:

- **Blockers:** an issue that another issue blocks, through a Linear "blocks" relation, does not start while that issue is neither completed nor canceled. It waits in the state file as blocked, and starts on the first poll after its last blocker is closed.
- **Human labels:** an issue with a label in [`humanLabels`](configuration.md#human-labels) — "Needs human" or "Spike" by default, in any case — never starts an agent. Should the label come off, it starts like any other issue. These issues are for you: the [standup](planning.md#standup-needs-human) lists them to sign off.
- **Holds:** an issue held at a [standup](planning.md#standup) does not start until a standup releases it.
- **Moving on:** a waiting issue moved out of the states an agent starts from, or archived, stops waiting.

`superlinear status` lists waiting issues under "Blocked", with their open blockers, and "Needs human", with their human labels, as of the daemon's last poll. In `new` mode each poll fetches the waiting issues again, in one more query when there are any; in `ready` mode the ready query brings them.

<a id="agent"></a>
## The agent

Each issue that passes the gate is queued, in the order the selection gives, or in the order the last standup set. While fewer than [`maxConcurrentAgents`](configuration.md#max-concurrent-agents) agents run, the issue queued longest ago starts. The poll does not wait for agents: the next one runs on schedule however long they take.

To start an agent, the daemon picks a Claude session ID, writes the prompt to a file, then runs, in the repository directory:

```
work start --headless --prompt-file <prompt> --log-file <log> --session-id <uuid> <issue-branch-name>
```

This creates a worktree at `worktrees/<branch>`, runs `make init`, and pipes the prompt into `claude -p` under that session ID. Branch names come from Linear's own `branchName` field, so the branch matches what the Linear UI shows.

The prompt instructs the agent to run `/armcknight-claude:start`, implement the change, run `/armcknight-claude:commit`, then run `/armcknight-claude:pr --autonomous` to open a pull request and see CI through. The agent is told not to pause for confirmation. The target repository's `CLAUDE.md` tells it how the project is built and tested.

The run — issue, branch, session ID, and the process running it — is kept in the state file until the agent exits. Agents outlive the daemon: see [Restarts](operations.md#restarts).

<a id="pull-request"></a>
## The pull request

When the agent exits, the issue waits in the state file for its pull request. Each poll runs `gh pr list --head <branch> --state all` in the repository for every waiting issue:

- **Merged:** see [The merge and completion](#merge).
- **Open:** the next poll checks again — unless you have reviewed it, or it conflicts with its base branch. See [Reviews](#reviews) and [Conflicts](#conflicts).
- **Closed without a merge**, or **no pull request:** the daemon logs it and stops watching. The worktree stays for you to inspect.

Each poll also attaches the pull requests opened from an issue's branch to the issue in Linear, from the first poll after the pull request is opened, so the link is there whether or not Linear's GitHub integration is set up for the repository.

superlinear never merges. Require review before merge on every repository it works on: see [Security](../README.md#security).

<a id="reviews"></a>
## Reviews

Review a pull request the daemon is watching, and an agent comes back to address it. Each poll reads the reviews on the open pull request of every issue awaiting its merge. A review counts when:

- it is from the GitHub user `gh` is signed in as,
- it was submitted after the issue's last agent started, and
- it asks for something: changes requested, a comment review — including one made only of comments on lines of code — or an approval with a note. An approval with nothing written, a draft review and a dismissed review do not count.

The issue then goes back in the queue. Its agent runs in the same worktree, on the same branch, under a new Claude session, with a prompt to read every review and its inline comments, satisfy the points not yet addressed, commit, push and see CI through. It does not reply on GitHub. When it ends, the issue waits for its merge again, and only reviews submitted after that agent started bring it back. Reviews from other people and from bots, such as Seer, are left alone: the first agent already handles bots' reviews.

Issues already awaiting their merge when you upgrade to a version that follows reviews take their pull request's newest commit as the starting point: a review submitted after the last push still starts an agent, and older reviews, which the agent may have addressed, do not.

<a id="conflicts"></a>
## Conflicts

When the base branch moves on and an open pull request the daemon is watching no longer merges cleanly, an agent comes back to merge the base branch in. Each poll reads GitHub's mergeable state for those pull requests, in the listing that brings their reviews. For one that conflicts, the daemon fetches the base branch from `origin`, then queues the issue. Its agent runs in the same worktree, on the same branch, under a new Claude session, with a prompt to merge `origin/<base>` into the branch, resolve each conflict so that both sides' changes stay, build and test, commit the merge, push and see CI through. It does not rebase, force-push or comment on GitHub.

Reviews come first: if a review also needs an agent, that agent goes first, and the conflict waits for the poll after it ends. The conflict also waits for a poll that can read the reviews, so the review baseline stays correct; a conflict run does not count reviews as addressed.

Each conflict gets one agent. The daemon records the heads of the branch and of the base when it queues the agent. If the pull request still conflicts with the same heads after the agent ends, the daemon logs that once and starts no other agent until one of the two branches moves. GitHub works out the mergeable state in the background after a push, so a pull request it has not yet checked waits for a later poll.

<a id="merge"></a>
## The merge and completion

When the pull request merges, the issue moves to its team's first completed state in Linear, unless it is already completed or canceled, and `work finish <branch>` removes the worktree and the local branch. If Linear cannot be updated, the next poll tries again. With Linear's GitHub integration installed for the repository, Linear moves the issue to done when the pull request merges, by default; without it, the daemon does.

A task is completed only when both its pull request is merged and its Linear issue is done.

<a id="started-issue-sweep"></a>
### Issues the daemon does not follow

The same goes for started issues the daemon is not following — work done by hand, or by agents from before a state reset. Each poll matches issues In Progress or In Review to pull requests by branch, links them, and marks an issue done once its pull request has merged, unless a pull request on its branch is still open or the issue was moved back into progress after the merge. Their worktrees are left alone. This needs an API key with write access; with a read-only key it logs the refusal once.

<a id="after-merge"></a>
## After the merge

The merge starts the next part of the project's life:

- The [daily planning job](planning.md#daily-planning) reads the merged changes and proposes what follows from them.
- The project's [nightly build](builds.md#nightly-testflight) ships them to testers.
