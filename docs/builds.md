# Builds

How a project's changes are checked and shipped: CI on each pull request, builds for testers, and who releases.

<a id="ci"></a>
## CI

Each agent opens its pull request with `/armcknight-claude:pr --autonomous`, which waits for the pull request's CI and fixes failures until it passes. An agent that comes back for a [review](lifecycle.md#reviews) or a [conflict](lifecycle.md#conflicts) sees CI through again after it pushes.

superlinear itself reads CI in two places:

- `superlinear status` shows each open pull request's CI state, and the CI time of each task, from `gh run list`: see [Status](operations.md#status).
- The [standup](planning.md#standup) lists CI failing on the default branch under Risks.

The CI workflows a project runs are its own, or the shared ones its [components](bootstrap.md#components) bring: an Apple app calls `apple-test.yml` from the templates repository on each pull request, which runs the shared `test` lane.

<a id="nightly-testflight"></a>
## Nightly TestFlight builds

An Apple app calls the templates repository's `apple-beta.yml` workflow nightly, and by hand. It runs the shared `beta` lane, which:

1. signs with fastlane match, read-only, through an App Store Connect API key with the App Manager role;
2. builds with the next [build number](#build-numbers);
3. writes TestFlight's "What to Test" from the titles of the pull requests merged since the last build, so pull request titles are written for testers;
4. uploads to TestFlight without waiting for processing — the internal tester group gets the build by automatic distribution;
5. tags the commit `beta/<platform>/<build number>`.

A nightly run whose commit already has that tag uploads nothing: a build is made only when the default branch changed after the last one. A run by hand always uploads. The schedule is turned on after the first run by hand has put a build in TestFlight. Do not delete or move the `beta/` tags; the next build reads them.

<a id="build-numbers"></a>
## Build numbers

The shared `beta` lane sets each build's number to the latest build number in TestFlight for the app and platform, plus one. It gives it to every target, an embedded watch app's too, as `CURRENT_PROJECT_VERSION`, so each `Info.plist`'s `CFBundleVersion` must be `$(CURRENT_PROJECT_VERSION)`, as it is by default. Projects do not set or commit build numbers.

<a id="release-rule"></a>
## The release rule: agents never release

Agents build, test and open pull requests. They never release: no version bumps, tags, deploys, or package or store submissions. superlinear never merges either. A person merges each pull request, and a release is a separate decision a person makes each time.

Builds for testers are not releases. A nightly build for internal testers ships what is already merged, and needs no one to approve it.

<a id="testflight-feedback"></a>
## TestFlight feedback

Not built yet: [SPL-20](https://linear.app/superlinear-linear/issue/SPL-20) turns testers' feedback and crash reports into proposals, and fills in this section.
