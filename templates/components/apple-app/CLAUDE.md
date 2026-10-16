# apple-app

This project is an Apple app built with the `apple-app` component from [armcknight/templates](https://github.com/armcknight/templates). `.superlinear/components.toml` has the tag it is pinned to.

## Building and testing

* `make test`, or `bundle exec fastlane <platform> test`, runs the tests. CI runs the same lane on each pull request through the shared `apple-test.yml` workflow.
* `make beta`, or `bundle exec fastlane <platform> beta`, uploads a build to TestFlight. Do not run it unless you are asked to: it publishes a build to testers. CI runs it nightly through the shared `apple-beta.yml` workflow.
* `<platform>` is `ios`, `tvos` or `mac`. An iOS app's embedded watch app builds with it.

## Rules

* The `test` and `beta` lanes come from the templates repository; `fastlane/Fastfile` imports them with `import_from_git`. Do not define lanes with those names in this project, and do not copy the shared lanes into it. To change them, change the templates repository and move this project to its new tag.
* Settings for the shared lanes are the `APPLE_APP_*` values at the top of `fastlane/Fastfile`.
* Do not set the build number by hand. The `beta` lane sets `CURRENT_PROJECT_VERSION` to the latest TestFlight build number plus one, for every target. Each `Info.plist`'s `CFBundleVersion` must stay `$(CURRENT_PROJECT_VERSION)`.
* Pull request titles become TestFlight's "What to Test" text, so write them for testers.
* Each uploaded build is tagged `beta/<platform>/<build number>`. Do not delete or move those tags: the nightly build uses them to skip a commit it already uploaded, and to list the pull requests merged since.
* Signing uses fastlane match, read-only. Do not create or change certificates or profiles.
* Never print, log or commit a secret's value. The secrets are named in the README's "How this project is built" section.

## Further reading

* [Builds](https://github.com/armcknight/superlinear/blob/main/docs/anchors.md#builds)
* [The apple-app component](https://github.com/armcknight/superlinear/blob/main/docs/anchors.md#apple-app)
