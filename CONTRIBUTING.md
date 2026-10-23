# Contributing to Ramal

Thanks for looking. Ramal is pre-alpha, so the most useful contributions right now are design review, tests that break the overlay, and reports of Ash features the hooks do not handle. Read [docs/DESIGN.md](docs/DESIGN.md) first; the section "How reads are patched" is the one that decides whether a change is correct.

## Setup

```bash
mise install                     # Erlang and Elixir pinned in mise.toml
docker compose up -d db          # Postgres 16 on port 5435
mix deps.get
mix ci                           # format, compile --warnings-as-errors, credo, tests
```

## Ground rules

Everything in [CLAUDE.md](https://github.com/agustinrojas1/ramal/blob/main/CLAUDE.md) applies to humans too: small branches, one topic per PR, `mix ci` green, a changelog line for every user-facing change, docs in the same PR as the code.

## Reporting a bug

Open an issue with the resource definition, the action, the call inside the branch, what you expected the branch to see, and what it saw. A failing test in `test/` is the best report.

## Proposing a design change

Open an issue first. If we agree, the PR adds an ADR under `docs/adr/` and updates `docs/DESIGN.md`.

## Releasing

A release is a pull request; the rest is `.github/workflows/release.yml`.

1. A PR bumps `@version` in `mix.exs` and in `ramal_live/mix.exs` (the two packages share a version), turns `Unreleased` in `CHANGELOG.md` into the version with its date, and updates the install snippets: `{:ramal, "~> X.Y.0"}` in the README install section, and `{:ramal, ...}` and `{:ramal_live, ...}` in `ramal_live/README.md` and `RamalLive`'s module doc. Run `mix hex.build` and `mix docs` and read the file list and dependencies `hex.build` prints. The package ships `lib`, `mix.exs`, the README, the license, the changelog, the logo and the agent rules; nothing under `priv/` or `test/`.
2. When it merges, CI runs on `main`. Once it has passed, the Release workflow (it starts only from a successful CI run of a push to `main`) sees a version in `mix.exs` with no GitHub release. It checks again that a CI run of that commit succeeded, creates the tag `vX.Y.Z` on that commit (the docs link to source at that tag) and a GitHub release whose notes are the changelog section, then the `publish` job publishes `ramal` to Hex, then `ramal_live` once Hex lists `ramal` (it runs with `RAMAL_LIVE_HEX=1`, which makes it depend on the published `ramal`; the `mix.lock` change that makes is never committed). Every step first checks what already exists, so a push that does not bump the version does nothing, and a run that failed half way is finished by running the workflow again.
3. **Running it by hand.** Actions > Release > Run workflow, with the branch set to `main`. A run from any other branch does nothing, and a commit without a successful CI run is refused, so a red `main` is never tagged or published.
4. **The Hex key.** The publish steps need a secret `HEX_API_KEY`: a Hex API key with write access to both packages (`mix hex.user key generate`, or Hex's dashboard). Keep it in an environment, not a repository secret: Settings > Environments > New environment `hex`, under "Deployment branches and tags" choose "Selected branches and tags" and add `main`, then add `HEX_API_KEY` as an environment secret (and delete any repository secret of that name). Only the `publish` job uses the environment, and only the two `hex.publish` steps and the check that the key exists read the secret, so checkout, `deps.get` and `hex.build` run without it. Without the secret the workflow still tags and releases, skips the Hex steps with a warning, and publishes when it is run again after the secret exists.
5. **Actions are pinned to commit SHAs** (the version is in a comment). To update one, change the SHA and the comment together in a PR.

By hand, with a Hex account: tag the merge commit, then `mix hex.publish` inside the repository and `RAMAL_LIVE_HEX=1 mix deps.get`, `mix hex.build`, `mix hex.publish` inside `ramal_live/` after `ramal` is on Hex. 0.2.0 was published this way. The install snippets moved into the release PR from 0.3.0 on, so that they are right the moment the packages are on Hex.

## Code of conduct

Participation is governed by the [Code of Conduct](https://github.com/agustinrojas1/ramal/blob/main/CODE_OF_CONDUCT.md): be kind, be specific, assume good faith. Maintainers will remove anyone who is not. Security reports go through [SECURITY.md](https://github.com/agustinrojas1/ramal/blob/main/SECURITY.md), never a public issue.
