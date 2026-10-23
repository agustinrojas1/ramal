# 0039. Replay keeps hook-created keys and caller-set attributes

Status: accepted, 2026-10-23. Amends [ADR 0007](0007-merge.md) and [ADR 0005](0005-write-capture.md).

## Context

A merge replays each top-level log entry through its action with the entry's `params`, and skips entries a hook wrote
(`nested?`), because replaying the action runs the hook again. Two things were lost by that:

- **A row a hook created got a new key.** The hook's create runs again during the replay and takes a new default key,
  so a later top-level entry that names the branch's key (an update of the `Move` a `:move` action created) found
  nothing and failed the merge.
- **Attributes set outside the input were not replayed.** A caller that builds the changeset and then calls
  `Ash.Changeset.change_attribute/3` before `Ash.update/2` sets something that is not in `params`, so the merge
  produced a row the branch never had.

## Decision

- **Every log entry carries `root: n`**, a random integer chosen when the outermost captured action starts (6 random
  bytes; a counter would start again with the node). The action's own entry and the entries of every hook inside it
  share it, whether the hook ran before the write (`before_action`) or after (`after_action`, managed relationships) and
  whatever other processes wrote in between. The order of the log alone cannot say that.
- **A key plan.** Replaying an entry, the merge collects the `{resource, key}` of the creates that carry its root, in
  log order, and runs the action with that plan in the process dictionary. The capture change, which does nothing else
  when no branch is current, gives the next planned key to a create of the planned resource, with
  `Ash.Changeset.force_change_attribute/3` when it builds the changeset. A create of another resource ends the plan: the
  hook does not do what it did in the branch, and the old behaviour applies (the row gets the key it is given). The plan
  lives in the process dictionary of the merging process and is dropped when the entry has been replayed. An entry
  without a root (a branch stored before this version) has no plan.
- **Recorded caller changes.** The capture change runs after the action's own changes (global changes run last), so
  the attributes it sees are what the action did with its input. It adds a `before_action` hook with `prepend?: true`,
  which runs before every other hook; whatever differs there was set by the caller. That difference (without primary
  keys, and without the defaults Ash applies when the action starts, which are listed in `changeset.defaults`) is the
  entry's `forced` option, and the replay applies it with `force_change_attributes` after building the changeset. What
  the action's own hooks set is not recorded, so a hook that stamps the time stamps the merge's time.
- `root` and `forced` are stored with the branch (`Ramal.Storage.Codec` names them).

## Consequences

- Updating or destroying, in the same branch, a row that a hook created now merges, when the hooks create the same rows
  in the same order. A hook that creates rows conditionally can still diverge; the plan then ends at the first create
  that does not fit, and a later entry that names an unplanned key fails the merge as before.
- A forced value is the value the branch had. If the caller computed it from the branch's state, the merge keeps it
  even when the base moved; it is a value, not an expression.
- Arguments set after `for_create` or `for_update` (`Ash.Changeset.set_argument/3`) are still not replayed. Changes
  that read an argument ran before it was set, in the branch and in the replay alike, so the attribute they set is in
  the difference, but an `after_action` hook that reads the argument sees the replay's.
- Every entry is a little larger (an integer under `root`); the entry of an action that sets nothing outside its input
  has no `forced`.
- No change to the merge's transaction, the claim or the storage callbacks, so the TLA+ model is unchanged.
