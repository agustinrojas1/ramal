# 0050. The formal models are tied to the code by a map that CI reads

Status: accepted, 2026-10-23. Builds on [ADR 0033](0033-running-actions-hold-their-writes.md), [0035](0035-merged-status-in-the-merge-transaction.md), [0043](0043-nested-branches-merge-into-their-parent.md), [0044](0044-branches-in-a-cluster.md) and [0048](0048-durable-branches.md), the changes the models led to or followed.

## Context

The TLA+ and Bend models under `verification/` are written by hand. Nothing regenerates them from the code, and nothing
checked that they still described it: the Verification workflow reran them when a handful of files changed, which proves
the model against itself, not against the code. Between ADR 0035 and this one, the models kept up because the authors of
the nested, cluster and durable changes updated them in the same pull request. A check of that drift (this ADR's
audit) found the rest of what had moved and nothing had flagged: two comments citing functions whose arity had changed
(`Capture.write/3`, `Branch.apply_delta/2`); the workflow's `paths` missing `lib/ramal.ex` and `lib/ramal/supervisor.ex`;
and an abstraction the code had outgrown, an action as exactly one write, while bulk actions (ADR 0036), hooks that
write other rows and nested actions that fail on their own make an action several writes that are held, stored and
taken back together.

## Decision

- **A map.** `verification/model_map.exs` names, for every step of every model, the `Module.function/arity` of `lib/` it
  stands for (a behaviour's `@callback` included), and lists every file under `lib/` that holds no such function with
  the reason no model needs it.
- **A test reads it** (`test/ramal/model_map_test.exs`, in `mix ci`, no database). It fails when a named function or a
  function a `.tla` comment cites is gone, when a step is not defined in its model, when a file under `lib/` is neither
  mapped nor excused, when the Verification workflow's `paths` leave out a file a model reads, and when the code of a
  step changed. The last uses `verification/model_map.stamps`: a hash of the syntax trees of a step's functions, which
  ignores comments, docs, formatting and line numbers. The author reads the step, edits the model if the rule changed,
  and runs `STAMP=1 mix test test/ramal/model_map_test.exs`. The stamps sit under `verification/`, so a moved stamp reruns TLC and Bend.
- **The model changes with it.** An action makes up to `MaxWrites` writes (`WriteMore`, `Retract`), `Branch.undo/2`'s
  newest-first order is `FixUndoOrder`, and `NoTornAction` holds that a fork, merge or stored branch has all the writes
  of an action or none. Two new configurations (`MC-multi.cfg`, `MC-multi-rows.cfg`) and two regression configurations
  (`bug-undo-order.cfg`, `bug-torn.cfg`) check it; with `MaxWrites = 1` the old configurations have the same states.
- **A checklist line** in the pull request template asks for the steps checked.

## Consequences

- A change to the body of a modelled function is a failing build until someone records that they looked. That is friction
  on purpose; the stamp cannot say the check was good, only that it was done, which the pull request description and
  review have to carry. A function the map does not name can still change behaviour unseen, and the model cannot see it;
  the map is only as good as its list, and a step that grows a new helper should have it added.
- The read side (`Ramal.Preparation` and friends) is excused as tested by properties, not modelled. The map says so per file, so
  moving a rule from there into the lifecycle shows up as a decision.
- The multi-write model found no bug in the code: TLC finds none with the current undo order and the running-action hold.
  It would have found the two designs it rejects (`bug-undo-order.cfg`, `bug-torn.cfg`).
