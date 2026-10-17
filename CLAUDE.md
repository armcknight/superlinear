# superlinear

A macOS launchd daemon, written in Swift, that starts Claude Code agents for Linear issues. See the [README](README.md) for an overview and [the guide](docs/index.md) for the details.

## Build and test

- `make build` builds, `make test` runs the unit tests.
- `make check-docs` checks that the relative links and anchors in the README, this file and `docs/` resolve. CI runs it.

## Documentation

- Every change to behavior updates the matching page in `docs/`, in the same pull request:
  - selection, the ready gate, agents, pull requests, reviews, conflicts, merges: [`docs/lifecycle.md`](docs/lifecycle.md);
  - proposals, trust levels, the planning job, follow-ups, reviewing proposals in Linear, project updates: [`docs/planning.md`](docs/planning.md);
  - components, manifests, secrets, `bootstrap`: [`docs/bootstrap.md`](docs/bootstrap.md);
  - CI, TestFlight builds, build numbers, releases, TestFlight feedback: [`docs/builds.md`](docs/builds.md);
  - config keys and files: [`docs/configuration.md`](docs/configuration.md);
  - installing and running the daemon, `status`, make targets: [`docs/operations.md`](docs/operations.md).
- When a change builds a feature whose section says "Not built yet", replace that line with the description.
- The README stays an overview with links. Details go in `docs/`.
- Do not rename or remove an anchor (`<a id="…"></a>`): other repositories link to them. Give each new section that others may link to an anchor, and list it in [`docs/anchors.md`](docs/anchors.md).
- Add user-visible changes to `CHANGELOG.md` under Unreleased.
