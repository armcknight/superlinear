# templates

Components: reusable parts of a project, such as an Apple app, a Swift command-line tool, a Vapor server on Fly, or a Supabase database. Each one says how to recognize a project that uses it, what it needs to know about the project, which secrets it needs and where they come from, what to check and set up, and which shared workflows, lanes and Makefile fragments it uses.

[superlinear](https://github.com/armcknight/superlinear)'s `bootstrap` command reads the components and sets projects up with them. People can also follow a manifest by hand.

This repository holds no secrets: only their names and where to get them.

## Components

| Component | What it sets up |
| --- | --- |
| [apple-app](components/apple-app) | An iOS (with an optional embedded watch app), tvOS or macOS app, tested on each pull request and uploaded to TestFlight nightly. |

## Layout

```
components/<name>/component.toml   the manifest
components/<name>/scaffold/        files copied one time into a project
components/<name>/CLAUDE.md        conventions for agents, included by projects
components/<name>/bin/             scripts the manifest's steps run
.github/workflows/                 reusable workflows (workflow_call)
fastlane/                          shared lanes, imported with import_from_git
make/                              Makefile fragments
schema/component.schema.json       the manifest's JSON Schema
scripts/validate.py                the manifest validator
```

## Releases

Releases are tags: `v1`, `v1.1`, `v2`. Projects refer to a tag — in `uses: armcknight/templates/...@v1`, `import_from_git(branch: "v1")` and `TEMPLATES_TAG = v1` — never to `main`. A change that a project must act on, such as a renamed input, a new required secret or a lane that behaves differently, takes a new major version.

## Shared pieces

| Piece | Kind | Used by | What it does |
| --- | --- | --- | --- |
| [fastlane/Fastfile](fastlane/Fastfile) | fastlane | apple-app | The `test` and `beta` lanes for `ios`, `tvos` and `mac`. |
| [.github/workflows/apple-test.yml](.github/workflows/apple-test.yml) | workflow | apple-app | Runs the `test` lane on each pull request. |
| [.github/workflows/apple-beta.yml](.github/workflows/apple-beta.yml) | workflow | apple-app | Runs the `beta` lane when the default branch changed after the last uploaded build. |
| [make/apple-app.mk](make/apple-app.mk) | make | apple-app | The `apple-app-test` and `apple-app-beta` targets. |
| [components/apple-app/scaffold/Brewfile](components/apple-app/scaffold/Brewfile) | brewfile | apple-app | The tools the lanes use. |
| [components/apple-app/bin/check-app-store-connect](components/apple-app/bin/check-app-store-connect) | script | apple-app | Checks the app record and its tester group in App Store Connect. |
| [components/apple-app/bin/check-shared-lanes](components/apple-app/bin/check-shared-lanes) | script | apple-app | Checks that `fastlane/Fastfile` uses the shared lanes. |

## The manifest

`component.toml` has these parts. [schema/component.schema.json](schema/component.schema.json) is the full format.

### `name`, `description`

The component's name, which is also its directory's name, and one sentence about what it sets up.

### `detect`

How to know that a repository uses the component, from its files only. Each rule is a `glob`, relative to the repository root (`**` matches any number of directories), with an optional `contains`: a regular expression that the contents of at least one matching file must match. The component is detected when every rule in `all` matches and, if `any` has rules, at least one of them does.

```toml
[detect]
all = [
  { glob = "fly.toml" },
  { glob = "Package.swift", contains = "github\\.com/vapor/vapor" },
]
```

### `inputs`

Values that differ for each project, such as the bundle ID or the team ID. Each has a `name`, a `description`, an `example`, an optional `default`, and `infer`: where to read the value in the repository, tried in order.

| `from` | Reads |
| --- | --- |
| `build-setting` | `key` from `xcodebuild -showBuildSettings` for the project's scheme. |
| `fastlane-config` | The first argument of the call `key` in `file`, such as `team_id("…")` in `fastlane/Appfile`. An array's values are joined with commas. |
| `toml` | The dotted `key` in the TOML `file`, such as `app` in `fly.toml`. |
| `glob` | The path of the first file that matches `glob`; with `exists = true`, `true` or `false`. |
| `regex` | The first capture group of `pattern` in the first file that matches `glob`. |

Any rule can have `map`, which replaces the value found with the value of its key, such as `{ iphoneos = "ios" }`. An input with no `infer`, or whose value is not found and has no `default`, is asked for one time.

### `secrets`

GitHub Actions secrets, by name. Each has a `description`, a `source` — `keychain:<item>`, `1password:op://<vault>/<item>/<field>`, or `generate:<kind>`, where `<kind>` is `ssh-key`, `password` or `hex32` — and a `scope`: `team` (one value for every project), `app` or `repo`. `human` is a step a person must do to get the value, with `twoFactor = true` when it needs a two-factor prompt. `rotateEvery`, such as `90d` or `1y`, is how often to make a new value.

### `steps`

Ordered. Each has an `id`, a `description`, a `check` — a shell command, run at the repository root, that exits 0 when the step is done — and a `fix`: a shell command, or `{ human = { text = "…" } }`, which becomes a Needs human issue. `scope = "app"` marks a step done one time for each app.

### `shared`

The reusable pieces of this repository that the component uses: `kind` (`workflow`, `fastlane`, `make`, `brewfile` or `script`), `path`, the `version` (tag) that has the piece in its current form, and a `description`.

### `docs`

Sections of the superlinear guide that explain the component, each with a `title` and an `anchor` listed in its [Anchors](https://github.com/armcknight/superlinear/blob/main/docs/anchors.md) page, as `<page>.md#<id>`, such as `builds.md#nightly-testflight`.

### Placeholders

Scaffold files, step commands and human texts can contain:

* `{{inputs.<name>}}`: an input's value. In `check` and `fix` commands, the value is quoted for the shell.
* `{{templates}}`: the path of a checkout of this repository at the project's tag, for the scripts in `components/<name>/bin/`.
* `{{templates.tag}}`: the project's tag, such as `v1`.

GitHub Actions expressions, `${{ … }}`, are not placeholders.

## The scaffold's README section

Each component's `scaffold/README.md` has a section between these markers:

```
<!-- superlinear:begin how-this-is-built -->
<!-- superlinear:end -->
```

`superlinear bootstrap` writes it from the manifests of the components the project uses, and changes nothing outside the markers. It has a "How this project is built" heading and:

* the components the project uses, each linked to `components/<name>` here at the pinned tag;
* each shared workflow, lane, Makefile fragment and Brewfile the project uses, linked here at the pinned tag;
* the secrets by name, never their values, with where each comes from, and the human steps;
* links to the superlinear guide's [life of an issue](https://github.com/armcknight/superlinear/blob/main/docs/lifecycle.md#overview), [planning](https://github.com/armcknight/superlinear/blob/main/docs/planning.md#proposals), [bootstrap](https://github.com/armcknight/superlinear/blob/main/docs/bootstrap.md#components) and [builds](https://github.com/armcknight/superlinear/blob/main/docs/builds.md#ci) sections, and to the components' own `docs` anchors;
* a link to the project's Linear team and, when it has one, its spec document.

## Adding a component

1. Make `components/<name>/` with `component.toml`, `CLAUDE.md` and `scaffold/README.md` with the markers.
2. Put shared pieces at the top level, add them to the manifest's `shared` and to the table above.
3. Add any new guide section to superlinear's `docs/`, with its anchor listed in `docs/anchors.md`, first.
4. Run the checks below, then tag a release.

## Checks

CI runs these on each pull request and push:

```sh
pip install -r scripts/requirements.txt
python3 scripts/validate.py                   # the manifests, against the schema and the guide's docs/anchors.md
python3 -m unittest discover -s scripts       # the validator's tests
```

and checks every link in the Markdown files with [lychee](https://github.com/lycheeverse/lychee).
