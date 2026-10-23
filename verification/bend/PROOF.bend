# The proofs of LAWS.bend. Most of the work is case analysis: once the row, the
# entry and the action are known, both sides compute to the same term. The
# entries that would contradict the base (Honest is Empty) close with an empty
# match.

import Base
import ./model.bend as M
import ./LAWS.bend as Laws

def Laws.fork_copies(p):
  match p:
    case M.Absent{}:
      {==}
    case M.Created{r}:
      {==}
    case M.Updated{r}:
      {==}
    case M.Deleted{}:
      {==}

def Laws.capture_honest(op, base, s, h):
  match op base s:
    case M.Create{v} None{} M.Absent{}:
      Unit{}
    case M.Create{v} None{} M.Created{r}:
      Unit{}
    case M.Create{v} Some{x} M.Absent{}:
      Unit{}
    case M.Create{v} Some{x} M.Updated{r}:
      Unit{}
    case M.Create{v} Some{x} M.Deleted{}:
      Unit{}
    case M.Create{v} None{} M.Updated{r}:
      match h:
    case M.Create{v} None{} M.Deleted{}:
      match h:
    case M.Create{v} Some{x} M.Created{r}:
      match h:
    case M.Set{v} None{} M.Absent{}:
      Unit{}
    case M.Set{v} None{} M.Created{r}:
      Unit{}
    case M.Set{v} Some{x} M.Absent{}:
      Unit{}
    case M.Set{v} Some{x} M.Updated{r}:
      Unit{}
    case M.Set{v} Some{x} M.Deleted{}:
      Unit{}
    case M.Set{v} None{} M.Updated{r}:
      match h:
    case M.Set{v} None{} M.Deleted{}:
      match h:
    case M.Set{v} Some{x} M.Created{r}:
      match h:
    case M.Add{n} None{} M.Absent{}:
      Unit{}
    case M.Add{n} None{} M.Created{r}:
      Unit{}
    case M.Add{n} Some{x} M.Absent{}:
      Unit{}
    case M.Add{n} Some{x} M.Updated{r}:
      Unit{}
    case M.Add{n} Some{x} M.Deleted{}:
      Unit{}
    case M.Add{n} None{} M.Updated{r}:
      match h:
    case M.Add{n} None{} M.Deleted{}:
      match h:
    case M.Add{n} Some{x} M.Created{r}:
      match h:
    case M.Delete{} None{} M.Absent{}:
      Unit{}
    case M.Delete{} None{} M.Created{r}:
      Unit{}
    case M.Delete{} Some{x} M.Absent{}:
      Unit{}
    case M.Delete{} Some{x} M.Updated{r}:
      Unit{}
    case M.Delete{} Some{x} M.Deleted{}:
      Unit{}
    case M.Delete{} None{} M.Updated{r}:
      match h:
    case M.Delete{} None{} M.Deleted{}:
      match h:
    case M.Delete{} Some{x} M.Created{r}:
      match h:

def Laws.capture_reads(op, base, s, h):
  match op base s:
    case M.Create{v} None{} M.Absent{}:
      {==}
    case M.Create{v} None{} M.Created{r}:
      {==}
    case M.Create{v} Some{x} M.Absent{}:
      {==}
    case M.Create{v} Some{x} M.Updated{r}:
      {==}
    case M.Create{v} Some{x} M.Deleted{}:
      {==}
    case M.Create{v} None{} M.Updated{r}:
      match h:
    case M.Create{v} None{} M.Deleted{}:
      match h:
    case M.Create{v} Some{x} M.Created{r}:
      match h:
    case M.Set{v} None{} M.Absent{}:
      {==}
    case M.Set{v} None{} M.Created{r}:
      {==}
    case M.Set{v} Some{x} M.Absent{}:
      {==}
    case M.Set{v} Some{x} M.Updated{r}:
      {==}
    case M.Set{v} Some{x} M.Deleted{}:
      {==}
    case M.Set{v} None{} M.Updated{r}:
      match h:
    case M.Set{v} None{} M.Deleted{}:
      match h:
    case M.Set{v} Some{x} M.Created{r}:
      match h:
    case M.Add{n} None{} M.Absent{}:
      {==}
    case M.Add{n} None{} M.Created{r}:
      {==}
    case M.Add{n} Some{x} M.Absent{}:
      {==}
    case M.Add{n} Some{x} M.Updated{r}:
      {==}
    case M.Add{n} Some{x} M.Deleted{}:
      {==}
    case M.Add{n} None{} M.Updated{r}:
      match h:
    case M.Add{n} None{} M.Deleted{}:
      match h:
    case M.Add{n} Some{x} M.Created{r}:
      match h:
    case M.Delete{} None{} M.Absent{}:
      {==}
    case M.Delete{} None{} M.Created{r}:
      {==}
    case M.Delete{} Some{x} M.Absent{}:
      {==}
    case M.Delete{} Some{x} M.Updated{r}:
      {==}
    case M.Delete{} Some{x} M.Deleted{}:
      {==}
    case M.Delete{} None{} M.Updated{r}:
      match h:
    case M.Delete{} None{} M.Deleted{}:
      match h:
    case M.Delete{} Some{x} M.Created{r}:
      match h:

def Laws.branch_honest(ops, base, s, h):
  match ops:
    case Nil{}:
      h
    case +op <> rest:
      Laws.branch_honest(rest, base, M.capture(op, base, s), Laws.capture_honest(op, base, s, h))

# branch_reads_replay from any honest entry, by induction on the log: the first
# action is capture_reads, the rest the induction hypothesis.
def reads_replay(ops: List<&2, M.Op>, +base: Maybe<&2, Nat>, +s: M.Slot, +h: M.Honest(base, s))
  -> {M.view(base, M.branch(ops, base, s)) == M.run(ops, M.view(base, s)) : Maybe<&2, Nat>}:
  match ops:
    case Nil{}:
      {==}
    case +op <> rest:
      %Laws.capture_reads(op, base, s, h) : {M.view(base, M.branch(rest, base, M.capture(op, base, s))) == M.run(rest, _) : Maybe<&2, Nat>}
      reads_replay(rest, base, M.capture(op, base, s), Laws.capture_honest(op, base, s, h))

def Laws.branch_reads_replay(ops, base):
  reads_replay(ops, base, M.Absent{}, Unit{})

# The same lemma, stated for the entry a nested merge's replay starts from.
def Laws.branch_reads_run(ops, base, s, h):
  reads_replay(ops, base, s, h)

def Laws.key_refl(j):
  match j:
    case 0n:
      {==}
    case 1n+p:
      Laws.key_refl(p)

# False is not True: rewriting the equation through a motive that is Empty at
# True and Unit at False.
def False.not_true(b: Bool) -> Data:
  match b:
    case True{}:
      Empty
    case False{}:
      Unit

def false_ne_true(e: {False{} == True{} : Bool}) -> Empty:
  %e : False.not_true(_)
  Unit{}

def Laws.key_sound(j, k, e):
  match j k:
    case 0n 0n:
      {==}
    case 0n 1n+kp:
      Empty.absurd({0n == 1n+kp : Nat}, false_ne_true(e))
    case 1n+jp 0n:
      Empty.absurd({1n+jp == 0n : Nat}, false_ne_true(e))
    case 1n+jp 1n+kp:
      Equal.cong(Nat, Nat, n => 1n+n, jp, kp, Laws.key_sound(jp, kp, e))

# The step of replay_local for a write at key k, with b standing for
# Nat.is_eq(j, k): when the keys are equal the write is the row's own action,
# otherwise the row is read through it.
def replay_local.step(b: Bool, +j: Nat, +k: Nat, +op: M.Op, +tail: List<&2, M.Op>, +t: M.Table, ev: {Nat.is_eq(j, k) == b : Bool})
  -> {M.run(tail, M.pick(Maybe<&2, Nat>, b, M.effect(op, M.get(k, t)), M.get(j, t))) == M.run(M.only.keep(b, op, tail), M.get(j, t)) : Maybe<&2, Nat>}:
  match b:
    case True{}:
      %Laws.key_sound(j, k, ev) : {M.run(tail, M.effect(op, M.get(_, t))) == M.run(tail, M.effect(op, M.get(j, t))) : Maybe<&2, Nat>}
      {==}
    case False{}:
      {==}

def Laws.replay_local(j, log, t):
  match log:
    case Nil{}:
      {==}
    case M.At{+k, +op} <> +rest:
      Equal.trans(
        Maybe<&2, Nat>,
        M.get(j, M.replay(rest, M.TPut{k, M.effect(op, M.get(k, t)), t})),
        M.run(M.only(j, rest), M.get(j, M.TPut{k, M.effect(op, M.get(k, t)), t})),
        M.run(M.only(j, M.At{k, op} <> rest), M.get(j, t)),
        Laws.replay_local(j, rest, M.TPut{k, M.effect(op, M.get(k, t)), t}),
        replay_local.step(Nat.is_eq(j, k), j, k, op, M.only(j, rest), t, {==}))

def capture_local.step(b: Bool, +j: Nat, +k: Nat, +op: M.Op, +tail: List<&2, M.Op>, +t: M.Table, +o: M.Overlay, ev: {Nat.is_eq(j, k) == b : Bool})
  -> {M.branch(tail, M.get(j, t), M.pick(M.Slot, b, M.capture(op, M.get(k, t), M.slot(k, o)), M.slot(j, o))) == M.branch(M.only.keep(b, op, tail), M.get(j, t), M.slot(j, o)) : M.Slot}:
  match b:
    case True{}:
      %Laws.key_sound(j, k, ev) : {M.branch(tail, M.get(j, t), M.capture(op, M.get(_, t), M.slot(_, o))) == M.branch(tail, M.get(j, t), M.capture(op, M.get(j, t), M.slot(j, o))) : M.Slot}
      {==}
    case False{}:
      {==}

def Laws.capture_local(j, log, t, o):
  match log:
    case Nil{}:
      {==}
    case M.At{+k, +op} <> +rest:
      Equal.trans(
        M.Slot,
        M.slot(j, M.capture_all(rest, t, M.OPut{k, M.capture(op, M.get(k, t), M.slot(k, o)), o})),
        M.branch(M.only(j, rest), M.get(j, t), M.slot(j, M.OPut{k, M.capture(op, M.get(k, t), M.slot(k, o)), o})),
        M.branch(M.only(j, M.At{k, op} <> rest), M.get(j, t), M.slot(j, o)),
        Laws.capture_local(j, rest, t, M.OPut{k, M.capture(op, M.get(k, t), M.slot(k, o)), o}),
        capture_local.step(Nat.is_eq(j, k), j, k, op, M.only(j, rest), t, o, {==}))

# merge_shows_branch, step by step:
#   get(j, replay(log, t2))
#   = run(only(j, log), get(j, t2))                              replay_local
#   = run(only(j, log), get(j, t))                               e
#   = view(get(j, t), branch(only(j, log), get(j, t), Absent))   branch_reads_replay
#   = view(get(j, t), slot(j, capture_all(log, t, ONil)))        capture_local
def Laws.merge_shows_branch(j, log, t, t2, e):
  Equal.trans(
    Maybe<&2, Nat>,
    M.get(j, M.replay(log, t2)),
    M.run(M.only(j, log), M.get(j, t2)),
    M.view(M.get(j, t), M.slot(j, M.capture_all(log, t, M.ONil{}))),
    Laws.replay_local(j, log, t2),
    Equal.trans(
      Maybe<&2, Nat>,
      M.run(M.only(j, log), M.get(j, t2)),
      M.run(M.only(j, log), M.get(j, t)),
      M.view(M.get(j, t), M.slot(j, M.capture_all(log, t, M.ONil{}))),
      Equal.cong(Maybe<&2, Nat>, Maybe<&2, Nat>, m => M.run(M.only(j, log), m), M.get(j, t2), M.get(j, t), e),
      Equal.trans(
        Maybe<&2, Nat>,
        M.run(M.only(j, log), M.get(j, t)),
        M.view(M.get(j, t), M.branch(M.only(j, log), M.get(j, t), M.Absent{})),
        M.view(M.get(j, t), M.slot(j, M.capture_all(log, t, M.ONil{}))),
        Equal.sym(
          Maybe<&2, Nat>,
          M.view(M.get(j, t), M.branch(M.only(j, log), M.get(j, t), M.Absent{})),
          M.run(M.only(j, log), M.get(j, t)),
          Laws.branch_reads_replay(M.only(j, log), M.get(j, t))),
        Equal.cong(
          M.Slot,
          Maybe<&2, Nat>,
          s => M.view(M.get(j, t), s),
          M.branch(M.only(j, log), M.get(j, t), M.Absent{}),
          M.slot(j, M.capture_all(log, t, M.ONil{})),
          Equal.sym(
            M.Slot,
            M.slot(j, M.capture_all(log, t, M.ONil{})),
            M.branch(M.only(j, log), M.get(j, t), M.Absent{}),
            Laws.capture_local(j, log, t, M.ONil{}))))))

def Laws.merge_keeps_others(j, log, t2, e):
  Equal.trans(
    Maybe<&2, Nat>,
    M.get(j, M.replay(log, t2)),
    M.run(M.only(j, log), M.get(j, t2)),
    M.get(j, t2),
    Laws.replay_local(j, log, t2),
    Equal.cong(List<&2, M.Op>, Maybe<&2, Nat>, l => M.run(l, M.get(j, t2)), M.only(j, log), Nil{}, e))

# Placeholder keys
# ----------------

# A list with an element in it is not the empty list: a motive that is Empty at
# the empty list and Unit at a cons.
def Cons(l: List<&2, M.Op>) -> Data:
  match l:
    case Nil{}:
      Empty
    case x <> xs:
      Unit

def cons_ne_nil(op: M.Op, tail: List<&2, M.Op>, e: {op <> tail == Nil{} : List<&2, M.Op>}) -> Empty:
  %e : Cons(_)
  Unit{}

# When keep(b, op, tail) is empty, the key did not match and the tail is empty.
def keep_false(b: Bool, op: M.Op, tail: List<&2, M.Op>, h: {M.only.keep(b, op, tail) == Nil{} : List<&2, M.Op>}) -> {b == False{} : Bool}:
  match b:
    case True{}:
      Empty.absurd({True{} == False{} : Bool}, cons_ne_nil(op, tail, h))
    case False{}:
      {==}

def keep_tail(b: Bool, op: M.Op, tail: List<&2, M.Op>, h: {M.only.keep(b, op, tail) == Nil{} : List<&2, M.Op>}) -> {tail == Nil{} : List<&2, M.Op>}:
  match b:
    case True{}:
      Empty.absurd({tail == Nil{} : List<&2, M.Op>}, cons_ne_nil(op, tail, h))
    case False{}:
      h

# Nat.is_eq is symmetric.
def eq_true_sym(+p: Nat, +k: Nat, ev: {Nat.is_eq(k, p) == True{} : Bool}) -> {Nat.is_eq(p, k) == True{} : Bool}:
  Equal.trans(
    Bool,
    Nat.is_eq(p, k),
    Nat.is_eq(p, p),
    True{},
    Equal.cong(Nat, Bool, x => Nat.is_eq(p, x), k, p, Laws.key_sound(k, p, ev)),
    Laws.key_refl(p))

def eq_false_sym(b: Bool, +p: Nat, +k: Nat, ev: {Nat.is_eq(k, p) == False{} : Bool}, ev2: {Nat.is_eq(p, k) == b : Bool}) -> {Nat.is_eq(p, k) == False{} : Bool}:
  match b:
    case True{}:
      Empty.absurd({Nat.is_eq(p, k) == False{} : Bool}, false_ne_true(
        Equal.trans(
          Bool,
          False{},
          Nat.is_eq(k, p),
          True{},
          Equal.sym(Bool, Nat.is_eq(k, p), False{}, ev),
          eq_true_sym(k, p, ev2))))
    case False{}:
      ev2

# The step of only_rename for a write at key k, with b standing for
# Nat.is_eq(k, p): a write at the placeholder moves to r, any other stays.
def only_rename.step(b: Bool, +p: Nat, +r: Nat, +k: Nat, +op: M.Op, +rest: List<&2, M.Write>, ev: {Nat.is_eq(k, p) == b : Bool}, ih: {M.only(r, M.rename(p, r, rest)) == M.only(p, rest) : List<&2, M.Op>}, hr: {Nat.is_eq(r, k) == False{} : Bool})
  -> {M.only(r, M.At{M.pick(Nat, b, r, k), op} <> M.rename(p, r, rest)) == M.only(p, M.At{k, op} <> rest) : List<&2, M.Op>}:
  match b:
    case True{}:
      Equal.trans(
        List<&2, M.Op>,
        M.only.keep(Nat.is_eq(r, r), op, M.only(r, M.rename(p, r, rest))),
        M.only.keep(True{}, op, M.only(p, rest)),
        M.only.keep(Nat.is_eq(p, k), op, M.only(p, rest)),
        Equal.trans(
          List<&2, M.Op>,
          M.only.keep(Nat.is_eq(r, r), op, M.only(r, M.rename(p, r, rest))),
          M.only.keep(True{}, op, M.only(r, M.rename(p, r, rest))),
          M.only.keep(True{}, op, M.only(p, rest)),
          Equal.cong(Bool, List<&2, M.Op>, x => M.only.keep(x, op, M.only(r, M.rename(p, r, rest))), Nat.is_eq(r, r), True{}, Laws.key_refl(r)),
          Equal.cong(List<&2, M.Op>, List<&2, M.Op>, l => M.only.keep(True{}, op, l), M.only(r, M.rename(p, r, rest)), M.only(p, rest), ih)),
        Equal.sym(
          List<&2, M.Op>,
          M.only.keep(Nat.is_eq(p, k), op, M.only(p, rest)),
          M.only.keep(True{}, op, M.only(p, rest)),
          Equal.cong(Bool, List<&2, M.Op>, x => M.only.keep(x, op, M.only(p, rest)), Nat.is_eq(p, k), True{}, eq_true_sym(p, k, ev))))
    case False{}:
      Equal.trans(
        List<&2, M.Op>,
        M.only.keep(Nat.is_eq(r, k), op, M.only(r, M.rename(p, r, rest))),
        M.only(p, rest),
        M.only.keep(Nat.is_eq(p, k), op, M.only(p, rest)),
        Equal.trans(
          List<&2, M.Op>,
          M.only.keep(Nat.is_eq(r, k), op, M.only(r, M.rename(p, r, rest))),
          M.only(r, M.rename(p, r, rest)),
          M.only(p, rest),
          Equal.cong(Bool, List<&2, M.Op>, x => M.only.keep(x, op, M.only(r, M.rename(p, r, rest))), Nat.is_eq(r, k), False{}, hr),
          ih),
        Equal.sym(
          List<&2, M.Op>,
          M.only.keep(Nat.is_eq(p, k), op, M.only(p, rest)),
          M.only(p, rest),
          Equal.cong(Bool, List<&2, M.Op>, x => M.only.keep(x, op, M.only(p, rest)), Nat.is_eq(p, k), False{}, eq_false_sym(Nat.is_eq(p, k), p, k, ev, {==}))))

# Renaming the placeholder to r moves the writes at p to r and leaves the others
# alone, so the actions on r are the actions that were on p, provided the log
# has no write at r.
def only_rename(+p: Nat, +r: Nat, log: List<&2, M.Write>, +h: {M.only(r, log) == Nil{} : List<&2, M.Op>})
  -> {M.only(r, M.rename(p, r, log)) == M.only(p, log) : List<&2, M.Op>}:
  match log:
    case Nil{}:
      {==}
    case M.At{+k, +op} <> +rest:
      only_rename.step(
        Nat.is_eq(k, p), p, r, k, op, rest, {==},
        only_rename(p, r, rest, keep_tail(Nat.is_eq(r, k), op, M.only(r, rest), h)),
        keep_false(Nat.is_eq(r, k), op, M.only(r, rest), h))

# What a read in the branch shows of the row j is what the row's own actions
# make of the base row (the second half of merge_shows_branch).
def shown(+j: Nat, +log: List<&2, M.Write>, +t: M.Table)
  -> {M.run(M.only(j, log), M.get(j, t)) == M.view(M.get(j, t), M.slot(j, M.capture_all(log, t, M.ONil{}))) : Maybe<&2, Nat>}:
  Equal.trans(
    Maybe<&2, Nat>,
    M.run(M.only(j, log), M.get(j, t)),
    M.view(M.get(j, t), M.branch(M.only(j, log), M.get(j, t), M.Absent{})),
    M.view(M.get(j, t), M.slot(j, M.capture_all(log, t, M.ONil{}))),
    Equal.sym(
      Maybe<&2, Nat>,
      M.view(M.get(j, t), M.branch(M.only(j, log), M.get(j, t), M.Absent{})),
      M.run(M.only(j, log), M.get(j, t)),
      Laws.branch_reads_replay(M.only(j, log), M.get(j, t))),
    Equal.cong(
      M.Slot,
      Maybe<&2, Nat>,
      s => M.view(M.get(j, t), s),
      M.branch(M.only(j, log), M.get(j, t), M.Absent{}),
      M.slot(j, M.capture_all(log, t, M.ONil{})),
      Equal.sym(
        M.Slot,
        M.slot(j, M.capture_all(log, t, M.ONil{})),
        M.branch(M.only(j, log), M.get(j, t), M.Absent{}),
        Laws.capture_local(j, log, t, M.ONil{}))))

# rename_shows_branch, step by step:
#   get(r, replay(rename(p, r, log), t2))
#   = run(only(r, rename(p, r, log)), get(r, t2))    replay_local
#   = run(only(p, log), get(r, t2))                  only_rename
#   = run(only(p, log), get(p, t))                   e
#   = view(get(p, t), slot(p, capture_all(log, t, ONil)))   shown
def Laws.rename_shows_branch(p, r, log, t, t2, h, e):
  Equal.trans(
    Maybe<&2, Nat>,
    M.get(r, M.replay(M.rename(p, r, log), t2)),
    M.run(M.only(r, M.rename(p, r, log)), M.get(r, t2)),
    M.view(M.get(p, t), M.slot(p, M.capture_all(log, t, M.ONil{}))),
    Laws.replay_local(r, M.rename(p, r, log), t2),
    Equal.trans(
      Maybe<&2, Nat>,
      M.run(M.only(r, M.rename(p, r, log)), M.get(r, t2)),
      M.run(M.only(p, log), M.get(r, t2)),
      M.view(M.get(p, t), M.slot(p, M.capture_all(log, t, M.ONil{}))),
      Equal.cong(List<&2, M.Op>, Maybe<&2, Nat>, l => M.run(l, M.get(r, t2)), M.only(r, M.rename(p, r, log)), M.only(p, log), only_rename(p, r, log, h)),
      Equal.trans(
        Maybe<&2, Nat>,
        M.run(M.only(p, log), M.get(r, t2)),
        M.run(M.only(p, log), M.get(p, t)),
        M.view(M.get(p, t), M.slot(p, M.capture_all(log, t, M.ONil{}))),
        Equal.cong(Maybe<&2, Nat>, Maybe<&2, Nat>, m => M.run(M.only(p, log), m), M.get(r, t2), M.get(p, t), e),
        shown(p, log, t))))
