------------------------------- MODULE Ramal -------------------------------
(***************************************************************************)
(* The life of Ramal branches, as the branch processes and their callers   *)
(* run it: writes captured by actions that can fail or die, reads that     *)
(* fingerprint base rows, fork, propose, approve, reject, discard, merge   *)
(* (claim, staleness check and replay, persist), idle unload, a process   *)
(* killed for its heap, restarts from storage, and outside writes to the   *)
(* base.                                                                   *)
(*                                                                         *)
(* The model abstracts the data: a base row is a version number, a write   *)
(* is identified by the action that made it, and the overlay maps a key to *)
(* the write that set it last. Ramal.Overlay and Ramal.Branch are proved   *)
(* separately (verification/bend); this spec is about who sees what, when. *)
(*                                                                         *)
(* Each step is one message a branch process handles, or one thing a       *)
(* caller does between messages, which is the granularity at which the     *)
(* BEAM interleaves them. The source line each step models is named.       *)
(*                                                                         *)
(* The constants FixPending, FixMarker and FixMergedMark switch on the     *)
(* fixes this model led to (verification/README.md); with any of them off, *)
(* TLC finds the bug it fixes. NodeCrashes and MergerCrashes allow the     *)
(* node to restart and the process running a merge to die after the       *)
(* commit; without FixMergedMark, TLC shows the double merge each allows.  *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Clients,        \* the processes that call Ramal
    Keys,           \* base rows
    Root, Fork,     \* a branch and the one fork the model lets it have
    MaxActs,        \* actions (each makes one captured write)
    MaxExternal,    \* writes to the base from outside any branch
    MaxKills,       \* branch processes killed by max_heap_size
    FixPending,     \* the branch process knows which writes are of actions still running
    FixMarker,      \* a process that died without terminate/2 is not restarted from storage
    FixMergedMark,  \* the merge transaction stores the branch as merged, and refuses one stored so (ADR 0035)
    NodeCrashes,    \* the node restarts: every process and ETS table is lost, storage stays
    MergerCrashes   \* the process running a merge dies after the commit, before finish_merge

None == "none"
NoFp == 0           \* base versions start at 1
Branches == {Root, Fork}
Acts == 1..MaxActs
Failed == {"failed", "crashed"}

Writes == [act : Acts, key : Keys, branch : Branches, setFp : BOOLEAN, prev : 0..MaxActs]
NoWrite == [act |-> 1, key |-> CHOOSE k \in Keys : TRUE, branch |-> Root, setFp |-> FALSE, prev |-> 0]

VARIABLES
    db,          \* key -> version of the base row
    store,       \* branch -> what storage holds
    proc,        \* branch -> the branch process
    marker,      \* branch -> a process was started and has not run terminate/2 (FixMarker)
    tooLarge,    \* branch -> Supervisor.too_large?/1
    watcherDue,  \* branch -> a killed process whose watcher has not marked it yet
    pc,          \* client -> what it is doing
    actState,    \* action -> "none" | "running" | "ok" | "failed" | "crashed"
    nextAct, externals, kills, crashes,
    committed,   \* branch -> how many merge transactions of it committed
    replayed,    \* branch -> the writes those transactions replayed
    forkCopy,    \* the writes the fork copied from its parent
    acked        \* the writes of actions that succeeded

vars == <<db, store, proc, marker, tooLarge, watcherDue, pc, actState, nextAct, externals,
          kills, crashes, committed, replayed, forkCopy, acked>>

LogSet(l) == {l[i] : i \in DOMAIN l}
Without(l, w) == SelectSeq(l, LAMBDA x : x # w)

\* The write that set key k last: what the overlay should hold for k.
RECURSIVE LastOn(_, _)
LastOn(l, k) == IF l = <<>> THEN 0
                ELSE IF l[Len(l)].key = k THEN l[Len(l)].act ELSE LastOn(SubSeq(l, 1, Len(l) - 1), k)

EmptyFp == [k \in Keys |-> NoFp]
EmptyOv == [k \in Keys |-> 0]
Absent == [status |-> "absent", log |-> <<>>, fp |-> EmptyFp, ov |-> EmptyOv]
DeadProc == [alive |-> FALSE, status |-> "absent", log |-> <<>>, fp |-> EmptyFp, ov |-> EmptyOv,
             claim |-> None, pending |-> {}]
IdlePc == [op |-> "idle", b |-> Root, w |-> NoWrite, stage |-> "none", snap |-> <<>>, held |-> Absent,
           ignore |-> FALSE, committed |-> FALSE, result |-> "none"]

Stored(p) == [status |-> p.status, log |-> p.log, fp |-> p.fp, ov |-> p.ov]
Loaded(s) == [alive |-> TRUE, status |-> s.status, log |-> s.log, fp |-> s.fp, ov |-> s.ov,
              claim |-> None, pending |-> {}]

\* Ramal.Branch.undo/2 of one write: the overlay entry and the base entry go back to what they were.
Undo(p, w) == [p EXCEPT !.log = Without(@, w),
                        !.ov = [@ EXCEPT ![w.key] = w.prev],
                        !.fp = IF w.setFp THEN [@ EXCEPT ![w.key] = NoFp] ELSE @,
                        !.pending = @ \ {w}]
RECURSIVE UndoAll(_, _)
UndoAll(p, ws) == IF ws = {} THEN p ELSE LET w == CHOOSE x \in ws : TRUE IN UndoAll(Undo(p, w), ws \ {w})

\* Server.usable?/1: open and not claimed by a merge.
Usable(b) == proc[b].alive /\ proc[b].status = "open" /\ proc[b].claim = None
\* With FixPending, a merge, a proposal and an idle unload wait for the actions in flight.
Quiet(b) == ~FixPending \/ proc[b].pending = {}
Stop(b) == /\ proc' = [proc EXCEPT ![b] = DeadProc]
           /\ marker' = [marker EXCEPT ![b] = FALSE]

Init ==
    /\ db = [k \in Keys |-> 1]
    /\ store = [b \in Branches |-> IF b = Root THEN [Absent EXCEPT !.status = "open"] ELSE Absent]
    /\ proc = [b \in Branches |-> IF b = Root THEN Loaded(store[Root]) ELSE DeadProc]
    /\ marker = [b \in Branches |-> b = Root]
    /\ tooLarge = [b \in Branches |-> FALSE]
    /\ watcherDue = [b \in Branches |-> FALSE]
    /\ pc = [c \in Clients |-> IdlePc]
    /\ actState = [a \in Acts |-> "none"]
    /\ nextAct = 0 /\ externals = 0 /\ kills = 0 /\ crashes = 0
    /\ committed = [b \in Branches |-> 0]
    /\ replayed = [b \in Branches |-> {}]
    /\ forkCopy = {}
    /\ acked = {}

---------------------------------------------------------------------------
(* Processes *)

\* Server.ensure_started/2: a call for a branch with no process loads it from storage.
Start(b) ==
    /\ ~proc[b].alive /\ store[b].status # "absent" /\ ~tooLarge[b]
    /\ IF FixMarker /\ marker[b]
         THEN /\ tooLarge' = [tooLarge EXCEPT ![b] = TRUE]
              /\ UNCHANGED <<proc, marker>>
         ELSE /\ proc' = [proc EXCEPT ![b] = Loaded(store[b])]
              /\ marker' = [marker EXCEPT ![b] = TRUE]
              /\ UNCHANGED tooLarge
    /\ UNCHANGED <<db, store, watcherDue, pc, actState, nextAct, externals, kills, crashes,
                   committed, replayed, forkCopy, acked>>

\* handle_info(:timeout, _): persist, then stop. Never while claimed (timeout/1 is :infinity then).
Idle(b) ==
    /\ proc[b].alive /\ proc[b].claim = None /\ Quiet(b)
    /\ \/ /\ store' = [store EXCEPT ![b] = Stored(proc[b])]
          /\ Stop(b)
       \/ UNCHANGED <<store, proc, marker>>                 \* the storage refused: stay up
    /\ UNCHANGED <<db, tooLarge, watcherDue, pc, actState, nextAct, externals, kills, crashes,
                   committed, replayed, forkCopy, acked>>

\* max_heap_size kills the process: no terminate/2, no persist. The watcher marks it later.
Kill(b) ==
    /\ proc[b].alive /\ kills < MaxKills
    /\ proc' = [proc EXCEPT ![b] = DeadProc]
    /\ watcherDue' = [watcherDue EXCEPT ![b] = TRUE]
    /\ kills' = kills + 1
    /\ UNCHANGED <<db, store, marker, tooLarge, pc, actState, nextAct, externals, crashes,
                   committed, replayed, forkCopy, acked>>

\* The watcher spawned by Server.watch/1 sees {:DOWN, _, _, _, :killed}.
Watcher(b) ==
    /\ watcherDue[b]
    /\ tooLarge' = [tooLarge EXCEPT ![b] = TRUE]
    /\ watcherDue' = [watcherDue EXCEPT ![b] = FALSE]
    /\ UNCHANGED <<db, store, proc, marker, pc, actState, nextAct, externals, kills, crashes,
                   committed, replayed, forkCopy, acked>>

\* With FixPending the process monitors a writer until its action settles; a writer that died is undone.
Down(b) ==
    /\ FixPending /\ proc[b].alive
    /\ \E w \in proc[b].pending :
         /\ actState[w.act] = "crashed"
         /\ proc' = [proc EXCEPT ![b] = Undo(@, w)]
    /\ UNCHANGED <<db, store, marker, tooLarge, watcherDue, pc, actState, nextAct, externals, kills,
                   crashes, committed, replayed, forkCopy, acked>>

\* The node restarts. Storage survives; processes, the registry and the ETS tables do not.
NodeCrash ==
    /\ crashes < NodeCrashes
    /\ crashes' = crashes + 1
    /\ proc' = [b \in Branches |-> DeadProc]
    /\ marker' = [b \in Branches |-> FALSE]
    /\ tooLarge' = [b \in Branches |-> FALSE]
    /\ watcherDue' = [b \in Branches |-> FALSE]
    /\ actState' = [a \in Acts |-> IF actState[a] = "running" THEN "crashed" ELSE actState[a]]
    /\ pc' = [c \in Clients |-> IdlePc]
    \* Writes not yet persisted live only in the process (Ramal.Storage), so a restart loses them by design.
    /\ acked' = {w \in acked : w \in LogSet(store[w.branch].log)}
    /\ UNCHANGED <<db, store, nextAct, externals, kills, committed, replayed, forkCopy>>

\* Someone writes the base outside any branch.
External(k) ==
    /\ externals < MaxExternal
    /\ externals' = externals + 1
    /\ db' = [db EXCEPT ![k] = @ + 1]
    /\ UNCHANGED <<store, proc, marker, tooLarge, watcherDue, pc, actState, nextAct, kills, crashes,
                   committed, replayed, forkCopy, acked>>

---------------------------------------------------------------------------
(* Callers *)

Others == <<db, store, marker, tooLarge, watcherDue, externals, kills, crashes, committed, replayed, forkCopy, acked>>

\* Ramal.Preparation: a read fingerprints the base rows it returns (Branch.put_fingerprints/2).
Read(c, b, k) ==
    /\ pc[c].op = "idle" /\ Usable(b) /\ proc[b].fp[k] = NoFp
    /\ proc' = [proc EXCEPT ![b].fp[k] = db[k]]
    /\ UNCHANGED <<db, store, marker, tooLarge, watcherDue, pc, actState, nextAct, externals, kills,
                   crashes, committed, replayed, forkCopy, acked>>

\* Ramal.Capture.write/3: an action's before_action hook puts its write in the branch (Server.write/2).
\* With FixPending the process refuses a write to a row another running action wrote, as a row lock would.
Locked(b, k) == FixPending /\ \E w \in proc[b].pending : w.key = k
Write(c, b, k) ==
    /\ pc[c].op = "idle" /\ nextAct < MaxActs /\ Usable(b) /\ ~Locked(b, k)
    /\ LET a == nextAct + 1
           w == [act |-> a, key |-> k, branch |-> b, setFp |-> proc[b].fp[k] = NoFp, prev |-> proc[b].ov[k]]
       IN /\ nextAct' = a
          /\ actState' = [actState EXCEPT ![a] = "running"]
          /\ proc' = [proc EXCEPT ![b].log = Append(@, w),
                                  ![b].ov = [@ EXCEPT ![k] = a],
                                  ![b].fp = IF w.setFp THEN [@ EXCEPT ![k] = db[k]] ELSE @,
                                  ![b].pending = IF FixPending THEN @ \union {w} ELSE @]
          /\ pc' = [pc EXCEPT ![c] = [IdlePc EXCEPT !.op = "act", !.b = b, !.w = w]]
    /\ UNCHANGED Others

\* The rest of the action (its after_action hooks) succeeds. With FixPending the caller tells the process.
Succeed(c) ==
    /\ pc[c].op = "act"
    /\ actState' = [actState EXCEPT ![pc[c].w.act] = "ok"]
    /\ proc' = IF FixPending /\ proc[pc[c].b].alive
                 THEN [proc EXCEPT ![pc[c].b].pending = @ \ {pc[c].w}]
                 ELSE proc
    /\ pc' = [pc EXCEPT ![c] = IdlePc]
    /\ acked' = acked \union {pc[c].w}
    /\ UNCHANGED <<db, store, marker, tooLarge, watcherDue, nextAct, externals, kills, crashes,
                   committed, replayed, forkCopy>>

\* The action fails after its write: Capture.rollback/3 sends the undo. Without FixPending it goes through
\* Server.update/2, which refuses it unless the branch is usable; the error is ignored.
Fail(c) ==
    LET b == pc[c].b
        w == pc[c].w
    IN /\ pc[c].op = "act" /\ proc[b].alive
       /\ actState' = [actState EXCEPT ![w.act] = "failed"]
       /\ proc' = IF (FixPending /\ w \in proc[b].pending) \/ (~FixPending /\ Usable(b) /\ w \in LogSet(proc[b].log))
                    THEN [proc EXCEPT ![b] = Undo(@, w)]
                    ELSE proc
       /\ pc' = [pc EXCEPT ![c] = IdlePc]
       /\ UNCHANGED <<db, store, marker, tooLarge, watcherDue, nextAct, externals, kills, crashes,
                      committed, replayed, forkCopy, acked>>

\* The process running the action dies (a killed task, a crashed LiveView) before the action ends.
Crash(c) ==
    /\ pc[c].op = "act"
    /\ actState' = [actState EXCEPT ![pc[c].w.act] = "crashed"]
    /\ pc' = [pc EXCEPT ![c] = IdlePc]
    /\ UNCHANGED <<db, store, proc, marker, tooLarge, watcherDue, nextAct, externals, kills, crashes,
                   committed, replayed, forkCopy, acked>>

\* Ramal.fork/2: Server.fork_source/1, storage.put/2 of the fork, Server.start_forked/2.
\* With FixPending the fork is taken without the writes of actions still running.
ForkIt(c) ==
    /\ pc[c].op = "idle" /\ Usable(Root) /\ store[Fork].status = "absent"
    /\ LET src == IF FixPending THEN UndoAll(proc[Root], proc[Root].pending) ELSE proc[Root]
           f == [status |-> "open", log |-> src.log, fp |-> src.fp, ov |-> src.ov]
       IN /\ store' = [store EXCEPT ![Fork] = f]
          /\ proc' = [proc EXCEPT ![Fork] = Loaded(f)]
          /\ forkCopy' = LogSet(src.log)
    /\ marker' = [marker EXCEPT ![Fork] = TRUE]
    /\ UNCHANGED <<db, tooLarge, watcherDue, pc, actState, nextAct, externals, kills, crashes,
                   committed, replayed, acked>>

\* Ramal.propose/2: the proposed branch is persisted before the call returns; a refused persist changes nothing.
Propose(c, b) ==
    /\ pc[c].op = "idle" /\ Usable(b) /\ Quiet(b)
    /\ \/ LET p == [proc[b] EXCEPT !.status = "proposed"]
          IN /\ proc' = [proc EXCEPT ![b] = p]
             /\ store' = [store EXCEPT ![b] = Stored(p)]
       \/ UNCHANGED <<proc, store>>
    /\ UNCHANGED <<db, marker, tooLarge, watcherDue, pc, actState, nextAct, externals, kills, crashes,
                   committed, replayed, forkCopy, acked>>

\* Ramal.reject/2 and Ramal.discard/1: persist, then stop.
Close(c, b, from, to) ==
    /\ pc[c].op = "idle" /\ proc[b].alive /\ proc[b].claim = None /\ proc[b].status \in from
    /\ LET p == IF to = "discarded" THEN [proc[b] EXCEPT !.status = to, !.log = <<>>, !.ov = EmptyOv, !.fp = EmptyFp]
                ELSE [proc[b] EXCEPT !.status = to]
       IN /\ store' = [store EXCEPT ![b] = Stored(p)]
          /\ Stop(b)
    /\ UNCHANGED <<db, tooLarge, watcherDue, pc, actState, nextAct, externals, kills, crashes,
                   committed, replayed, forkCopy, acked>>

\* Server.begin_merge/2 for Ramal.merge/2 (from "open") and Ramal.approve/2 (from "proposed").
Claim(c, b, from) ==
    /\ pc[c].op = "idle" /\ proc[b].alive /\ proc[b].status = from /\ proc[b].claim = None /\ Quiet(b)
    /\ proc' = [proc EXCEPT ![b].claim = c]
    /\ \E ignore \in BOOLEAN :
         pc' = [pc EXCEPT ![c] = [IdlePc EXCEPT !.op = "merge", !.b = b, !.stage = "claimed",
                                   !.snap = proc[b].log, !.held = Stored(proc[b]), !.ignore = ignore]]
    /\ UNCHANGED <<db, store, marker, tooLarge, watcherDue, actState, nextAct, externals, kills, crashes,
                   committed, replayed, forkCopy, acked>>

\* Merge.merge/3: one transaction checks the fingerprints, replays the log and, with FixMergedMark, stores the
\* branch as merged (storage.mark_merged/2, in the same transaction), or rolls back.
Stale(b) == {k \in Keys : proc[b].fp[k] # NoFp /\ proc[b].fp[k] # db[k]}
RECURSIVE Replay(_, _)
Replay(d, l) == IF l = <<>> THEN d ELSE Replay([d EXCEPT ![l[1].key] = @ + 1], Tail(l))
StoredMerged(b) == store[b].status = "merged"

Commit(c) ==
    LET b == pc[c].b IN
    /\ pc[c].op = "merge" /\ pc[c].stage = "claimed"
    /\ Stale(b) = {} \/ pc[c].ignore
    /\ ~(FixMergedMark /\ StoredMerged(b))
    /\ db' = Replay(db, pc[c].snap)
    /\ committed' = [committed EXCEPT ![b] = @ + 1]
    /\ replayed' = [replayed EXCEPT ![b] = @ \union LogSet(pc[c].snap)]
    /\ pc' = [pc EXCEPT ![c].stage = "committed", ![c].committed = TRUE]
    /\ store' = IF FixMergedMark THEN [store EXCEPT ![b] = [pc[c].held EXCEPT !.status = "merged"]] ELSE store
    /\ UNCHANGED <<proc, marker, tooLarge, watcherDue, actState, nextAct, externals, kills, crashes,
                   forkCopy, acked>>

\* The mark finds the branch stored as merged by an earlier merge whose process this one did not hear of: the
\* transaction rolls back, and finish_merge(:stored) stops the process as merged without writing.
MarkRefused(c) ==
    LET b == pc[c].b IN
    /\ FixMergedMark /\ pc[c].op = "merge" /\ pc[c].stage = "claimed" /\ StoredMerged(b)
    /\ IF proc[b].alive /\ proc[b].claim = c THEN Stop(b) ELSE UNCHANGED <<proc, marker>>
    /\ pc' = [pc EXCEPT ![c] = IdlePc]
    /\ UNCHANGED <<db, store, tooLarge, watcherDue, actState, nextAct, externals, kills, crashes,
                   committed, replayed, forkCopy, acked>>

\* The base is stale (on_stale: :error) or a replayed action fails: rolled back, then finish_merge(:aborted).
Abort(c) ==
    LET b == pc[c].b IN
    /\ pc[c].op = "merge" /\ pc[c].stage = "claimed" /\ proc[b].alive
    /\ proc' = IF proc[b].claim = c THEN [proc EXCEPT ![b].claim = None] ELSE proc
    /\ pc' = [pc EXCEPT ![c] = IdlePc]
    /\ UNCHANGED <<db, store, marker, tooLarge, watcherDue, actState, nextAct, externals, kills, crashes,
                   committed, replayed, forkCopy, acked>>

\* Server.finish_merge(:merged): persist the merged branch and stop, or keep it loaded as merged (ADR 0023).
Finish(c) ==
    LET b == pc[c].b IN
    /\ pc[c].op = "merge" /\ pc[c].stage = "committed"
    /\ IF proc[b].alive /\ proc[b].claim = c
         THEN \/ /\ store' = [store EXCEPT ![b] = Stored([proc[b] EXCEPT !.status = "merged"])]
                 /\ Stop(b)
              \/ /\ proc' = [proc EXCEPT ![b].status = "merged", ![b].claim = None]
                 /\ UNCHANGED <<store, marker>>
         ELSE UNCHANGED <<store, proc, marker>>                \* a timeout: reported as persist_failed
    /\ pc' = [pc EXCEPT ![c].stage = "done", ![c].result = "ok"]
    /\ UNCHANGED <<db, tooLarge, watcherDue, actState, nextAct, externals, kills, crashes,
                   committed, replayed, forkCopy, acked>>

Forget(c) == /\ pc[c].op = "merge" /\ pc[c].stage = "done"
             /\ pc' = [pc EXCEPT ![c] = IdlePc]
             /\ UNCHANGED <<db, store, proc, marker, tooLarge, watcherDue, actState, nextAct, externals,
                            kills, crashes, committed, replayed, forkCopy, acked>>

\* A merging process dies between the commit and finish_merge: the monitor releases the claim. With FixMergedMark
\* the process first asks the storage, and stops as merged if the transaction stored it so (Server.stored_merged?/1).
MergerDies(c) ==
    LET b == pc[c].b IN
    /\ crashes < MergerCrashes
    /\ pc[c].op = "merge" /\ pc[c].stage = "committed"
    /\ crashes' = crashes + 1
    /\ IF proc[b].alive /\ proc[b].claim = c
         THEN IF FixMergedMark /\ StoredMerged(b)
                THEN Stop(b)
                ELSE /\ proc' = [proc EXCEPT ![b].claim = None]
                     /\ UNCHANGED marker
         ELSE UNCHANGED <<proc, marker>>
    /\ pc' = [pc EXCEPT ![c] = IdlePc]
    /\ UNCHANGED <<db, store, tooLarge, watcherDue, actState, nextAct, externals, kills,
                   committed, replayed, forkCopy, acked>>

Next ==
    \/ \E b \in Branches : Start(b) \/ Idle(b) \/ Kill(b) \/ Watcher(b) \/ Down(b)
    \/ NodeCrash
    \/ \E k \in Keys : External(k)
    \/ \E c \in Clients :
         \/ Succeed(c) \/ Fail(c) \/ Crash(c) \/ ForkIt(c)
         \/ Commit(c) \/ MarkRefused(c) \/ Abort(c) \/ Finish(c) \/ Forget(c) \/ MergerDies(c)
         \/ \E b \in Branches :
              \/ Propose(c, b) \/ Claim(c, b, "open") \/ Claim(c, b, "proposed")
              \/ Close(c, b, {"proposed"}, "rejected") \/ Close(c, b, {"open", "proposed"}, "discarded")
              \/ \E k \in Keys : Read(c, b, k) \/ Write(c, b, k)

Spec == Init /\ [][Next]_vars

---------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ \A b \in Branches : proc[b].claim \in Clients \union {None}
    /\ \A b \in Branches : LogSet(proc[b].log) \subseteq Writes /\ LogSet(store[b].log) \subseteq Writes
    /\ \A c \in Clients : pc[c].op \in {"idle", "act", "merge"}

\* A merge transaction of a branch commits at most once.
MergeOnce == \A b \in Branches : committed[b] <= 1

\* At most one caller holds a branch between claim and finish.
OneMerger == \A b \in Branches : Cardinality({c \in Clients : pc[c].op = "merge" /\ pc[c].b = b
                                                         /\ pc[c].stage \in {"claimed", "committed"}}) <= 1

\* A merge, a fork and a proposal never take the write of an action that failed or died.
NoPhantomWrite ==
    /\ \A b \in Branches : \A w \in replayed[b] : actState[w.act] \notin Failed
    /\ \A w \in forkCopy : actState[w.act] \notin Failed
    /\ \A b \in Branches : store[b].status = "proposed" =>
                             \A w \in LogSet(store[b].log) : actState[w.act] \notin Failed

\* A committed merge replays every write of every action that succeeded in the branch.
NoLostWrite == \A b \in Branches : committed[b] > 0 => {w \in acked : w.branch = b} \subseteq replayed[b]

\* What a read in the branch sees (the overlay) is what the log says, so a merge replays what the branch showed.
OverlayMatchesLog ==
    \A b \in Branches : proc[b].alive => \A k \in Keys : proc[b].ov[k] = LastOn(proc[b].log, k)

\* A merge reported as failed did not commit (ADR 0023).
CommitIsFinal == \A c \in Clients : ~(pc[c].result = "error" /\ pc[c].committed)

\* Stored statuses only move forward, and a merged, rejected or discarded branch stays so.
Order == [s \in {"absent", "open", "proposed", "merged", "rejected", "discarded"} |->
            CASE s = "absent" -> 0 [] s = "open" -> 1 [] s = "proposed" -> 2 [] OTHER -> 3]
StatusMonotonic ==
    [][\A b \in Branches : /\ Order[store'[b].status] >= Order[store[b].status]
                           /\ Order[store[b].status] = 3 => store'[b].status = store[b].status]_vars

\* A branch whose merge committed is never claimed again.
NoClaimAfterCommit ==
    [][\A c \in Clients : (pc'[c].stage = "claimed" /\ pc[c].stage # "claimed") => committed[pc'[c].b] = 0]_vars
=============================================================================
