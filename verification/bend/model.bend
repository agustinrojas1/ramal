# The data rules of a Ramal branch, as plain functions over one row and over a
# table of rows. LAWS.bend states what must hold of them; PROOF.bend proves it.
#
# What is modelled, and where it lives in lib/:
#
#   Slot        an overlay entry for one row, or no entry   Ramal.Overlay.entry
#   put_*       how a write combines with the entry there   Ramal.Overlay.put_created/3 and friends
#   view        what a read in the branch sees of the row   Ramal.Overlay.patch/4, one row
#   Op, effect  what an action does to a row                the action, run against the row
#   capture     the branch runs the action on what it sees  Ramal.Capture, Ramal.Branch.put_write/6
#   run         the merge replays the log on the base       Ramal.Merge.replay/3
#   put_entry   a fork copies its parent entry by entry     Ramal.Overlay.merge_into/2
#   rename      the merge swaps a placeholder key for the   Ramal.Merge.rename_entry/2 (ADR 0039)
#               key the database gave the row
#
# A row is a Nat, a missing row is None. An action is one of four kinds; one
# that is invalid for the row it finds (a create over an existing row, an
# update or a destroy of a missing one) fails, and a failed action writes
# nothing, in the branch and in the replay alike.
#
#   bend verification/bend/model.bend

import Base

# Rows
# ----

type Slot is Data:
  Absent{}
  Created{r: Nat}
  Updated{r: Nat}
  Deleted{}

# The table in Ramal.Overlay's module doc: a second write to a row keeps the
# net effect on the base, so Deleted always means the base had the row.
def put_created(s: Slot, r: Nat) -> Slot:
  match s:
    case Absent{}:
      Created{r}
    case Created{x}:
      Created{r}
    case Updated{x}:
      Updated{r}
    case Deleted{}:
      Updated{r}

def put_updated(s: Slot, r: Nat) -> Slot:
  match s:
    case Absent{}:
      Updated{r}
    case Created{x}:
      Created{r}
    case Updated{x}:
      Updated{r}
    case Deleted{}:
      Updated{r}

def put_deleted(s: Slot) -> Slot:
  match s:
    case Absent{}:
      Deleted{}
    case Created{x}:
      Absent{}
    case Updated{x}:
      Deleted{}
    case Deleted{}:
      Deleted{}

# What a read in the branch returns for the row: the overlay entry, or the base
# row when the branch has none.
def view(base: Maybe<&2, Nat>, s: Slot) -> Maybe<&2, Nat>:
  match s:
    case Absent{}:
      base
    case Created{r}:
      Some{r}
    case Updated{r}:
      Some{r}
    case Deleted{}:
      None{}

type Op is Data:
  Create{v: Nat}
  Set{v: Nat}
  Add{n: Nat}
  Delete{}

# The row after the action, or the row as it was when the action fails.
def effect(op: Op, m: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match op m:
    case Create{v} None{}:
      Some{v}
    case Create{v} Some{x}:
      Some{x}
    case Set{v} None{}:
      None{}
    case Set{v} Some{x}:
      Some{v}
    case Add{n} None{}:
      None{}
    case Add{n} Some{x}:
      Some{Nat.add(x, n)}
    case Delete{} None{}:
      None{}
    case Delete{} Some{x}:
      None{}

# The branch runs the action against what it sees (m) and records the write
# with the put_* its action type calls for.
def capture.go(op: Op, m: Maybe<&2, Nat>, s: Slot) -> Slot:
  match op m:
    case Create{v} None{}:
      put_created(s, v)
    case Create{v} Some{x}:
      s
    case Set{v} None{}:
      s
    case Set{v} Some{x}:
      put_updated(s, v)
    case Add{n} None{}:
      s
    case Add{n} Some{x}:
      put_updated(s, Nat.add(x, n))
    case Delete{} None{}:
      s
    case Delete{} Some{x}:
      put_deleted(s)

def capture(op: Op, +base: Maybe<&2, Nat>, +s: Slot) -> Slot:
  capture.go(op, view(base, s), s)

# The entry the branch holds after a log of actions on the row.
def branch(ops: List<&2, Op>, +base: Maybe<&2, Nat>, +s: Slot) -> Slot:
  match ops:
    case Nil{}:
      s
    case op <> rest:
      branch(rest, base, capture(op, base, s))

# The row after the merge replays the same log on the base.
def run(ops: List<&2, Op>, m: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match ops:
    case Nil{}:
      m
    case op <> rest:
      run(rest, effect(op, m))

# A fork applies each entry of its parent onto an empty overlay.
def put_entry(s: Slot, p: Slot) -> Slot:
  match p:
    case Absent{}:
      s
    case Created{r}:
      put_created(s, r)
    case Updated{r}:
      put_updated(s, r)
    case Deleted{}:
      put_deleted(s)

# What an entry says about the base: Created means the base has no such row,
# Updated and Deleted that it has one.
def IsNone(m: Maybe<&2, Nat>) -> Data:
  match m:
    case None{}:
      Unit
    case Some{x}:
      Empty

def IsSome(m: Maybe<&2, Nat>) -> Data:
  match m:
    case None{}:
      Empty
    case Some{x}:
      Unit

def Honest(base: Maybe<&2, Nat>, s: Slot) -> Data:
  match s:
    case Absent{}:
      Unit
    case Created{r}:
      IsNone(base)
    case Updated{r}:
      IsSome(base)
    case Deleted{}:
      IsSome(base)

# Tables
# ------

# A table maps keys to rows; a later put shadows an earlier one, as Map.put does.
type Table is Data:
  TNil{}
  TPut{k: Nat, v: Maybe<&2, Nat>, rest: Table}

def pick(-A: Data, b: Bool, +x: A, +y: A) -> A:
  match b:
    case True{}:
      x
    case False{}:
      y

def get(+j: Nat, t: Table) -> Maybe<&2, Nat>:
  match t:
    case TNil{}:
      None{}
    case TPut{k, v, rest}:
      pick(Maybe<&2, Nat>, Nat.is_eq(j, k), v, get(j, rest))

# The overlay of a branch: a slot per key, Absent where the branch has no entry.
type Overlay is Data:
  ONil{}
  OPut{k: Nat, s: Slot, rest: Overlay}

def slot(+j: Nat, o: Overlay) -> Slot:
  match o:
    case ONil{}:
      Absent{}
    case OPut{k, s, rest}:
      pick(Slot, Nat.is_eq(j, k), s, slot(j, rest))

# A log entry: an action on the row with key k.
type Write is Data:
  At{k: Nat, op: Op}

# The merge: every logged action replayed, in order, on the table.
def replay(log: List<&2, Write>, +t: Table) -> Table:
  match log:
    case Nil{}:
      t
    case At{+k, op} <> rest:
      replay(rest, TPut{k, effect(op, get(k, t)), t})

# The branch: every logged action captured, in order, against the base table.
def capture_all(log: List<&2, Write>, +t: Table, +o: Overlay) -> Overlay:
  match log:
    case Nil{}:
      o
    case At{+k, op} <> rest:
      capture_all(rest, t, OPut{k, capture(op, get(k, t), slot(k, o)), o})

def only.keep(b: Bool, op: Op, tail: List<&2, Op>) -> List<&2, Op>:
  match b:
    case True{}:
      op <> tail
    case False{}:
      tail

# The actions of the log on the row with key j, in order.
def only(+j: Nat, log: List<&2, Write>) -> List<&2, Op>:
  match log:
    case Nil{}:
      Nil{}
    case At{k, op} <> rest:
      only.keep(Nat.is_eq(j, k), op, only(j, rest))

# Placeholder keys (ADR 0038)
# ---------------------------

# The merge replays the log with the key of the row the branch created under a
# placeholder p renamed to the key r the database gave it.
def rename(+p: Nat, +r: Nat, log: List<&2, Write>) -> List<&2, Write>:
  match log:
    case Nil{}:
      Nil{}
    case At{+k, op} <> rest:
      At{pick(Nat, Nat.is_eq(k, p), r, k), op} <> rename(p, r, rest)
