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

Run on 2026-10-23, full profile, on Ramal 0.6.1 (commit `1f32373`). Raw samples: [`results/published/full-20261023.json`](results/published/full-20261023.json). Every table in this section comes from that one run, except where it says otherwise.

Machine: Intel Xeon @ 2.10 GHz, 4 logical cores, 16 GB, a cloud sandbox, PostgreSQL 16.15 on the same host, Erlang/OTP 28, Elixir 1.19.6, Ash 3.37.0, AshPostgres 2.15.1. Medians in milliseconds, p95 in parentheses.

**Noise.** The sandbox is shared, and the same case moves by tens of percent between runs, in the baselines too. A second run of `fork`, `merge` and `tree_search` a few minutes later ([`subset-20261023-rerun.json`](results/published/subset-20261023-rerun.json)) gave a tree search of 266 ms for Ramal, 276 ms for the delta table and 890 ms for table copies (first run: 280, 279, 873), and a fork at overlay 1,000 of 3.2 ms (first run: 2.7). The run of 2026-10-22 under 0.1 ([`full-20261022-after-fast-aggregates.json`](results/published/full-20261022-after-fast-aggregates.json), kept below) measured the same tree search at 183 / 172 / 586 ms on a faster moment of the same kind of sandbox, so compare variants inside a run, and the ratio to the delta table across runs, not absolute times across runs. These numbers are **indicative**: one shared machine with the database on localhost says nothing about network latency or a loaded server. Rerun `mix bench` on your own hardware before drawing a conclusion.

### Where Ramal wins

| case | ramal | copy | delta |
|---|---|---|---|
| fork, overlay 0 | 0.05 (0.07) | 31.41 (39.58) | 0.33 (0.85) |
| fork, overlay 100 | 0.32 (0.56) | 33.27 (41.26) | 1.75 (2.45) |
| fork, overlay 1,000 | 2.73 (3.81) | 29.43 (39.35) | 7.10 (7.95) |

A fork is a copy of a map in memory. The copy baseline pays for every row at every fork, whatever the overlay holds; the delta baseline pays for the parent's overlay, as Ramal does, plus a round trip. A fork at overlay 1,000 took 0.34 ms in the 2026-10-22 run and takes 2.7 to 3.2 ms now; the bench cases were reworked since (`diff`, `aggregate` and `read_other` were added and a harness fix made the copy variant start from the base table, #81), and I did not investigate the difference. `diff` is new in this table: 0.28 ms at 100 changes and 2.61 ms at 1,000, computed without a query.

### Where Ramal is level or slightly behind

| case | ash_no_branch | ramal | copy | delta |
|---|---|---|---|---|
| read small, overlay 0 | 1.66 | 1.80 | 0.65 | 1.24 |
| read small, overlay 1,000 | | 2.11 | 1.13 | 1.00 |
| write one row, overlay 0 | 1.45 (base write, rolled back) | 1.18 | 0.46 | 1.15 |
| write one row, overlay 1,000 | | 1.55 | 0.37 | 1.02 |
| read of another resource, overlay 10,000 | 0.64 | 0.73 | | |
| tree search (20 forks, 100 updates, 20 scorings) | | 280.36 | 872.63 | 279.20 |

The overlay size shows little in a small read or in a write up to 1,000 entries, and not at all in a read of a resource the branch never wrote (the second-to-last row). A write inside a branch costs about what the same write costs on the base, since the real action runs.

* **Tree search.** Ramal takes 280 ms for the whole search, 3.1 times faster than the copy baseline and level with the delta baseline (279 ms; 266 against 276 in the second run). The delta baseline is the relational twin of Ramal's overlay and the practical floor for this workload, so being level with it is the result to expect, not a win over it.

### Where Ramal loses

| case | ash_no_branch | ramal | copy | delta |
|---|---|---|---|---|
| read wide (2,000 rows), overlay 0 | 10.22 | 9.20 | 1.80 | 1.94 |
| read wide, overlay 100 | | 18.17 | 1.71 | 1.93 |
| read wide, overlay 1,000 | | 15.43 | 1.76 | 2.14 |
| aggregate (sum over the table), overlay 100 | 2.29 | 8.18 | 1.88 | 3.56 |
| aggregate, overlay 1,000 | | 31.81 | 2.49 | 5.98 |
| merge 100 updates | | 41.05 | | 2.74 |
| merge 1,000 updates | | 436.17 | | 6.83 |

* **Wide reads.** Reading 2,000 rows through Ash costs about 10 ms before any branch is involved in this run (5.5 ms in the 2026-10-22 run: the machine was faster then), against 2 ms for raw SQL. Inside a branch with no changes Ramal adds a few ms (the fingerprints, below); once the overlay holds 100 or 1,000 rows of that table it adds 6 to 9 ms more, because the read has to patch, filter and sort the rows in memory.
* **Aggregates.** `Ramal.aggregate/4` grows with the overlay: 2.4 ms with none, 8.2 ms with 100 entries and 31.8 ms with 1,000. About 8 ms of each query at 1,000 is Ash handling a filter with a 1,000-key `in` list, which Ramal cannot avoid without changing what the aggregate means for filters it cannot evaluate. It is still independent of the table size, which is what the tree search needs.
* **Merge.** Replay costs about 0.4 ms per change (0.7 ms in the 2026-10-22 run), because each change is a real action with validations, policies and changes, and the staleness check re-reads the rows. A set-based `UPDATE` is 15 to 64 times faster. That is the price of merging through the application's own rules, which a database merge cannot do.

### Before and after fast aggregates

This subsection is the 2026-10-22 run, on Ramal 0.1.0 at commit `2f31044`, kept as the record of what issue #28 fixed. Its raw samples are [`results/published/full-20261022.json`](results/published/full-20261022.json) (before) and [`results/published/full-20261022-after-fast-aggregates.json`](results/published/full-20261022-after-fast-aggregates.json) (after).

The tree search is the case issue #28 was opened for, and it is closed. Scoring a state used `Ramal.aggregate!/4`, which read and fingerprinted all 20,000 rows to sum them; it now has the database sum the rows the overlay does not touch and reads only the overlaid ones.

| tree search, median ms | ramal | copy | delta | ramal / delta |
|---|---|---|---|---|
| before (`full-20261022.json`) | 5,704.73 | 728.41 | 247.19 | 23.1 |
| after (`full-20261022-after-fast-aggregates.json`) | 183.27 | 586.48 | 171.99 | 1.07 |

Ramal is 31 times faster than before. The two baselines are also lower in the second run (by 20% and 30%), because they were measured in a different run of a shared sandbox, so compare the last column, which cancels that out, rather than the absolute times across rows. The benchmark raises if the variants disagree on the best score, and none did.

### Fingerprints

| records | median ms |
|---|---|
| 100 | 0.06 |
| 1,000 | 0.30 |
| 20,000 | 13.40 |

About 0.7 microseconds per row (1.1 in the 2026-10-22 run). A `wide` read in an empty branch takes 10.00 ms against 8.67 ms for the same read with no branch, 15% more in this run (67% in the 2026-10-22 run, where the machine and the code were different); this is the figure behind DESIGN open question 5.

## Memory

`mix bench.memory` fills a branch with updated rows (read first, then updated, so the branch keeps the row as the database gave it and as the update left it) plus 200 created ones, and prints what the branch costs in the three places it lives in: the heap of its process (`heap words`, and `after reload` for the process that loaded the branch back from storage), the ETS table of `Ramal.Storage.ETS` (`ETS words`), and the JSON that `Ramal.Storage.Postgres` stores. The row is `Bench.Row`: seven attributes with timestamps, two relationships and an aggregate. Heap words are `:erts_debug.size/1` of what the process holds, which counts a term shared by many rows once, as the heap does.

Run on 2026-10-23 in a cloud sandbox, Erlang/OTP 28, Elixir 1.19.6, Ash 3.37.0. The words are exact for the term, so they do not vary between runs. The `0.3.0` and `after sharing terms` columns are from the first memory pass (Erlang/OTP 25, Elixir 1.18.4); the `0.6.1` columns are the same command on commit `1f32373`.

| rows updated | heap words, 0.3.0 | after sharing terms | 0.6.1 | after a reload, 0.3.0 | after sharing terms | 0.6.1 |
|---|---|---|---|---|---|---|
| 100 | 80,328 | 61,452 | 43,240 | 115,080 | 68,143 | 49,931 |
| 1,000 | 427,860 | 269,619 | 204,273 | 614,712 | 291,610 | 229,264 |
| 5,000 | 1,972,202 | 1,194,788 | 895,367 | 2,835,054 | 1,284,779 | 994,958 |

The same command on 0.6.1 also reports the ETS table of `Ramal.Storage.ETS`: 115,893 words at 100 updated rows, 734,292 at 1,000 and 3,589,367 at 5,000.

The stored JSON is what `Ramal.Storage.Postgres` writes to the `state` column. The compact codec (state version 2: ISO 8601 text for the common date structs, struct fields at their defaults left out, the parts of a record that many records share written once, a snapshot stored as its difference from the record) writes about a third of it:

| rows updated | stored JSON bytes, state version 1 | state version 2 | 0.6.1 |
|---|---|---|---|
| 100 | 527,543 | 215,071 (-59%) | 215,093 |
| 1,000 | 3,018,251 | 1,023,133 (-66%) | 1,021,795 |
| 5,000 | 14,084,083 | 4,612,222 (-67%) | 4,646,139 |

`merge heap words` is the largest heap (`heap_block_size` plus `old_heap_block_size` at the end of a garbage collection, which grows in steps) that the process calling `Ramal.merge/1` reaches while it holds the branch, replays it and keeps the result. A branch crosses the process boundary as a full copy, and the merge used to ask for it twice:

| rows updated | merge heap words, before | after | 0.6.1 |
|---|---|---|---|
| 100 | 514,837 | 364,609 (-29%) | 364,609 |
| 1,000 | 2,639,025 | 1,517,744 (-42%) | 1,196,281 |
| 5,000 | 11,347,307 | 7,022,466 (-38%) | 5,131,249 |

## What this is not

It is not a reproduction of the [DAPLab benchmark](https://daplab.cs.columbia.edu/general/2026/05/26/branchable-databases-arent-ready-for-agentic-workloads.html) (BranchBench). The workload is modelled on the workload the article focuses on, a Monte Carlo tree search that keeps forking promising partial states, mutates, queries and prunes; ours is a fixed-shape tree search, not MCTS, and it does not use their harness, schemas or step counts. The article reports that Neon finished 33 of 1,000 steps before hitting its active branch limit and that Dolt finished 170 steps before a two-hour timeout; those are their figures from their harness, cited here and deliberately kept out of the tables above, which were not measured the same way. It compares one Postgres schema at one size on one machine; Neon, Dolt and other branching databases are not measured.
