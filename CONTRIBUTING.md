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

## Code of conduct

Be kind, be specific, assume good faith. Maintainers will remove anyone who is not.
