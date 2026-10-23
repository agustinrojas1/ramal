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
* **diff**: `Ramal.diff/1` of a node whose overlay holds 100 or 1,000 updated rows. Only Ramal has this case: the baselines have no diff that needs no query. The run raises unless the diff holds one change per updated row.
* **read_other**: a read of a second resource the node never wrote to (`Bench.Note`, 20 rows), in a node whose overlay holds 1,000 or 10,000 updated `Bench.Item` rows, next to the same read with no branch. It shows what the overlay of other resources costs a read.
* **aggregate**: the sum of `score` over the whole table in a node with that overlay (`Ramal.aggregate!/4` for `ramal`), next to `ash_no_branch`, the same sum with no branch at all.
* **read**: a filtered read (`bucket < n`) returning about 1% (`small`) or 10% (`wide`) of the rows, from a node with that overlay.
* **write**: one update in a node with that overlay.
* **merge**: apply 100 or 1,000 updates to the base. Ramal replays each through the real update action in one transaction and checks staleness; `delta` applies them in one SQL statement.
* **fingerprint**: `Ramal.Resource.fingerprint/1` over 100, 1,000 and 20,000 records, and a `wide` read in an empty branch against the same read outside any branch.
* **tree_search**: from a root, three levels; every level forks 4 children from each kept node, changes 5 rows in each, scores each by the sum of `score` over the whole table, and keeps the best 2. Mutations are a pure function of position in the tree, so all variants do the same logical work, and the run raises if they do not find the same best score.

The full profile uses 20,000 rows and 100 buckets, 3 warm-up runs and 30 measured runs per row. Only the operation is timed; building the node, and discarding what the operation made, are not.

## Results

Run on 2026-10-22, full profile, after fast aggregates (issue [#28](https://github.com/agustinrojas1/ramal/issues/28), [ADR 0013](../docs/adr/0013-aggregate-delta.md)). Raw samples: [`results/published/full-20261022-after-fast-aggregates.json`](results/published/full-20261022-after-fast-aggregates.json). Every table below comes from that one run, on one machine, at one commit.

Machine: Intel Xeon @ 2.10 GHz, 4 logical cores, 16 GB, a cloud sandbox, PostgreSQL 16.15 on the same host, Erlang/OTP 28, Elixir 1.19.6, Ash 3.37.0, AshPostgres 2.15.1, Ramal 0.1.0 (the code at commit `2f31044`, the one that merged #37). Medians in milliseconds, p95 in parentheses.

The run before fast aggregates, on the same kind of sandbox and the same versions, is kept as [`results/published/full-20261022.json`](results/published/full-20261022.json). Only the tree search changed because of the library; the other cases moved together with the baselines (the plain-Ash floor, the copy and delta variants), which is the sandbox varying between runs, not #37.

These numbers are **indicative**. They come from one shared machine with the database on localhost, so they say nothing about network latency or a loaded server. Rerun `mix bench` on your own hardware before drawing a conclusion.

### Where Ramal wins

| case | ramal | copy | delta |
|---|---|---|---|
| fork, overlay 0 | 0.04 (0.06) | 20.20 (27.67) | 0.27 (0.69) |
| fork, overlay 100 | 0.06 (0.11) | 19.66 (23.95) | 0.92 (1.26) |
| fork, overlay 1,000 | 0.34 (0.46) | 19.65 (25.47) | 3.70 (4.15) |

A fork is a copy of a map in memory. The copy baseline pays for every row at every fork, whatever the overlay holds; the delta baseline pays for the parent's overlay, as Ramal does, plus a round trip.

### Where Ramal is level or slightly behind

| case | ash_no_branch | ramal | copy | delta |
|---|---|---|---|---|
| read small, overlay 0 | 0.90 | 1.25 | 0.50 | 0.75 |
| read small, overlay 1,000 | | 1.42 | 0.53 | 0.82 |
| write one row, overlay 0 | 1.24 (base write, rolled back) | 0.80 | 0.52 | 0.71 |
| write one row, overlay 1,000 | | 0.95 | 0.57 | 0.62 |
| tree search (20 forks, 100 updates, 20 scorings) | | 183.27 | 586.48 | 171.99 |

The overlay size does not show in a small read or in a write up to 1,000 entries. A write inside a branch costs about what the same write costs on the base, since the real action runs.

* **Tree search.** Ramal takes 183 ms for the whole search, 3.2 times faster than the copy baseline and 7% slower than the delta baseline (172 ms). The delta baseline is the relational twin of Ramal's overlay and the practical floor for this workload, so being within a few percent of it is the result to expect, not a win over it.

### Where Ramal loses

| case | ash_no_branch | ramal | copy | delta |
|---|---|---|---|---|
| read wide (2,000 rows), overlay 0 | 5.54 | 9.59 | 0.93 | 1.42 |
| read wide, overlay 1,000 | | 10.13 | 0.91 | 1.48 |
| merge 100 updates | | 67.25 | | 2.60 |
| merge 1,000 updates | | 655.10 | | 4.47 |

* **Wide reads.** Reading 2,000 rows through Ash costs 5.5 ms before any branch is involved, against 0.9 to 1.5 ms for raw SQL. Inside a branch Ramal adds about 4 to 5 ms: it fingerprints every base row (below) and sends the fingerprints to the branch process. The overlay itself adds little.
* **Merge.** Replay costs about 0.7 ms per change, because each change is a real action with validations, policies and changes, and the staleness check re-reads the rows. A set-based `UPDATE` is 26 to 147 times faster. That is the price of merging through the application's own rules, which a database merge cannot do.

### Before and after fast aggregates

The tree search is the case issue #28 was opened for, and it is closed. Scoring a state used `Ramal.aggregate!/4`, which read and fingerprinted all 20,000 rows to sum them; it now has the database sum the rows the overlay does not touch and reads only the overlaid ones.

| tree search, median ms | ramal | copy | delta | ramal / delta |
|---|---|---|---|---|
| before (`full-20261022.json`) | 5,704.73 | 728.41 | 247.19 | 23.1 |
| after (`full-20261022-after-fast-aggregates.json`) | 183.27 | 586.48 | 171.99 | 1.07 |

Ramal is 31 times faster than before. The two baselines are also lower in the second run (by 20% and 30%), because they were measured in a different run of a shared sandbox, so compare the last column, which cancels that out, rather than the absolute times across rows. The benchmark raises if the variants disagree on the best score, and none did.

### Fingerprints

| records | median ms |
|---|---|
| 100 | 0.08 |
| 1,000 | 0.66 |
| 20,000 | 22.12 |

About 1.1 microseconds per row. A `wide` read in an empty branch takes 9.88 ms against 5.93 ms for the same read with no branch, 67% more; this run is the figure behind DESIGN open question 5.

## Memory

`mix bench.memory` fills a branch with updated rows (read first, then updated, so the branch keeps the row as the database gave it and as the update left it) plus 200 created ones, and prints what the branch costs in the three places it lives in: the heap of its process (`heap words`, and `after reload` for the process that loaded the branch back from storage), the ETS table of `Ramal.Storage.ETS` (`ETS words`), and the JSON that `Ramal.Storage.Postgres` stores. The row is `Bench.Row`: seven attributes with timestamps, two relationships and an aggregate. Heap words are `:erts_debug.size/1` of what the process holds, which counts a term shared by many rows once, as the heap does.

Run on 2026-10-23 in a cloud sandbox, Erlang/OTP 25, Elixir 1.18.4, Ash 3.37.0. The words are exact for the term, so they do not vary between runs.

| rows updated | heap words, 0.3.0 | heap words, after sharing terms | after a reload, 0.3.0 | after a reload, after sharing terms |
|---|---|---|---|---|
| 100 | 80,328 | 61,452 | 115,080 | 68,143 |
| 1,000 | 427,860 | 269,619 | 614,712 | 291,610 |
| 5,000 | 1,972,202 | 1,194,788 | 2,835,054 | 1,284,779 |

## What this is not

It is not a reproduction of the [DAPLab benchmark](https://daplab.cs.columbia.edu/general/2026/05/26/branchable-databases-arent-ready-for-agentic-workloads.html) (BranchBench). The workload is modelled on the workload the article focuses on, a Monte Carlo tree search that keeps forking promising partial states, mutates, queries and prunes; ours is a fixed-shape tree search, not MCTS, and it does not use their harness, schemas or step counts. The article reports that Neon finished 33 of 1,000 steps before hitting its active branch limit and that Dolt finished 170 steps before a two-hour timeout; those are their figures from their harness, cited here and deliberately kept out of the tables above, which were not measured the same way. It compares one Postgres schema at one size on one machine; Neon, Dolt and other branching databases are not measured.
