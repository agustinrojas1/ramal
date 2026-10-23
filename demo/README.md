# Ramal demo

A guided tour you run on your own machine. It opens branches of a small farm's data, changes them in different ways,
diffs them, merges one, gets another refused as stale, and shows a merge that fails halfway and leaves Postgres exactly as
it was. Every step prints what it is about to do, then what came back.

It installs `ramal` from [Hex](https://hex.pm/packages/ramal), the same package your app would use, and runs against a real
Postgres through AshPostgres. It takes about a minute to read if you press Enter through it, and nothing in it needs an
Ash project of your own.

## What you need

- **Elixir 1.18 or newer** with a recent Erlang/OTP. The repository pins `1.19.6` and OTP 28 in `mise.toml`, so
  `mise install` from the repository root gets you exactly that. Any Elixir 1.18+ works.
- **Postgres 14 or newer.** The quickest way is Docker; the compose file in this folder starts one on port 5436.
  Without Docker, [use your own Postgres](#using-your-own-postgres).
- Internet on the first run, to fetch and compile the dependencies. Compiling Ash is memory-hungry (several GB at its peak), so close big apps if the first run gets killed; it is cached afterwards.

## Run it

From the repository root:

```sh
git clone https://github.com/agustinrojas1/ramal && cd ramal   # if you do not have it yet

docker compose -f demo/docker-compose.yml up -d              # Postgres on localhost:5436
elixir demo/walkthrough.exs                                  # press Enter between chapters
```

The first run downloads and compiles Ash and friends, which takes a couple of minutes. You will see some compiler warnings
about modules such as `Igniter` and `Owl` from the Ash packages; they are optional code paths the demo does not use. Later
runs start in a few seconds because Mix caches the build.

Add `--fast` to print everything without waiting for Enter:

```sh
elixir demo/walkthrough.exs --fast
```

The script drops and recreates three tables (`paddocks`, `herds`, `moves`) in the `ramal_demo` database on every run, so
you can run it as often as you like. It touches nothing else.

When you are done: `docker compose -f demo/docker-compose.yml down -v`.

## Run it in Livebook

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fagustinrojas1%2Framal%2Fblob%2Fmain%2Fdemo%2Framal_tour.livemd)

[`ramal_tour.livemd`](ramal_tour.livemd) is the same story as a [Livebook](https://livebook.dev) notebook: one section per
chapter, with the explanation next to the cell that runs it, and cells you can edit and run again. It is one
self-contained file (the farm is defined in its setup cells), so the badge opens it from GitHub without a clone. It needs
the same Postgres as the script; start it with `docker compose -f demo/docker-compose.yml up -d`. If Livebook runs in
Docker, `localhost` is its container: set `RAMAL_PG_HOST=host.docker.internal`, or edit the connection cell.

It installs `ramal ~> 0.4.0` from Hex and falls back to the checkout when it is opened from one and that version is not
published. `RAMAL_TOUR_SOURCE=path` uses the checkout on purpose. The cells carry over state, so run them from top to
bottom; "Reconnect and setup" starts over.

To check the notebook without a browser, `elixir demo/run_tour_headless.exs` runs its cells in order the way Livebook does
and stops at the first one that fails. If you change `farm.exs` or `tour.exs`, change the notebook with them: the farm and the
helpers are copied into it.

## The story

A farm has four paddocks, each with a capacity, and four herds. Herd R7 is crowding paddock L07. Someone wants to try moving
it. The chapters, in order:

| # | Chapter | What you see |
|---|---|---|
| 1 | The farm | The starting data, in Postgres. |
| 2 | Open a branch and change things inside it | Branch A moves R7 to L18 with the real `move` action. A read inside the branch sees the move; a read outside, and plain SQL, do not. A visitor is refused by the action's policy and an over-full paddock is refused by its validation, both inside the branch. |
| 3 | Diff | `Ramal.diff/1` lists the changes, computed without querying Postgres. The audit row that the `move` action writes is part of the diff. |
| 4 | Fork, and try an alternative next to it | A2 forks A and adds a second move without touching A. Branch B tries a different destination for R7. Three branches are open at once. |
| 5 | Count and sum inside a branch | `Ramal.aggregate/4` answers "how many head per paddock?" exactly, inside a branch, without reading the whole table. Next to it, `Ash.count!` inside the branch gives the wrong answer, which is the one thing to know about aggregates. |
| 6 | Merge | A is replayed through the real actions in one transaction. Postgres changes, and the audit row appears once. |
| 7 | Stale branches are refused | B read R7 before A moved it, so merging B is refused. Nothing is written. |
| 8 | A merge is all or nothing | Branch C creates a herd and moves another into L22. Meanwhile somebody fills L22 directly in the database. The merge replays the first step, fails on the second, and rolls both back. |
| 9 | Propose, review, approve | An agent proposes a recount, a person reads the diff and approves it, and the decision is recorded on the branch. |
| 10 | Where the farm ended up | The final data and the status of every branch. |

Each chapter heading ends with the line of [`tour.exs`](tour.exs) where it starts, so you can read the code next to the
output. The farm itself (three Ash resources, a policy, a validation, an action with an after-hook) is in
[`farm.exs`](farm.exs). It is an ordinary Ash app; the only Ramal line in each resource is `extensions: [Ramal.Resource]`.

A taste of the output (colours omitted):

```text
━━ 2. Open a branch and change things inside it (tour.exs:44)
   A read inside the branch sees the move:
     herd  head  paddock
     R7    30    L18
     ...
   The same read outside the branch, and Postgres itself with plain SQL, see nothing:
     R7    30    L07
     moves logged in Postgres: 0
   ✓ branch A holds the change; the database is untouched
   ✗ a visitor was refused: not authorized (the :move policy needs a manager)
   ✗ the move was refused: paddock L31 holds 45 head and already has 40
```

## See it in a browser

`ramal_live` is a LiveView page that shows branches as columns, each with its diff, and buttons to fork, merge and discard.
The farm demo for it opens four branches that each move R7 to a different paddock, and merging one makes the others stale.
It finds the Postgres container above by itself (it tries port 5436, then 5435) and uses its own `ramal_dev` database:

```sh
elixir ramal_live/examples/farm_demo.exs
```

Open <http://localhost:4000> and press "Explore 4 alternatives". The first run compiles Phoenix on top of the dependencies
above, so allow a few more minutes.

## Using your own Postgres

Any Postgres 14+ works. The script connects as a user that may create databases and creates `ramal_demo` when it is missing.

| Variable | Default |
|---|---|
| `RAMAL_PG_HOST` | `localhost` |
| `RAMAL_PG_PORT` | `5436` |
| `RAMAL_PG_USER` | `ramal` |
| `RAMAL_PG_PASSWORD` | `ramal` |
| `RAMAL_PG_DATABASE` | `ramal_demo` |

```sh
RAMAL_PG_PORT=5432 RAMAL_PG_USER=postgres RAMAL_PG_PASSWORD=postgres elixir demo/walkthrough.exs
```

If the script cannot reach Postgres it says so and stops before changing anything.

## Running it against a checkout

By default the demo installs the published `ramal ~> 0.4.0`, and uses the checkout you run it from when that version is not on Hex. If you are working on Ramal and want to see your changes in the
walkthrough, set `RAMAL_DEMO_SOURCE=path`, which uses the checkout you are running from:

```sh
RAMAL_DEMO_SOURCE=path elixir demo/walkthrough.exs
```

## Things to try

- Change a paddock's `capacity_head` in `farm.exs` and watch which chapter starts refusing.
- In chapter 7, merge with `on_stale: :ignore` and see the replay run again against the new data.
- Lower R12's head count in chapter 8 so the merge fits, and watch it succeed.
- Read [`docs/DESIGN.md`](../docs/DESIGN.md) for how a branch works and [`README.md`](../README.md) for what it cannot do.
