# Planning

How superlinear keeps the plan in Linear up to date: it proposes changes in Linear, where you accept or reject them, or let them through on their own.

<a id="proposals"></a>
## Proposals and trust levels

superlinear can propose changes to the Linear workspace: new issues, edits, closures, relations, promotions from Backlog to Todo, spec changes, and project updates. Each proposal is kept in the state file with its kind, its target (an issue, a project, a document, or for a new issue its team), the change itself (for an edit, the old and the new text, so a diff can be shown), the reason, its source (a pull request, a commit range, an agent session with its issue and pull request, or a workflow run), when it was made, and its status: `pending`, `applied`, `rejected` or `expired`, with the reason for a rejection. [Agents' follow-ups](#follow-ups), failing CI on the default branch, TODOs in merged pull requests, and the [planning job](#daily-planning) make proposals.

<a id="trust-levels"></a>
### Trust levels

The workspace's [`autonomy`](configuration.md#autonomy) config sets what happens to each kind:

| Level | Effect |
| --- | --- |
| `auto` | Applied at once, and still listed for review. |
| `review` | Put in Linear for you to approve or reject there. See [Reviewing proposals in Linear](#standup). |
| `never` | Not proposed at all. |

<a id="proposal-kinds"></a>
### Kinds

| Kind | Change | Default |
| --- | --- | --- |
| `createIssue` | A new issue. | `review` |
| `editIssue` | A new description, or managed block, for an issue. | `review` |
| `closeIssue` | Moves an issue to its team's first canceled state. | `review` |
| `addRelation` | Relates two issues: `blocks`, `duplicate`, `related` or `similar`. | `auto` |
| `promoteIssue` | Moves an issue from Backlog to its team's first unstarted state, such as Todo, as when its blockers are done. | `review` |
| `changeSpec` | A new description for a project, or new content for a document. | `review` |
| `postProjectUpdate` | Posts a project update. The proposal names the project's overview issue, on which it is proposed; without one it is not proposed. | `review` |

<a id="proposal-rules"></a>
### Rules for applying a proposal

- **Its own issues are labelled.** Each issue superlinear creates gets the label `superlinear`, which it creates in the team when neither the team nor the workspace has it, and ends with a "Source" line linking to where it came from. Project updates end with the same line.
- **Your text is yours.** In an issue without the `superlinear` label, an edit changes only the managed block between `<!-- superlinear -->` and `<!-- /superlinear -->`, which Linear does not show; it adds the block at the end when there is none. The rest of the description is left exactly as it was. In an issue with the label, an edit replaces the description.
- **Hands off.** An issue with the label `superlinear: hands off` is never edited, closed, promoted or related. A proposal to change one is rejected.
- **No lost updates.** A proposal records the target's `updatedAt` when it was worked out. Before an edit, closure, promotion or spec change, superlinear reads the target again. If it changed after that time, the proposal is not applied but stays pending, sent back for review with a note, even when its kind is `auto`: it is [asked again in Linear](#standup), against the target as it is now. A proposal without the time is checked against the old text instead. Times within a second count as the same, as the state file keeps dates to the second.
- **No duplicates.** A change already pending, or rejected before, is not proposed again: the same kind and target, and for a new issue the same title once case and punctuation are set aside, for a relation the same other issue and type. A new issue is also compared with the open issues and proposals by an agent, for the same work in other words: see [Duplicate issues](#duplicate-check).
- **Proposals expire.** A proposal still pending [`proposalExpiryDays`](configuration.md#proposal-expiry-days) days after it was [put in Linear](#standup) expires: its comment says so, or its issue is canceled with a note. One not yet in Linear does not expire. Applied and expired proposals drop out of the state file 30 days after; rejected ones stay, to keep the change from coming back.

<a id="duplicate-check"></a>
### Duplicate issues

Before a new issue is proposed, superlinear looks for the same work under another title. Its candidates are:

- the open issues in its team that Linear's search finds for its title, at most 10;
- the team's proposed issues that are pending or were rejected, at most 20, newest first. One already in Linear counts as the issue it is.

When there is one or more, a short headless Claude session, `claude -p` with no tools, gets the new issue's title and description and each candidate's, and says whether the new issue is the same work as one of them, may be the same work as some, or is the same work as none. Two issues are the same work when doing one would do the other: "Retry failed syncs" and "Make sync robust to network errors" are. Duplicates can say different things, so superlinear merges them, rather than keeping one and losing the other:

| The new issue is | What is proposed |
| --- | --- |
| The same work as an open issue, and says something that issue does not | An `editIssue` proposal that adds what it says to that issue, under the heading `Also from "<title>"`: to the description of an issue superlinear created, or else to the managed block. |
| The same work as an open issue, and adds nothing | Nothing, or, for an issue that follows from another, a `related` relation between that one and the open one. |
| The same work as a pending proposal not yet in Linear | Nothing new: what it adds goes into that proposal's description. |
| The same work as a rejected proposal | Nothing. |
| Maybe the same work as some candidates | The new issue, for review even when `createIssue` is `auto`, with a comment on the proposed issue that links each candidate. |
| The same work as none | The new issue. |

The session's answer names the candidates by their keys, and keys it does not know are dropped. When the session fails or its answer cannot be read, the daemon logs it and proposes the new issue for review, with every candidate listed. A hands-off issue gets no edit.

On a proposed issue that lists possible duplicates, you decide: accept it, decline it, or mark it a duplicate of one of them in Linear. Marking it a duplicate rejects the proposal, with the issue it duplicates in the reason, and proposes an `editIssue` that adds the proposed issue's description to that issue, so that nothing it says is lost. Reject that edit with 👎 when the issue says it all already.

<a id="audit-log"></a>
### The audit log

Each change applied is appended to `~/.local/share/superlinear/audit/<workspace>.jsonl`: the time, the proposal, and Linear's response, one JSON object a line. A failed write leaves the proposal pending, with the error, and writes nothing to the log.

`superlinear proposals [--workspace <name>]` lists each workspace's pending proposals, oldest first, then those applied, rejected or expired in the last 7 days, newest first. Each shows its ID's first 8 characters, kind, target, status, when it was made, reason and source, where it waits in Linear and since when, any rejection reason, note or error, and the change: a new issue's title and description, or a line diff for an edit.

<a id="daily-planning"></a>
## The planning job

```sh
superlinear plan [--workspace <name>]
```

Each change that may move the project's direction makes superlinear review what was merged and how the open issues stand, for each workspace with `planning.enabled`, and store what it finds as [proposals](#proposals). It never writes to Linear itself; each proposal's trust level decides whether it is applied at once or [put in Linear for review](#standup).

There is no schedule. At each poll, when no job is running for the workspace, the daemon starts one when:

- the workspace has had no job yet;
- the default branch's head is not the one the last job looked at, failed or not: a pull request merged, or commits were pushed outside one. The head comes from `git ls-remote`, so the poll fetches nothing;
- an issue of the watched teams was completed after the last job ended, in Linear by hand or by the daemon after a merge. Completions while the last job ran do not count again.

Jobs for one workspace run one at a time, so several merges while one runs make one job after it, which covers them all. A failed job counts: the branch has to move, or an issue be completed, before the next. `superlinear plan` runs a job at once, in the foreground, for the workspace named, or for every workspace with planning on. The session is told why its job runs.

A job runs one headless Claude session, `claude -p`, in the worktree that has the repository's default branch checked out, which is that of `origin/HEAD`, or `main` or `master`. superlinear first fetches the branch and fast-forwards that worktree to it when the worktree is clean. The session may read the code and run `git log`, `git show` and `git diff`, and write one file. Its prompt gives:

- the commits on the default branch since the head the last successful job looked at, or, on the first job, those of the last 24 hours, at most 100, each with its pull request, from `gh pr list --state merged`, and the Linear issues its message, branch or title names;
- the issues of the watched teams completed since the last job ended, or, on the first job, in the last 24 hours, which are no longer among the open issues;
- the open issues of the watched teams, with their state, priority, project, milestone, labels, relations, description and managed block, and each project's description and milestones;
- the spec document, when `planning.specDocumentURL` is set.

The session writes a JSON file of proposals, not to Linear. It looks for:

- issues that the merged changes made obsolete or already did: `closeIssue`, with the commit;
- issue descriptions whose assumptions the changes broke: `editIssue` of the managed block;
- missing relations between issues, and duplicates: `addRelation`;
- gaps: work that the spec or a project's exit criteria need but that no issue covers, and issues you created that have no acceptance criteria or spec references: `createIssue`, `editIssue`;
- places where the code and the spec no longer agree: `changeSpec`, or `createIssue` to fix the code;
- backlog issues that are now unblocked and should be promoted to Todo: `promoteIssue`.

When the session ends, superlinear checks the file against what the job was given. A proposal is refused when it has no reason, names an issue that is not open in the watched teams or is `superlinear: hands off`, promotes an issue not in the backlog, adds a relation that exists, or edits text into what it is. Each proposal's source is the pull request or commit it names, or else the job's commit range, or its session when there were no commits. The rest go through the proposal store's rules, so one pending or rejected before is not proposed again, and `auto` kinds are applied. The job's time, head, token use, and the numbers proposed and skipped are kept in the state file, and its refusals in the daemon log.

The job has no token budget of its own. Like an agent, it outlives a daemon restart: a later daemon waits for it, takes in its proposals if it ended meanwhile, or resumes its Claude session if it was interrupted, up to three times. A session that the Claude usage limit stops ends as a failed job for now; pausing and resuming it as agents will be is [SPL-26](https://linear.app/superlinear-linear/issue/SPL-26). Jobs do not count toward `maxConcurrentAgents`.

`superlinear plan` stores its proposals and runs in `~/.local/share/superlinear/planning.json`, apart from the state file that only the daemon writes; the daemon and `superlinear proposals` take them in from there, and the daemon puts them in Linear at its next poll. It refuses to start while the daemon or another `plan` runs a job for the workspace.

<a id="follow-ups"></a>
## Follow-ups from agents

Agents find bugs and missing work outside their issue. Every agent's prompt — for a new issue, a review or a conflict — tells it not to fix such work and not to create Linear issues, but to add an entry to the JSON array in `.superlinear/followups.json` at the root of its worktree:

```json
[
  {
    "title": "Status crashes on an empty state file",
    "description": "It force-unwraps the last poll, which a new state file does not have.",
    "kind": "bug",
    "evidence": "Sources/superlinear/Status.swift:42",
    "relatedIssue": "SPL-4"
  }
]
```

`kind` is `bug`, `task`, `test` or `spec`. `evidence` is the file and line, the failing command, or a log excerpt. `relatedIssue` is optional: the issue the work blocks or relates to. Before each launch, the daemon adds `/.superlinear/` to the repository's `info/exclude`, which every worktree shares, so git ignores the file.

When an agent exits, the daemon reads the file and stores each entry as a `createIssue` proposal in the team of the agent's issue. Its description has the entry's description, kind, evidence and related issue, and its source is the agent's session, issue and pull request. The new issue follows from `relatedIssue`, or else from the agent's issue, so an open issue that is the [same work](#duplicate-check), with nothing to add to it, becomes an `addRelation` proposal between the two instead. Entries that could not be proposed, as when Linear is down, stay in the file for the next agent on the issue; the rest are removed with it. A malformed file — not a JSON array of entries, an unknown `kind`, or a blank title, description or evidence — is logged, nothing in it is proposed, and it stays where it is for inspection.

Two more sources make `createIssue` proposals:

- **Failing CI on the default branch.** Each poll lists the workflow runs on the branch `origin/HEAD` names (`main` when it names none). For each workflow whose latest completed run failed, timed out or could not start, it proposes "CI fails on `<branch>`: `<workflow>`", with the run as its source, in the workspace's first `teamIds` entry or else Linear's first team. The title is the same for each run of a workflow, so while that proposal is pending, or the issue it made is open, later failures propose nothing. The daemon screens each failed run once until it restarts. A run the [GitHub Actions spending limit](lifecycle.md#spending-limit) stopped is not a failure: it proposes nothing, and the daemon reruns it when the limit is raised.
- **TODOs in merged pull requests.** When an agent's pull request merges, the daemon reads its diff, and proposes an issue for each added line with `TODO` or `FIXME` that names no issue (a line like `TODO: SPL-24` is already tracked). The title is the words after the marker; the description gives the file and line. Its source is the pull request and the agent's issue, which the new issue follows from. Pull requests merged outside the daemon's merge watch are not read.

<a id="standup"></a>
## Reviewing proposals in Linear

Proposals that need you are reviewed in Linear, where the rest of your triage happens: there is no second place to look. At each poll, the daemon puts every pending proposal in Linear, in the form its kind takes, reads your answers to those already there, and applies or rejects them. Only the answers of the API key's user count.

| Kind | In Linear | Approve | Reject |
| --- | --- | --- | --- |
| `createIssue` | The issue itself, created at once in the team's **Triage** state, with the labels `superlinear` and `superlinear: proposed`, its reason and its source, and a comment that links its [possible duplicates](#duplicate-check), if any. | Accept it from Triage, into any state. | Decline or cancel it, or mark it a duplicate. Marking it a duplicate of an issue proposes to add its text to that issue. |
| `editIssue`, `closeIssue`, `addRelation`, `promoteIssue` | A comment on the target issue, written by superlinear: what it proposes, the reason, the source, and for an edit the diff of the managed block. The issue gets the label `superlinear: proposed` while it waits. | React 👍 on the comment. | React 👎 on the comment. |
| `changeSpec` | An issue in Triage, labeled `superlinear: spec` as well, with the diff of the spec and a link to the document or the project. | Accept it from Triage. The change is applied to the document or project, and the issue completed. | Decline or cancel it, or mark it a duplicate. |
| `postProjectUpdate` | A comment on the project's overview issue, as above. | React 👍. | React 👎. |

A team with Triage off: superlinear turns Triage on when the API key may, and logs once when it may not. Then the issue is created in Backlog with the same labels; moving it out of Backlog, or removing the `superlinear: proposed` label, approves it, and canceling it rejects it. Deleting a proposed issue, or a proposal's comment, rejects it too.

Once answered, superlinear edits the comment's first line to say so, with the time: `**Applied 2026-10-17T20:31:00Z.** superlinear proposed to cancel this issue.` The `superlinear: proposed` label comes off the issue once nothing waits on it, so the issues with that label are the proposals still open: the number waiting in each workspace is in [`superlinear status`](operations.md#status), with a link to each. A rejection is recorded, so the same change is not proposed again. Each approval goes through the [rules above](#proposal-rules): one whose issue changed since it was proposed is not applied, but asked again in a new comment with a note, the old one marked superseded; a spec change goes back to Triage with a note. An issue labeled `superlinear: hands off` gets no comment: the proposal is rejected.

<a id="proposal-comments"></a>
### Questions and requests on proposals

Ask about a proposal in a comment, and superlinear answers in the comment's thread. A comment counts when you write it on a proposed issue that waits in Triage or Backlog, or as a reply in the thread of a proposal's comment. Only comments from the API key's user count. superlinear's own comments do not count: each reply it writes starts with the line `*Written by superlinear.*`, and its proposal comments start with what they propose.

For each comment, the daemon runs a short headless Claude session that only reads. It can read the code and its history in the repository's default-branch worktree, and look at pull requests and CI runs with `gh`. It cannot edit files, commit, push, open pull requests, or write to Linear or GitHub. Its prompt has the proposal (its kind, reason, source, and the text or the diff), the comments before yours, and your comment. The answer is posted as a reply under your comment. Ask "What would this cost in CI?" on a proposed CI change, and the reply estimates the minutes it adds to each run, and says on which runners.

When the comment asks for a change to the proposal, such as "make it optional" or "only for main", the session may also return new text. superlinear then edits the proposed issue's description, or the proposal's comment, and says in the reply that it did. The proposal still waits for your answer. This applies to the kinds that have text: a new issue's description, an edit's new text, a spec change, and a project update. For a closure, a relation or a promotion, the reply tells you to reject the proposal and say what you want instead.

A reply that superlinear writes with your API key does not reach your Linear inbox. So the reply also keeps the label `superlinear: proposed` on the issue, or puts it back, and the issue stays in the proposals view until you answer the proposal.

Each comment is answered once for each version of its text. The daemon records, in the state file, each comment it handled and the text the comment had then. If you edit a comment after it was answered, it is answered again, and the prompt has the old text and the new text. A change only to the comment's reactions does not count. At the first poll after an upgrade, only comments made after the proposal was put in Linear count, so old comments are not all answered at once.

The sessions run one at a time in each workspace, in the background, so a poll does not wait for them. They wait while the [Claude usage limit](lifecycle.md#claude-usage-limit) pauses sessions. A session that stops at the limit pauses Claude like any other session, and its comment is answered after the pause. Each session's token use is recorded in the state file and logged. Claude's output goes to `~/.local/share/superlinear/logs/comments-<workspace>.log`. If a comment's session fails three times, the comment is logged and left unanswered.

<a id="spec-comments"></a>
### Comments on the spec document

Proposals are checked against the workspace's spec document ([`planning.specDocumentURL`](configuration.md#planning)), so a question or a request on it is answered like one on a proposal. Each poll reads the document's comments. A new comment from the API key's user gets a read-only session. Its prompt has the document, the comment's thread, and the open issues of the watched teams, and it runs in the repository's default-branch worktree. The answer is a reply in the comment's thread.

A request to change the spec, such as "this should also cover X", becomes a `changeSpec` proposal. It goes to Triage like any other proposal, and the reply links to it. superlinear never edits the document unless you accept the proposal. Only comments made after the daemon first reads the document count. Comments on other documents, on projects and on project updates are ignored.

<a id="standup-needs-human"></a>Issues that need a human need nothing from superlinear: when you mark one Done in Linear, the issues it blocks become ready at the next poll. Holding an issue back is moving it to Backlog; the Todo order in Linear — priority, project, milestone, sort order — is the only queue order.

**Expiry:** [`proposalExpiryDays`](configuration.md#proposal-expiry-days) counts from when the proposal was put in Linear. An expired comment's first line says so; an expired Triage issue is canceled with a note.

**Migration:** at the first poll after an upgrade from a version that reviewed proposals in the terminal, every pending proposal in the state file is put in Linear as above. Those with the old trust name read as `review`.

<a id="project-updates"></a>
## Project updates

Not built yet: [SPL-13](https://linear.app/superlinear-linear/issue/SPL-13) adds them, and fills in this section.
