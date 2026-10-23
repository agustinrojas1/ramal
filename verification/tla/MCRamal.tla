---- MODULE MCRamal ----
EXTENDS Ramal, TLC
Symmetry == Permutations(Clients)

\* For configurations about the processes of one branch (writes, undo, durable appends, restarts) that would be too big with
\* the lifecycle on top: no fork, no proposal, no merge. MC.cfg and MC-multi.cfg check those with the same writes.
ProcessOnly == /\ store[Fork].status = "absent"
               /\ store[Root].status = "open"
               /\ \A c \in Clients : pc[c].op \in {"idle", "act"}
====
