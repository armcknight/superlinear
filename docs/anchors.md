# Anchors

Stable links into the superlinear guide. Component manifests in [armcknight/templates](https://github.com/armcknight/templates), and the README sections that `superlinear bootstrap` writes, link to the headings here, not to the guide's other pages, so the guide can be reorganized without breaking those links. Each heading's anchor is its text, so do not rename one; add a new heading, and keep the old one pointing to the new place until no manifest uses it.

The templates repository's validator fails when a manifest's `docs` names an anchor that is not a heading here.

## lifecycle

How an issue becomes a pull request and is closed: the daemon picks issues, an agent works on each in its own worktree, and the merge closes the issue. See [How it works](../README.md#how-it-works).

## planning

How work is chosen: `ready` selection, blockers, human labels, and the proposals that agents and the daily planning job make for the owner to approve in the standup. See [Selection](../README.md#selection).

## components

What a component is — a reusable part of a project, such as `apple-app` or `vapor-fly` — and how its manifest, `component.toml`, describes detection, inputs, secrets, steps and the shared pieces it uses. See [the templates repository's README](https://github.com/armcknight/templates#readme).

## bootstrap

How `superlinear bootstrap` sets up a project's components from their manifests, and what it asks a person to do. Projects record their components and the pinned template tag in `.superlinear/components.toml`.

## secrets

Where each component's secrets come from (`keychain:`, `1password:` or `generate:`), who they are shared with (`team`, `app` or `repo`), and when they are rotated. Values are only ever given to `gh secret set`, never to a log, a prompt or an agent.

## builds

How projects are tested and shipped through the shared workflows and lanes: tests on each pull request, and a nightly build that uploads only when the default branch changed after the last one.

## apple-app

The `apple-app` component: iOS (with an optional embedded watch app), tvOS and macOS apps. Its `beta` lane uploads to TestFlight with the next build number and "What to Test" written from the pull requests merged since the last build. See [its directory](https://github.com/armcknight/templates/tree/main/components/apple-app).
