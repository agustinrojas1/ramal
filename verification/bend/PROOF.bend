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
