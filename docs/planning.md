# Planning

How superlinear keeps the plan in Linear up to date: it proposes changes, and you approve them at a standup, or let them through on their own.

<a id="proposals"></a>
## Proposals and trust levels

superlinear can propose changes to the Linear workspace: new issues, edits, closures, relations, promotions from Backlog to Todo, spec changes, and project updates. Each proposal is kept in the state file with its kind, its target (an issue, a project, a document, or for a new issue its team), the change itself (for an edit, the old and the new text, so a diff can be shown), the reason, its source (a pull request, a commit range, an agent session with its issue and pull request, or a workflow run), when it was made, and its status: `pending`, `applied`, `rejected` or `expired`, with the reason for a rejection. [Agents' follow-ups](#follow-ups), failing CI on the default branch, and TODOs in merged pull requests make proposals today; the [daily planning job](#daily-planning) will too.

<a id="trust-levels"></a>
### Trust levels

The workspace's [`autonomy`](configuration.md#autonomy) config sets what happens to each kind:

| Level | Effect |
| --- | --- |
| `auto` | Applied at once, and still listed for review. |
| `standup` | Kept pending for you to approve or reject at a [standup](#standup). |
| `never` | Not proposed at all. |

<a id="proposal-kinds"></a>
### Kinds

| Kind | Change | Default |
| --- | --- | --- |
| `createIssue` | A new issue. | `standup` |
| `editIssue` | A new description, or managed block, for an issue. | `standup` |
| `closeIssue` | Moves an issue to its team's first canceled state. | `standup` |
| `addRelation` | Relates two issues: `blocks`, `duplicate`, `related` or `similar`. | `auto` |
| `promoteIssue` | Moves an issue from Backlog to its team's first unstarted state, such as Todo, as when its blockers are done. | `standup` |
| `changeSpec` | A new description for a project, or new content for a document. | `standup` |
| `postProjectUpdate` | Posts a project update. | `standup` |

<a id="proposal-rules"></a>
### Rules for applying a proposal

- **Its own issues are labelled.** Each issue superlinear creates gets the label `superlinear`, which it creates in the team when neither the team nor the workspace has it, and ends with a "Source" line linking to where it came from. Project updates end with the same line.
- **Your text is yours.** In an issue without the `superlinear` label, an edit changes only the managed block between `<!-- superlinear -->` and `<!-- /superlinear -->`, which Linear does not show; it adds the block at the end when there is none. The rest of the description is left exactly as it was. In an issue with the label, an edit replaces the description.
- **Hands off.** An issue with the label `superlinear: hands off` is never edited, closed, promoted or related. A proposal to change one is rejected.
- **No lost updates.** A proposal records the target's `updatedAt` when it was worked out. Before an edit, closure, promotion or spec change, superlinear reads the target again. If it changed after that time, the proposal is not applied but stays pending, sent back for review with a note, even when its kind is `auto`. A proposal without the time is checked against the old text instead. Times within a second count as the same, as the state file keeps dates to the second.
- **No duplicates.** Before a new issue is proposed, Linear's search looks for open issues in its team with the same title or a close one, by the [Sørensen–Dice coefficient](https://en.wikipedia.org/wiki/Dice-S%C3%B8rensen_coefficient) of their letter pairs, at 0.8 or more, once case and punctuation are set aside. When one is found, nothing is proposed, or, for an issue that follows from another, a `related` relation between that one and the open one. A change already pending, or rejected before, is not proposed again: the same kind and target, and for a new issue the same title, for a relation the same other issue and type.
- **Proposals expire.** A proposal still pending [`proposalExpiryDays`](configuration.md#proposal-expiry-days) days after the first [standup](#standup) that showed it expires. One no standup has shown does not expire. Applied and expired proposals drop out of the state file 30 days after; rejected ones stay, to keep the change from coming back.

<a id="audit-log"></a>
### The audit log

Each change applied is appended to `~/.local/share/superlinear/audit/<workspace>.jsonl`: the time, the proposal, and Linear's response, one JSON object a line. A failed write leaves the proposal pending, with the error, and writes nothing to the log.

`superlinear proposals [--workspace <name>]` lists each workspace's pending proposals, oldest first, then those applied, rejected or expired in the last 7 days, newest first. Each shows its ID's first 8 characters, kind, target, status, when it was made, reason and source, any rejection reason, note or error, and the change: a new issue's title and description, or a line diff for an edit.

<a id="daily-planning"></a>
## The daily planning job

Not built yet: [SPL-11](https://linear.app/superlinear-linear/issue/SPL-11) adds it, and fills in this section.

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

When an agent exits, the daemon reads the file and stores each entry as a `createIssue` proposal in the team of the agent's issue. Its description has the entry's description, kind, evidence and related issue, and its source is the agent's session, issue and pull request. The new issue follows from `relatedIssue`, or else from the agent's issue, so an open issue with a close title becomes an `addRelation` proposal between the two instead. Entries that could not be proposed, as when Linear is down, stay in the file for the next agent on the issue; the rest are removed with it. A malformed file — not a JSON array of entries, an unknown `kind`, or a blank title, description or evidence — is logged, nothing in it is proposed, and it stays where it is for inspection.

Two more sources make `createIssue` proposals:

- **Failing CI on the default branch.** Each poll lists the workflow runs on the branch `origin/HEAD` names (`main` when it names none). For each workflow whose latest completed run failed, timed out or could not start, it proposes "CI fails on `<branch>`: `<workflow>`", with the run as its source, in the workspace's first `teamIds` entry or else Linear's first team. The title is the same for each run of a workflow, so while that proposal is pending, or the issue it made is open, later failures propose nothing. The daemon screens each failed run once until it restarts.
- **TODOs in merged pull requests.** When an agent's pull request merges, the daemon reads its diff, and proposes an issue for each added line with `TODO` or `FIXME` that names no issue (a line like `TODO: SPL-24` is already tracked). The title is the words after the marker; the description gives the file and line. Its source is the pull request and the agent's issue, which the new issue follows from. Pull requests merged outside the daemon's merge watch are not read.

<a id="standup"></a>
## The standup

```sh
superlinear standup [--print] [--workspace <name>]
```

An interactive review in the terminal, run when you want: there is no schedule. It is where proposals that need you are approved, and where you sign off work only you can do. Each workspace goes through these sections in turn:

1. **Done autonomously:** what superlinear did since your last standup that you may not have seen: agents started, finished, failed or stopped; reviews addressed; conflicts resolved; issues completed in Linear after their merge; and proposals applied automatically. Not merged pull requests: superlinear never merges, so you know what you merged.
2. **Waiting on you:** open pull requests ready for review, the ones holding back the most work first: the open issues their issues block, directly and indirectly, and the pull requests stacked on them. Each stack is listed bottom first. Drafts, and pull requests an agent is working on, are left out.
3. **Proposals:** each pending proposal with its reason, source and change, with a diff for edits. Keys: `a` approves it, `e` opens the change in `$EDITOR` as JSON and shows it again, `r` rejects it and asks why, `d` or Enter defers it.
4. <a id="standup-needs-human"></a>**Needs human:** issues with a [`humanLabels`](configuration.md#human-labels) label, those blocking the most open issues, directly and indirectly, first. Keys: `d` marks it done, so the issues it blocks become ready; `e` enters a decision, added to the issue's managed block and, when [`planning.specDocumentURL`](configuration.md#planning) is set, to the end of that document; `s` or Enter skips it.
5. **Plan for today:** the issues agents start next, in the order they will: those queued, then, in `ready` mode, the ready issues not yet queued. Then the issues held, and those the last standup unblocked. Commands: `h N` holds item N, so no agent starts on it until a standup releases it with `h N` again; `u N` and `d N` move it up or down; `p bN` promotes backlog item N to Todo, or takes the promotion back. The 10 backlog issues listed are the first in Linear's order. Enter ends the section.
6. **Risks:** CI failing on the default branch, and GitHub's rate limit when less than a fifth of it is left.

`q` at any prompt quits, applying and recording nothing for that workspace. At the end of each workspace's standup, the approved proposals are applied and the other decisions written to Linear. Then the standup's time, the proposals shown and decided, the decisions, the holds and the order are recorded in `~/.local/share/superlinear/standup.json`, and a summary is printed. The daemon reads that file at each poll: it takes in the proposals' outcomes, holds issues back, and starts the queue in your order. A hold or a new order applies only to issues no agent has started on.

"Since the last standup" means since you last finished one; the first covers the last 7 days. Between standups, agents keep working on the ready queue and `auto` proposals keep being applied; other proposals wait. `superlinear status` ends with a line giving the time of the last standup and the numbers of pending proposals and issues that need a human, so you know when one is worth running.

`--print` prints sections 1, 3, 4 and 5 without prompts and records nothing, for a quick look or a script. Without `--print`, the standup needs a terminal.

The standup does not yet offer to run the daily planning job first, nor show budgets or late milestones.

<a id="project-updates"></a>
## Project updates

Not built yet: [SPL-13](https://linear.app/superlinear-linear/issue/SPL-13) adds them, and fills in this section.
