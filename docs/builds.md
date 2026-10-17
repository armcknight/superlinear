# Builds

How a project's changes are checked and shipped: CI on each pull request, builds for testers, and who releases.

<a id="ci"></a>
## CI

Each agent opens its pull request with `/armcknight-claude:pr --autonomous`, which waits for the pull request's CI and fixes failures until it passes. An agent that comes back for a [review](lifecycle.md#reviews) or a [conflict](lifecycle.md#conflicts) sees CI through again after it pushes.

superlinear itself reads CI in two places:

- `superlinear status` shows each open pull request's CI state, and `superlinear stats` the CI time of each task, from `gh run list`: see [Status](operations.md#status) and [Stats](operations.md#stats).
- The [standup](planning.md#standup) lists CI failing on the default branch under Risks.

The CI workflows a project runs are its own. Shared workflows for each kind of project are not built yet: [SPL-17](https://linear.app/superlinear-linear/issue/SPL-17) adds them.

<a id="nightly-testflight"></a>
## Nightly TestFlight builds

Not built yet: [SPL-17](https://linear.app/superlinear-linear/issue/SPL-17) adds the nightly beta workflow for Apple apps, and fills in this section.

<a id="build-numbers"></a>
## Build numbers

Not built yet: [SPL-17](https://linear.app/superlinear-linear/issue/SPL-17) adds the shared `beta` lane that sets build numbers, and fills in this section.

<a id="release-rule"></a>
## The release rule: agents never release

Agents build, test and open pull requests. They never release: no version bumps, tags, deploys, or package or store submissions. superlinear never merges either. A person merges each pull request, and a release is a separate decision a person makes each time.

Builds for testers are not releases. A nightly build for internal testers ships what is already merged, and needs no one to approve it.

<a id="testflight-feedback"></a>
## TestFlight feedback

Not built yet: [SPL-20](https://linear.app/superlinear-linear/issue/SPL-20) turns testers' feedback and crash reports into proposals, and fills in this section.
