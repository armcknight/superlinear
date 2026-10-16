# Planning

How superlinear keeps the plan in Linear up to date: it proposes changes, and you approve them at a standup, or let them through on their own.

<a id="proposals"></a>
## Proposals and trust levels

superlinear can propose changes to the Linear workspace: new issues, edits, closures, relations, promotions from Backlog to Todo, spec changes, and project updates. Each proposal is kept in the state file with its kind, its target (an issue, a project, a document, or for a new issue its team), the change itself (for an edit, the old and the new text, so a diff can be shown), the reason, its source (a pull request, a commit range, or an agent session), when it was made, and its status: `pending`, `applied`, `rejected` or `expired`, with the reason for a rejection. Nothing makes proposals yet; the [daily planning job](#daily-planning) and [agents' follow-ups](#follow-ups) will.

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

Not built yet: [SPL-12](https://linear.app/superlinear-linear/issue/SPL-12) adds it, and fills in this section.

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
6. **Risks:** CI failing on the default branch, GitHub's rate limit when less than a fifth of it is left, and the active [pauses](lifecycle.md#limits) with the work they hold back: Claude sessions waiting out the usage limit, and branches whose CI the GitHub Actions spending limit stopped. While Claude sessions are paused, the standup ends by offering to resume them now, as `superlinear resume` does.

`q` at any prompt quits, applying and recording nothing for that workspace. At the end of each workspace's standup, the approved proposals are applied and the other decisions written to Linear. Then the standup's time, the proposals shown and decided, the decisions, the holds and the order are recorded in `~/.local/share/superlinear/standup.json`, and a summary is printed. The daemon reads that file at each poll: it takes in the proposals' outcomes, holds issues back, and starts the queue in your order. A hold or a new order applies only to issues no agent has started on.

"Since the last standup" means since you last finished one; the first covers the last 7 days. Between standups, agents keep working on the ready queue and `auto` proposals keep being applied; other proposals wait. `superlinear status` ends with a line giving the time of the last standup and the numbers of pending proposals and issues that need a human, so you know when one is worth running.

`--print` prints sections 1, 3, 4 and 5 without prompts and records nothing, for a quick look or a script. Without `--print`, the standup needs a terminal.

The standup does not yet offer to run the daily planning job first, nor show late milestones.

<a id="project-updates"></a>
## Project updates

Not built yet: [SPL-13](https://linear.app/superlinear-linear/issue/SPL-13) adds them, and fills in this section.
