------------------------------- MODULE Nested -------------------------------
(***************************************************************************)
(* A nested fork merging into its parent branch (ADR 0043): the fork is     *)
(* claimed, the parent is copied together with its version, the fork's own  *)
(* writes are replayed in the copy, and the parent takes the copy in one    *)
(* call if its version is still the one copied, and remembers the fork's    *)
(* id. The caller that runs the merge may die between any two steps.        *)
(*                                                                         *)
(* Ramal.tla is about the lifecycle of one branch and its merge into the    *)
(* database; this spec is about the second kind of merge. A write is        *)
(* identified by the action that made it and by who wrote it, the log of a  *)
(* branch is the sequence of writes, and what the replay needs of an action *)
(* (validations, policies) is abstracted to "may fail". Each step names the *)
(* function it models. Staleness against the parent (Branch.stale_against)  *)
(* is the rule of Ramal.tla's fingerprints and is modelled as on_stale:     *)
(* :ignore; the version check is what this spec adds.                       *)
(*                                                                         *)
(* FixVersion, FixMerged and FixReconcile switch on the guards of           *)
(* Server.adopt/4 and the reconciliation of a fork its parent holds; with   *)
(* any of them off, TLC finds the bug the guard closes.                     *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Clients,      \* the processes that write and merge
    MaxActs,      \* writes, by the parent or the fork
    FixVersion,   \* Server.adopt/4 refuses a copy of the parent that is not current
    FixMerged,    \* the parent remembers the forks that merged into it (merged_children)
    FixReconcile  \* a fork its parent holds is merged when its merger dies or it is loaded (Server.adopted?/2)

None == "none"
Writes == [act : 1..MaxActs, src : {"parent", "child"}]

VARIABLES
    parent,   \* [log, ver, merged]: the parent branch process
    child,    \* [status, log, inherited, claim]: the nested fork
    pc,       \* client -> what it is doing in a merge
    nextAct,
    acked     \* the writes that were reported as done

vars == <<parent, child, pc, nextAct, acked>>

IdlePc == [stage |-> "idle", snap |-> <<>>, ver |-> 0, scratch |-> <<>>, attempt |-> 0]

Init ==
    /\ parent = [log |-> <<>>, ver |-> 0, merged |-> FALSE]
    /\ child = [status |-> "absent", log |-> <<>>, inherited |-> 0, claim |-> None]
    /\ pc = [c \in Clients |-> IdlePc]
    /\ nextAct = 0
    /\ acked = {}

LogSet(l) == {l[i] : i \in DOMAIN l}
Count(l, w) == Cardinality({i \in DOMAIN l : l[i] = w})

\* Branch.own_entries/1: the entries the fork wrote itself, not the ones it inherited.
Own == IF child.inherited >= Len(child.log) THEN <<>> ELSE SubSeq(child.log, child.inherited + 1, Len(child.log))

---------------------------------------------------------------------------
(* Writers *)

\* An action in the parent: Ramal.Capture puts its write in the log and the process bumps its version.
ParentWrite(c) ==
    /\ pc[c].stage = "idle" /\ nextAct < MaxActs
    /\ LET w == [act |-> nextAct + 1, src |-> "parent"]
       IN /\ parent' = [parent EXCEPT !.log = Append(@, w), !.ver = @ + 1]
          /\ acked' = acked \union {w}
          /\ nextAct' = nextAct + 1
    /\ UNCHANGED <<child, pc>>

\* Ramal.fork(parent, nested: true): the fork starts with the parent's log and remembers how long it was.
Fork(c) ==
    /\ pc[c].stage = "idle" /\ child.status = "absent"
    /\ child' = [status |-> "open", log |-> parent.log, inherited |-> Len(parent.log), claim |-> None]
    /\ UNCHANGED <<parent, pc, nextAct, acked>>

\* An action in the fork. A claimed fork takes no writes (Server.usable?/1).
ChildWrite(c) ==
    /\ pc[c].stage = "idle" /\ nextAct < MaxActs
    /\ child.status = "open" /\ child.claim = None
    /\ LET w == [act |-> nextAct + 1, src |-> "child"]
       IN /\ child' = [child EXCEPT !.log = Append(@, w)]
          /\ acked' = acked \union {w}
          /\ nextAct' = nextAct + 1
    /\ UNCHANGED <<parent, pc>>

---------------------------------------------------------------------------
(* The merge of the fork into its parent *)

\* Server.begin_merge/2 on the fork.
Claim(c) ==
    /\ pc[c].stage = "idle" /\ child.status = "open" /\ child.claim = None
    /\ child' = [child EXCEPT !.claim = c]
    /\ pc' = [pc EXCEPT ![c] = [IdlePc EXCEPT !.stage = "claimed"]]
    /\ UNCHANGED <<parent, nextAct, acked>>

\* Server.merge_source/1 on the parent: a copy of it and its version.
Snapshot(c) ==
    /\ pc[c].stage = "claimed" /\ ~(FixMerged /\ parent.merged)
    /\ pc' = [pc EXCEPT ![c].stage = "snapped", ![c].snap = parent.log, ![c].ver = parent.ver]
    /\ UNCHANGED <<parent, child, nextAct, acked>>

\* A fork whose id the parent holds is stored as merged and not merged again (Merge.not_adopted/2).
Refuse(c) ==
    /\ pc[c].stage = "claimed" /\ FixMerged /\ parent.merged
    /\ child' = [child EXCEPT !.status = "merged", !.claim = None]
    /\ pc' = [pc EXCEPT ![c] = IdlePc]
    /\ UNCHANGED <<parent, nextAct, acked>>

\* Merge.replay_in_scratch/4: the fork's own entries are replayed in the copy.
Replay(c) ==
    /\ pc[c].stage = "snapped"
    /\ pc' = [pc EXCEPT ![c].stage = "replayed", ![c].scratch = pc[c].snap \o Own]
    /\ UNCHANGED <<parent, child, nextAct, acked>>

\* A replayed action fails, or the storage refuses the parent's persist: the copy is dropped and the claim released.
Abort(c) ==
    /\ pc[c].stage \in {"snapped", "replayed"}
    /\ child' = [child EXCEPT !.claim = None]
    /\ pc' = [pc EXCEPT ![c] = IdlePc]
    /\ UNCHANGED <<parent, nextAct, acked>>

\* Server.adopt/4: in one call, the parent takes the copy, bumps its version, remembers the fork and persists.
\* With FixVersion a parent that changed since the copy refuses it, and the merge runs its steps once more.
Adopt(c) ==
    /\ pc[c].stage = "replayed"
    /\ \/ /\ (~FixVersion \/ parent.ver = pc[c].ver)
          /\ ~(FixMerged /\ parent.merged)
          /\ parent' = [log |-> pc[c].scratch, ver |-> parent.ver + 1, merged |-> TRUE]
          /\ pc' = [pc EXCEPT ![c].stage = "adopted"]
          /\ UNCHANGED child
       \/ /\ FixVersion /\ parent.ver # pc[c].ver
          /\ IF pc[c].attempt = 0
               THEN pc' = [pc EXCEPT ![c] = [IdlePc EXCEPT !.stage = "claimed", !.attempt = 1]]
               ELSE pc' = [pc EXCEPT ![c] = IdlePc]
          /\ child' = IF pc[c].attempt = 0 THEN child ELSE [child EXCEPT !.claim = None]
          /\ UNCHANGED parent
    /\ UNCHANGED <<nextAct, acked>>

\* Server.finish_merge(:merged): the fork is stored as merged.
Finish(c) ==
    /\ pc[c].stage = "adopted"
    /\ child' = [child EXCEPT !.status = "merged", !.claim = None]
    /\ pc' = [pc EXCEPT ![c] = IdlePc]
    /\ UNCHANGED <<parent, nextAct, acked>>

\* A fork the parent holds is merged: Server.adopted?/2, asked of the storage that adopt/4 wrote before it answered.
Reconciled(ch) == IF FixReconcile /\ FixMerged /\ parent.merged /\ ch.status = "open"
                    THEN [ch EXCEPT !.status = "merged"] ELSE ch

\* The process running the merge dies at any step: the monitor on it releases the claim, and the fork looks at its parent
\* before it takes another call. What the parent adopted stays.
Dies(c) ==
    /\ pc[c].stage # "idle"
    /\ child' = Reconciled([child EXCEPT !.claim = None])
    /\ pc' = [pc EXCEPT ![c] = IdlePc]
    /\ UNCHANGED <<parent, nextAct, acked>>

\* The node restarts: every merger is gone, no claim is held, and the fork is loaded again from storage, where it is
\* open if its merger never stored it as merged. Its writes since its last persist are lost by design, so they were
\* never "reported as done" in the sense of the properties below, and the model leaves the log as it is.
NodeCrash ==
    /\ pc' = [c \in Clients |-> IdlePc]
    /\ child' = IF child.status = "absent" THEN child ELSE Reconciled([child EXCEPT !.claim = None])
    /\ UNCHANGED <<parent, nextAct, acked>>

Next ==
    \/ NodeCrash
    \/ \E c \in Clients :
        \/ ParentWrite(c) \/ Fork(c) \/ ChildWrite(c)
        \/ Claim(c) \/ Snapshot(c) \/ Refuse(c) \/ Replay(c) \/ Abort(c) \/ Adopt(c) \/ Finish(c) \/ Dies(c)

Spec == Init /\ [][Next]_vars

---------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ LogSet(parent.log) \subseteq Writes /\ LogSet(child.log) \subseteq Writes
    /\ child.status \in {"absent", "open", "merged"}
    /\ \A c \in Clients : pc[c].stage \in {"idle", "claimed", "snapped", "replayed", "adopted"}

\* No write is in the parent's log twice: a fork's work is taken once, however many merges are tried or die.
NoDoubleNestedMerge == \A w \in Writes : Count(parent.log, w) <= 1

\* Once the fork is merged, every write of it that was reported as done is in the parent, once.
ParentGetsChildWritesOnce ==
    child.status = "merged" =>
        \A w \in acked : (w.src = "child" /\ w \in LogSet(child.log)) => Count(parent.log, w) = 1

\* A write to the parent that was reported as done is never lost to a merge of the fork.
NoLostParentWrite == \A w \in acked : w.src = "parent" => w \in LogSet(parent.log)

\* A merged fork is never claimed again.
MergedStaysMerged == [][child.status = "merged" => child' = child]_vars
=============================================================================
