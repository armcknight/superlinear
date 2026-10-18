# Builds

How a project's changes are checked and shipped: CI on each pull request, builds for testers, and who releases.

<a id="ci"></a>
## CI

Each agent opens its pull request with `/armcknight-claude:pr --autonomous`, which waits for the pull request's CI and fixes failures until it passes. An agent that comes back for a [review](lifecycle.md#reviews) or a [conflict](lifecycle.md#conflicts) sees CI through again after it pushes.

superlinear itself reads CI in two places:

- `superlinear status` shows each open pull request's CI state, and `superlinear stats` the CI time of each task, from `gh run list`: see [Status](operations.md#status) and [Stats](operations.md#stats).
- [`superlinear status`](operations.md#status) lists CI failing on the default branch under Risks.

The CI workflows a project runs are its own, or the shared ones its [components](bootstrap.md#components) bring. An Apple app calls `ios-ci.yml` from [armcknight/workflows](https://github.com/armcknight/workflows) at its major tag, `@4`. On each pull request it runs the shared `test` lane. Before it builds, it writes the app's Arkana keys to `.env` from the repository's secrets, runs Arkana and runs XcodeGen, so the app needs both.

<a id="testflight"></a>
<a id="nightly-testflight"></a>
## TestFlight builds

Apple apps have two kinds of build for testers.

A staging build is for one pull request. A person comments `/build-staging` on the pull request, and `ios-ci.yml` checks that they can write to the repository, runs the tests, then runs the shared `stage` lane: an ad-hoc build, signed with fastlane match, read-only. It uploads the build to a private S3 bucket and comments an install link, good for 12 hours. `/refresh-staging` signs the link again, or makes a new build if the bucket has deleted the old one. When the pull request closes, its staging builds are deleted. The repository needs the variables `AWS_ROLE_ARN`, `AWS_REGION` and `S3_BUCKET`, and the secrets `MATCH_PASSWORD` and `MATCH_DEPLOY_KEY`.

A TestFlight build is a release candidate of the default branch. The owner makes it by hand, with `make deploy-beta`, on their Mac. CI never uploads to TestFlight. `make deploy-beta`:

1. runs `prepare-release rc`, from the armcknight/tools cask: it moves `CHANGELOG.md`'s Unreleased entries under the release candidate's version, raises the [build number](#build-numbers), commits, tags, pushes and makes a GitHub prerelease;
2. runs the shared `beta` lane, which signs with fastlane match, read-only, builds for the App Store, and uploads to TestFlight without waiting for processing. The internal tester group gets the build by automatic distribution;
3. keeps the output in `deploy-beta-<build number>.log`.

TestFlight's "What to Test" is the new `CHANGELOG.md` entry, so agents add an entry under Unreleased for each change testers can see, and write it for them. The `beta` lane signs in to App Store Connect with the API key in `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8_BASE64` when they are set, and needs no two-factor prompt then. The key stays in the owner's Keychain; it is never a GitHub secret.

A TestFlight upload is the owner's action. Agents never run `make deploy-beta` or the `beta` lane. See [the release rule](#release-rule).

<a id="build-numbers"></a>
## Build numbers

The build number is `CURRENT_PROJECT_VERSION` in the app's xcconfig, next to `MARKETING_VERSION`. Each `make deploy-beta` raises it by one with `prepare-release`, and commits and tags it. Every target, an embedded watch app's too, reads it from the xcconfig, so each `Info.plist`'s `CFBundleVersion` must be `$(CURRENT_PROJECT_VERSION)`, as it is by default.

`make patch`, `make minor` and `make major` raise `MARKETING_VERSION` with `vrsn` and commit it. Only the owner runs them. Agents never change the version or the build number.

<a id="release-rule"></a>
## The release rule: agents never release

Agents build, test and open pull requests. They never release: no version bumps, tags, deploys, or package or store submissions. superlinear never merges either. A person merges each pull request, and a release is a separate decision a person makes each time.

A TestFlight build is a release candidate: `make deploy-beta` tags it and makes a GitHub prerelease. Only the owner makes one. A staging build is not a release: it is for one pull request, and is gone when the pull request closes.

<a id="testflight-feedback"></a>
## TestFlight feedback

Not built yet: [SPL-20](https://linear.app/superlinear-linear/issue/SPL-20) turns testers' feedback and crash reports into proposals, and fills in this section.
