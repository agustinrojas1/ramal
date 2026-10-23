# What must hold of a Ramal branch's data rules (model.bend). PROOF.bend proves
# each law; `bend PROOF.bend` prints ALL PROOFS CHECK only when all of them do.

import Base
import ./model.bend as M

# One row
# -------

# A fork starts as a copy: applying an entry onto no entry gives that entry.
law fork_copies:
  for p: M.Slot
  {M.put_entry(M.Absent{}, p) == p : M.Slot}

# Capturing one action keeps the entry honest about the base: Created only for
# a row the base lacks, Updated and Deleted only for one it has.
law capture_honest:
  for op: M.Op
  for +base: Maybe<&2, Nat>
  for +s: M.Slot
  for h: M.Honest(base, s)
  M.Honest(base, M.capture(op, base, s))

# After capturing one action, a read in the branch sees what the action did to
# what the read saw before.
law capture_reads:
  for op: M.Op
  for +base: Maybe<&2, Nat>
  for +s: M.Slot
  for h: M.Honest(base, s)
  {M.view(base, M.capture(op, base, s)) == M.effect(op, M.view(base, s)) : Maybe<&2, Nat>}

# Any log keeps the entry honest.
law branch_honest:
  for ops: List<&2, M.Op>
  for +base: Maybe<&2, Nat>
  for +s: M.Slot
  for h: M.Honest(base, s)
  M.Honest(base, M.branch(ops, base, s))

# read(branch) = base + overlay: what a read in a branch sees of a row is the
# row the log's actions would produce if run on the base.
law branch_reads_replay:
  for ops: List<&2, M.Op>
  for +base: Maybe<&2, Nat>
  {M.view(base, M.branch(ops, base, M.Absent{})) == M.run(ops, base) : Maybe<&2, Nat>}

# Keys
# ----

law key_refl:
  for j: Nat
  {Nat.is_eq(j, j) == True{} : Bool}

law key_sound:
  for j: Nat
  for k: Nat
  for e: {Nat.is_eq(j, k) == True{} : Bool}
  {j == k : Nat}

# Tables
# ------

# A row of the merged table depends only on that row of the base and the log's
# actions on it.
law replay_local:
  for +j: Nat
  for log: List<&2, M.Write>
  for +t: M.Table
  {M.get(j, M.replay(log, t)) == M.run(M.only(j, log), M.get(j, t)) : Maybe<&2, Nat>}

# A row's overlay entry depends only on that row of the base and the log's
# actions on it.
law capture_local:
  for +j: Nat
  for log: List<&2, M.Write>
  for +t: M.Table
  for +o: M.Overlay
  {M.slot(j, M.capture_all(log, t, o)) == M.branch(M.only(j, log), M.get(j, t), M.slot(j, o)) : M.Slot}

# The merge gives every row the branch touched the value a read in the branch
# showed, provided the row did not change in the base since the branch first saw
# it (what the staleness check establishes; see the README for its assumptions).
law merge_shows_branch:
  for +j: Nat
  for +log: List<&2, M.Write>
  for +t: M.Table
  for +t2: M.Table
  for e: {M.get(j, t2) == M.get(j, t) : Maybe<&2, Nat>}
  {M.get(j, M.replay(log, t2)) == M.view(M.get(j, t), M.slot(j, M.capture_all(log, t, M.ONil{}))) : Maybe<&2, Nat>}

# The merge leaves every row the branch did not touch as the base has it now:
# no edit made outside the branch is lost.
law merge_keeps_others:
  for +j: Nat
  for log: List<&2, M.Write>
  for +t2: M.Table
  for e: {M.only(j, log) == Nil{} : List<&2, M.Op>}
  {M.get(j, M.replay(log, t2)) == M.get(j, t2) : Maybe<&2, Nat>}

# Placeholder keys: a row the branch created under the placeholder p, which
# the database gave the key r. The branch never wrote r (it is a key the base
# did not have), and r is as free in the base the merge writes to as p was in
# the base the branch read. Then the merge, replaying the log with p renamed to
# r, writes at r the row a read in the branch returned at p.
law rename_shows_branch:
  for +p: Nat
  for +r: Nat
  for +log: List<&2, M.Write>
  for +t: M.Table
  for +t2: M.Table
  for h: {M.only(r, log) == Nil{} : List<&2, M.Op>}
  for e: {M.get(r, t2) == M.get(p, t) : Maybe<&2, Nat>}
  {M.get(r, M.replay(M.rename(p, r, log), t2)) == M.view(M.get(p, t), M.slot(p, M.capture_all(log, t, M.ONil{}))) : Maybe<&2, Nat>}
