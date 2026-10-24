# Stability

Ramal is pre-1.0. This page says what is promised now, so you know what a minor release may change.

## Stable

From Ramal 0.8.0, these nine calls keep their names, their required arguments and their return shapes through 0.x and into 1.0:

- `Ramal.branch/2`
- `Ramal.run/2` (`Ramal.run/3` adds the `:atomic` option)
- `Ramal.fork/2`
- `Ramal.diff/2`
- `Ramal.merge/2`
- `Ramal.propose/2`
- `Ramal.approve/2`
- `Ramal.reject/2`
- `Ramal.discard/1`

Where the second argument is an optional `opts` (`opts \\ []`), the one-argument form is part of the promise too, so `Ramal.diff/1` is covered along with `Ramal.diff/2`.

What is promised:

- A call returns `{:ok, value}` or `{:error, %Ramal.Error{}}`. `Ramal.discard/1` returns `:ok` or `{:error, %Ramal.Error{}}`.
- `Ramal.run!/2` is the bang variant of `Ramal.run/2`. It returns the value or raises `Ramal.Error`. Of the nine calls, it is the only one with a bang variant.
- An option may be added to any of them. An option is not removed, and its meaning is not changed, without the deprecation below.
- Renaming a call, changing its required arguments or its return shape, or removing an option gets a deprecation warning for at least one minor release before the change takes effect.

## Extended

These work and are covered by tests. They may change in a minor release before 1.0, and the changelog says when one does. Each entry names what turns it on.

- **Bulk actions in a branch**: `Ash.bulk_create/4`, `Ash.bulk_update/4` and `Ash.bulk_destroy/4`. A bulk update or destroy of a query must allow `strategy: [:atomic, :stream]`.
- **Upserts**: an action with `upsert? true`. An `upsert_condition` is refused.
- **Placeholder keys for generated primary keys**: a `generated? true` integer or UUID primary key. `Ramal.Merge.Result.keys` maps each placeholder to its real key.
- **Nested forks**: `Ramal.fork(branch, nested: true)`.
- **Clusters**: `cluster: true` on `Ramal.Supervisor`, with `Ramal.Storage.Postgres`.
- **Durable branches**: `durable: true` on `Ramal.branch/2`, or on `Ramal.Supervisor` as the default for every branch.
- **Aggregates**: `Ramal.aggregate/4` and `Ramal.aggregate!/4`.
- **Loads onto a changed record**: `Ramal.load/3` and `Ramal.load!/3`.
- **Context for tool servers**: `Ramal.context/1`, the `context:` option of an Ash call.
- **Agent tools**: `Ramal.Tools`, its `definitions/1` and `call/3`.
- **Storage**: the `Ramal.Storage` behaviour and the bundled `Ramal.Storage.ETS` and `Ramal.Storage.Postgres`. The optional callbacks (`claim/2`, `count/3`, `append/4`, `writes_after/2`) are part of this.
- **Limits on branches**: `max_active_branches` and `branch_rate` on `Ramal.Supervisor`, and `max_heap_size` for the heap of each branch process.
- **The rest of the public surface**: `Ramal.get/1`, `Ramal.list/2`, `Ramal.current/0` and `Ramal.in_branch?/1`; the `Ramal.Branch`, `Ramal.Change`, `Ramal.Merge.Result` and `Ramal.Error` structs (fields and error reasons may be added); `Ramal.Aggregate`, `Ramal.Overlay` and `Ramal.Storage.Codec`; the telemetry event names in `Ramal.Telemetry`; the `Ramal.Resource` extension and its options; `mix ramal.gen.migration`; and `ramal_live`, the inspector, which ships with the same version.

## Experimental

These may change or go in any release, and the changelog says so. They are not part of the nine stable calls.

- **The staleness check without the merge**: `Ramal.stale/2` and `Ramal.mark_merged/1` (ADR 0051), for a host that commits a branch through its own command layer instead of letting `merge/2` replay the Ash log. `stale/2` returns the rows the base changed under the branch, with the same `FOR UPDATE` locks as the merge when called with `lock: true` inside the host's transaction. `mark_merged/1` stores the branch as merged afterwards. The reasons `:nested_fork` and `:not_in_transaction` belong to them.

## Release cadence

Releases come when there is something worth releasing: a fix a user needs, or a set of features. They do not come after every merge. Patch releases carry fixes and minor releases carry features, and each release has an entry in the [changelog](https://github.com/agustinrojas1/ramal/blob/main/CHANGELOG.md). A release is made when the version in `mix.exs` on `main` is raised: CI then tags it and publishes it to Hex (see `.github/workflows/release.yml`).

The stable calls change only with the deprecation warning described above, for at least one minor release first. Everything else may change in a minor release before 1.0, and the changelog says so when it does. An Ash upgrade is checked with `mix ramal.doctor`, which runs each Ash behaviour Ramal relies on against the version the host runs (ADR 0049). What 1.0 needs is in the [roadmap](ROADMAP.md).
