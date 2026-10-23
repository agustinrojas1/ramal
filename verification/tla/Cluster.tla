------------------------------ MODULE Cluster ------------------------------
(***************************************************************************)
(* One branch in a cluster of nodes that share a database (ADR 0044):      *)
(* `:global` names the branch process, every load of the branch takes the  *)
(* next epoch from the storage, and a save is conditional on the epoch the *)
(* process loaded with.                                                    *)
(*                                                                         *)
(* This is a separate model from Ramal.tla, which stays about what one     *)
(* node's processes do with a branch. Here a write is just a number, the   *)
(* storage holds the set of writes it has, and the question is whether a   *)
(* process that lost the branch to another load can take back what the     *)
(* other saved. The network can split (each node then sees only its own    *)
(* process in `:global`), heal (`:global` keeps the process with the       *)
(* higher epoch, Ramal.Cluster.resolve/3), and a node can crash, which     *)
(* loses what its process had not saved, as on one node.                  *)
(*                                                                         *)
(* FixFence switches the epoch guard on. Off, a process saves whatever it  *)
(* holds, and TLC finds a write that was acknowledged and then silently    *)
(* dropped.                                                                *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Nodes,        \* the nodes; each can hold at most one process of the branch
    MaxWrites,    \* writes acknowledged to callers
    MaxLoads,     \* times a node loads the branch from storage
    MaxSplits,    \* times the network splits
    MaxCrashes,   \* node crashes
    FixFence      \* a save is refused unless the process holds the storage's epoch

None == "none"

VARIABLES
    store,        \* [data : the writes the storage holds, epoch : the storage's epoch]
    procs,        \* node -> [alive, epoch : the epoch it loaded with, data : the writes it holds]
    view,         \* node -> the node whose process this node's :global points to, or None
    connected,    \* whether the nodes can see each other
    acked,        \* the writes a caller was told succeeded
    reported,     \* the writes a process announced as lost ([:ramal, :branch, :fenced])
    crashLost,    \* the writes lost with a crashed node: the limit Ramal documents, not a fencing failure
    nextW, loads, splits, crashes

vars == <<store, procs, view, connected, acked, reported, crashLost, nextW, loads, splits, crashes>>

Init ==
    /\ store = [data |-> {}, epoch |-> 0]
    /\ procs = [n \in Nodes |-> [alive |-> FALSE, epoch |-> 0, data |-> {}]]
    /\ view = [n \in Nodes |-> None]
    /\ connected = TRUE
    /\ acked = {} /\ reported = {} /\ crashLost = {}
    /\ nextW = 0 /\ loads = 0 /\ splits = 0 /\ crashes = 0

\* A name goes when its process does: on every node that can see the dying node.
Forget(n) == [m \in Nodes |-> IF view[m] = n THEN None ELSE view[m]]

---------------------------------------------------------------------------

\* Server.init/1: the process won the name, and claims the branch (Storage.claim/2): the epoch goes up and the process
\* has the state as of that epoch. :global registers the name on every node it is connected to.
Load(n) ==
    /\ loads < MaxLoads
    /\ ~procs[n].alive /\ view[n] = None
    /\ store' = [store EXCEPT !.epoch = @ + 1]
    /\ procs' = [procs EXCEPT ![n] = [alive |-> TRUE, epoch |-> store.epoch + 1, data |-> store.data]]
    /\ view' = [m \in Nodes |-> IF m = n \/ connected THEN n ELSE view[m]]
    /\ loads' = loads + 1
    /\ UNCHANGED <<connected, acked, reported, crashLost, nextW, splits, crashes>>

\* A caller on node n writes: the call goes to the process its :global names, wherever it runs.
Write(n) ==
    /\ nextW < MaxWrites
    /\ view[n] # None
    /\ LET o == view[n] IN
         /\ procs[o].alive /\ (o = n \/ connected)
         /\ procs' = [procs EXCEPT ![o].data = @ \union {nextW + 1}]
    /\ acked' = acked \union {nextW + 1}
    /\ nextW' = nextW + 1
    /\ UNCHANGED <<store, view, connected, reported, crashLost, loads, splits, crashes>>

\* handle_info(:timeout, _) (and a superseded process, which unloads the same way): save, then stop. With the fence,
\* a save by a process that is not on the storage's epoch is refused, the process announces what it held and stops.
Unload(n) ==
    /\ procs[n].alive
    /\ IF FixFence /\ procs[n].epoch # store.epoch
         THEN /\ reported' = reported \union (procs[n].data \ store.data)
              /\ UNCHANGED store
         ELSE /\ store' = [store EXCEPT !.data = procs[n].data]
              /\ UNCHANGED reported
    /\ procs' = [procs EXCEPT ![n].alive = FALSE]
    /\ view' = Forget(n)
    /\ UNCHANGED <<connected, acked, crashLost, nextW, loads, splits, crashes>>

\* The network splits: each node keeps in :global only the process it runs itself.
Split ==
    /\ connected /\ splits < MaxSplits
    /\ connected' = FALSE
    /\ view' = [m \in Nodes |-> IF view[m] = m THEN m ELSE None]
    /\ splits' = splits + 1
    /\ UNCHANGED <<store, procs, acked, reported, crashLost, nextW, loads, crashes>>

\* The nodes find each other. :global meets two processes with one name and Ramal.Cluster.resolve/3 keeps the higher
\* epoch (the lower is told to stop, which is the Unload step; until it takes it no caller reaches it).
Heal ==
    /\ ~connected
    /\ LET owners == {view[m] : m \in Nodes} \ {None}
           winner == IF owners = {} THEN None
                     ELSE CHOOSE o \in owners : \A p \in owners : procs[o].epoch >= procs[p].epoch
       IN view' = [m \in Nodes |-> winner]
    /\ connected' = TRUE
    /\ UNCHANGED <<store, procs, acked, reported, crashLost, nextW, loads, splits, crashes>>

\* A node crashes: no terminate/2, so what its process had not saved is lost. Ramal documents that (README, ADR 0022).
Crash(n) ==
    /\ procs[n].alive /\ crashes < MaxCrashes
    /\ crashLost' = crashLost \union (procs[n].data \ store.data)
    /\ procs' = [procs EXCEPT ![n].alive = FALSE]
    /\ view' = Forget(n)
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<store, connected, acked, reported, nextW, loads, splits>>

Next == Split \/ Heal \/ \E n \in Nodes : Load(n) \/ Write(n) \/ Unload(n) \/ Crash(n)

Spec == Init /\ [][Next]_vars

---------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ store.data \subseteq 1..MaxWrites
    /\ \A n \in Nodes : view[n] \in Nodes \union {None}
    /\ \A n \in Nodes : view[n] # None => procs[view[n]].alive

\* While the nodes see each other they agree on who holds the branch.
OneOwner == connected => \A m, n \in Nodes : view[m] = view[n]

\* A write a caller was told succeeded is in the storage, still held by a live process that can save it, announced as
\* lost by a process the storage fenced, or lost with a crashed node. It is never dropped without a trace.
NoLostUpdateUnreported ==
    \A w \in acked :
        \/ w \in store.data
        \/ \E n \in Nodes : procs[n].alive /\ w \in procs[n].data
        \/ w \in reported
        \/ w \in crashLost

\* The storage's set of writes only changes by a save of the process that holds the storage's epoch.
SingleWriter ==
    [][store'.data # store.data =>
         \E n \in Nodes : procs[n].alive /\ procs[n].epoch = store.epoch /\ store'.data = procs[n].data]_vars
=============================================================================
