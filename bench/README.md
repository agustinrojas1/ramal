# Ramal benchmark

A separate Mix project. It is never a dependency of the library and it measures the code in the directory above it.

```
docker compose up -d db          # from the repository root: Postgres on port 5435
cd bench
mix deps.get
mix bench                        # full profile, a few minutes
mix bench --quick                # smoke run, seconds, what CI executes
mix bench --only fork,merge      # a subset
```

`BENCH_PG_USER`, `BENCH_PG_PASSWORD`, `BENCH_PG_HOST`, `BENCH_PG_PORT` and `BENCH_PG_DATABASE` override the connection (defaults `ramal`, `ramal`, `localhost`, `5435`, `ramal_bench`). The database is created if missing and its two tables are dropped and rebuilt on every run. A run prints a table and writes every sample, plus the machine, to `bench/results/<profile>-<time>.json`.

## What is compared

All variants run the same SQL on the same server, in the same VM, over the same rows (`bench_items`: id, name, score, bucket).

| variant | what it is |
|---|---|
| `ramal` | `Ramal.branch/fork/run/aggregate/merge` over an Ash resource with `Ramal.Resource`, ETS storage |
| `copy` | one `CREATE UNLOGGED TABLE ... AS SELECT` per fork, indexed like the base. What a database that branches by copying does. |
| `delta` | one shared table keyed by `(state, id)`. A fork copies the parent's delta rows, a read is the base minus the state's rows plus the state's rows, a merge is one `UPDATE ... FROM`. The relational twin of Ramal's overlay. |
| `ash_no_branch`, `ash_base_write` | the same Ash read or write with no branch: the floor Ramal adds to |

The baselines are raw SQL through Ecto with no Ash in the path, no validations, no policies and no hooks. They are lower bounds for what an Ash-level branching layer could cost, and some of the gap in the read rows below is Ash, not Ramal: compare `ramal` with `ash_no_branch` to see what Ramal itself adds.

## Cases

* **fork**: fork a node whose overlay holds 0, 100 or 1,000 updated rows.
* **read**: a filtered read (`bucket < n`) returning about 1% (`small`) or 10% (`wide`) of the rows, from a node with that overlay.
* **write**: one update in a node with that overlay.
* **merge**: apply 100 or 1,000 updates to the base. Ramal replays each through the real update action in one transaction and checks staleness; `delta` applies them in one SQL statement.
* **fingerprint**: `Ramal.Resource.fingerprint/1` over 100, 1,000 and 20,000 records, and a `wide` read in an empty branch against the same read outside any branch.
* **tree_search**: from a root, three levels; every level forks 4 children from each kept node, changes 5 rows in each, scores each by the sum of `score` over the whole table, and keeps the best 2. Mutations are a pure function of position in the tree, so all variants do the same logical work, and the run raises if they do not find the same best score.

The full profile uses 20,000 rows and 100 buckets, 3 warm-up runs and 30 measured runs per row. Only the operation is timed; building the node, and discarding what the operation made, are not.

## Results

Run on 2026-10-22, full profile. Raw samples: [`results/published/full-20261022.json`](results/published/full-20261022.json).

Machine: Intel Xeon @ 2.10 GHz, 4 logical cores, 16 GB, a cloud sandbox, PostgreSQL 16.15 on the same host, Erlang/OTP 28, Elixir 1.19.6, Ash 3.37.0, AshPostgres 2.15.1, Ramal 0.1.0 (the code at the commit that added this file). Medians in milliseconds, p95 in parentheses.

These numbers are **indicative**. They come from one shared machine with the database on localhost, so they say nothing about network latency or a loaded server. Rerun `mix bench` on your own hardware before drawing a conclusion.

### Where Ramal wins

| case | ramal | copy | delta |
|---|---|---|---|
| fork, overlay 0 | 0.03 (0.06) | 25.63 (32.56) | 0.59 (1.26) |
| fork, overlay 100 | 0.06 (0.14) | 23.36 (33.78) | 1.41 (1.83) |
| fork, overlay 1,000 | 0.33 (0.51) | 24.77 (30.61) | 4.84 (6.43) |

A fork is a copy of a map in memory. The copy baseline pays for every row at every fork, whatever the overlay holds; the delta baseline pays for the parent's overlay, as Ramal does, plus a round trip.

### Where Ramal is level or slightly behind

| case | ash_no_branch | ramal | copy | delta |
|---|---|---|---|---|
| read small, overlay 0 | 1.17 | 1.58 | 0.72 | 1.02 |
| read small, overlay 1,000 | | 1.68 | 0.75 | 1.26 |
| write one row, overlay 0 | 2.00 (base write, rolled back) | 1.85 | 0.71 | 1.13 |
| write one row, overlay 1,000 | | 1.71 | 0.88 | 1.10 |

The overlay size does not show in a small read or in a write up to 1,000 entries. A write inside a branch costs about what the same write costs on the base, since the real action runs.

### Where Ramal loses

| case | ash_no_branch | ramal | copy | delta |
|---|---|---|---|---|
| read wide (2,000 rows), overlay 0 | 6.48 | 11.58 | 1.43 | 1.81 |
| read wide, overlay 1,000 | | 10.61 | 1.09 | 1.83 |
| merge 100 updates | | 98.33 | | 4.15 |
| merge 1,000 updates | | 968.84 | | 6.08 |
| tree search (20 forks, 100 updates, 20 scorings) | | 5,704.73 | 728.41 | 247.19 |

* **Wide reads.** Reading 2,000 rows through Ash costs 6.5 ms before any branch is involved, against 1.4 to 1.8 ms for raw SQL. Inside a branch Ramal adds about 5 ms: it fingerprints every base row (below) and sends the fingerprints to the branch process. The overlay itself adds little.
* **Merge.** Replay costs about 1 ms per change, because each change is a real action with validations, policies and changes, and the staleness check re-reads the rows. A set-based `UPDATE` is 24 to 160 times faster. That is the price of merging through the application's own rules, which a database merge cannot do.
* **Tree search.** Ramal is about 8 times slower than the copy baseline here and 23 times slower than the delta baseline, and the cause is not forking: scoring uses `Ramal.aggregate!/4`, which reads and fingerprints all 20,000 rows to sum them (about 280 ms per scoring, 20 of them per search). A workload that scores a state without scanning the table does not pay this. Making the aggregate read only what the overlay changes is tracked in [#28](https://github.com/agustinrojas1/ramal/issues/28).

### Fingerprints

| records | median ms |
|---|---|
| 100 | 0.09 |
| 1,000 | 0.72 |
| 20,000 | 28.39 |

About 1.4 microseconds per row. A `wide` read in an empty branch takes 11.93 ms against 7.30 ms for the same read with no branch, 63% more; this run is the figure behind DESIGN open question 5.

## What this is not

It is not a reproduction of the DAPLab benchmark. The article could not be fetched when this was written, so the workload is modelled on the ROADMAP's description of it (a tree search that keeps forking promising partial states, mutates, queries and prunes) and none of its figures are quoted. It compares one Postgres schema at one size on one machine; Neon, Dolt and other branching databases are not measured.
