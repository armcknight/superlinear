# Bootstrap

How a project gets what it needs to be built by agents: its components, the files and settings they bring, the secrets they use, and the steps only a person can do.

The guide's sections here describe work that is planned. Each one that is not built yet says so, and the issue that builds it fills it in.

<a id="components"></a>
## Components

A component is a reusable part of a project: `apple-app`, and later `swift-cli`, `vapor-fly`, `supabase` and `web-frontend`. A project can use more than one, such as an Apple app and a Vapor server in one repository.

Components live in the [armcknight/templates](https://github.com/armcknight/templates) repository. Until it is published, its content is in [templates/](../templates/README.md) in this repository, where CI validates it. Each component has a directory, `components/<name>/`, with:

- `component.toml`, its [manifest](#manifests);
- `scaffold/`, files copied one time into a project, never over a file that exists, including a README with the generated "How this project is built" section's markers;
- `CLAUDE.md`, conventions for agents, which the project's `CLAUDE.md` includes.

The pieces that projects share — reusable workflows, fastlane lanes and Makefile fragments — are at the top of the templates repository. Releases are tags, `v1`, `v1.1`; projects refer to a tag, never to `main`.

The first component is `apple-app`: an iOS app, with an optional embedded watch app, a tvOS app or a macOS app. It brings the shared `test` and `beta` lanes, the `apple-test.yml` workflow for pull requests and the `apple-beta.yml` workflow for [nightly TestFlight builds](builds.md#nightly-testflight).

<a id="manifests"></a>
## Manifests

Each component's `component.toml` says:

- `detect`: how to know from its files that a repository uses the component, such as an `.xcodeproj` with an application target. Each rule is a file glob, optionally with a pattern the file must contain.
- `inputs`: the values that differ per project, such as the bundle ID and the team ID, each with an example, and `infer`: where to read it in the repository — a build setting, a key in `fastlane/Appfile`, a field in a TOML file, a file's path or a pattern in a file. An input that is not found is asked for one time.
- `secrets`: the GitHub Actions secrets by name, where each value comes from, who it is shared with, the step a person must do to make it, and how often to rotate it. See [Secrets](#secrets).
- `steps`: in order, a `check` command for each and a `fix`, which is a command or the text of a [Needs human step](#needs-human-steps).
- `shared`: the shared pieces the component uses, with their paths and the tags they changed in.
- `docs`: the anchors in this guide that explain the component, from [Anchors](anchors.md).

The [templates repository's README](../templates/README.md#the-manifest) describes each field, and [its JSON Schema](../templates/schema/component.schema.json) is the full format.

<a id="secrets"></a>
## Secrets and where they come from

Not built yet: [SPL-18](https://linear.app/superlinear-linear/issue/SPL-18) adds `superlinear bootstrap`, which sets a project's secrets from their sources, and fills in this section.

<a id="needs-human-steps"></a>
## Needs human steps

Not built yet: [SPL-18](https://linear.app/superlinear-linear/issue/SPL-18) turns the steps that need a person into Needs human issues, and fills in this section. Until then, an issue with a [human label](lifecycle.md#ready-gate) is how work is kept for a person, and the [standup](planning.md#standup-needs-human) is where you sign it off.

<a id="bootstrap-check"></a>
## `bootstrap --check`

Not built yet: [SPL-18](https://linear.app/superlinear-linear/issue/SPL-18) adds it, and fills in this section.
