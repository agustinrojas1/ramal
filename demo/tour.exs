# The story the walkthrough tells, one chapter at a time. Run it through walkthrough.exs, which installs the dependencies
# and loads the farm first. Every chapter prints the line of this file it starts on.

import Demo.UI
require Demo.UI
require Ash.Query

alias Demo.View

Farm.Data.configure!()

case Farm.Data.setup!() do
  :ok ->
    :ok

  {:error, message} ->
    IO.puts(IO.ANSI.format([:red, :bright, "\n#{message}\n", :reset]))
    IO.puts("Start Postgres with `docker compose -f demo/docker-compose.yml up -d`, or point the walkthrough at your own:")
    IO.puts("RAMAL_PG_HOST, RAMAL_PG_PORT, RAMAL_PG_USER, RAMAL_PG_PASSWORD (see demo/README.md).")
    System.halt(1)
end

{:ok, _} = Supervisor.start_link([Farm.Repo, {Ramal.Supervisor, storage: Ramal.Storage.ETS}], strategy: :one_for_one)

p = Farm.Data.seed!()
manager = %{name: "Marta", role: :manager}
visitor = %{name: "A visitor", role: :guest}

IO.puts(IO.ANSI.format([:bright, "\nRamal: Git-style branches of your Ash data", :reset]))
note("A branch is a process that holds changes in memory. Postgres is only written when you merge.")

# ---------------------------------------------------------------------------------------------------------------------
chapter "The farm" do
  say("Four paddocks and four herds, in Postgres. Paddocks have a capacity; herd R7 is crowding L07 with R8.")

  View.print_herds(View.postgres_herds())

  note("")
  note("The data layer is AshPostgres and the actions are ordinary Ash actions. The only Ramal line in each resource is")
  note("`extensions: [Ramal.Resource]` (see farm.exs). The app's supervision tree starts `Ramal.Supervisor`.")
end

# ---------------------------------------------------------------------------------------------------------------------
chapter "Open a branch and change things inside it" do
  say("Branch A explores one idea: move herd R7 to paddock L18. Ramal.run! runs the real `move` action inside it.")

  {:ok, a} = Ramal.branch(Farm, name: "A: R7 to L18")

  Ramal.run!(a, fn ->
    Ash.update!(View.herd("R7"), %{to_paddock_id: p.l18.id}, action: :move, actor: manager)

    label("A read inside the branch sees the move:")
    View.print_herds(View.herds())
  end)

  note("")
  label("The same read outside the branch, and Postgres itself with plain SQL, see nothing:")
  View.print_herds(View.herds())
  show("moves logged in Postgres: #{View.postgres_moves()}")
  ok("branch A holds the change; the database is untouched")

  say("\nThe action's rules still apply inside a branch. A policy first (only a manager may move a herd):")

  result = Ramal.run!(a, fn -> Ash.update(View.herd("R8"), %{to_paddock_id: p.l22.id}, action: :move, actor: visitor) end)
  refused("a visitor was refused: #{View.reason(result)}")

  say("A validation next (L31 holds 45 head and herd R10 already has 40, so R7's 30 do not fit):")

  result = Ramal.run!(a, fn -> Ash.update(View.herd("R7"), %{to_paddock_id: p.l31.id}, action: :move, actor: manager) end)
  refused("the move was refused: #{View.reason(result)}")

end

# ---------------------------------------------------------------------------------------------------------------------
chapter "Diff: what would this branch change?" do
  say("Ramal.diff lists every row the branch changed, computed from the branch itself without asking Postgres.")

  {:ok, changes} = Ramal.diff(a)
  View.print_diff(changes)

  note("")
  note("The second line is the audit row that the `move` action creates after it succeeds (a hook). The branch holds it too,")
  note("so a read of the moves table inside the branch would show it.")
end

# ---------------------------------------------------------------------------------------------------------------------
chapter "Fork, and try an alternative next to it" do
  say("A fork starts where its parent is. Here A2 builds on A and also moves herd R9 to L22; A stays as it was.")

  {:ok, a2} = Ramal.fork(a, name: "A2: A, plus R9 to L22")
  Ramal.run!(a2, fn -> Ash.update!(View.herd("R9"), %{to_paddock_id: p.l22.id}, action: :move, actor: manager) end)

  {:ok, a_changes} = Ramal.diff(a)
  {:ok, a2_changes} = Ramal.diff(a2)
  show("A  has #{length(a_changes)} changes, A2 has #{length(a2_changes)} (what it inherited plus its own):")
  View.print_diff(a2_changes)

  say("\nA different idea, started from the database: branch B moves R7 to L22 instead.")

  {:ok, b} = Ramal.branch(Farm, name: "B: R7 to L22")
  Ramal.run!(b, fn -> Ash.update!(View.herd("R7"), %{to_paddock_id: p.l22.id}, action: :move, actor: manager) end)

  {:ok, open} = Ramal.list(Farm, status: :open)
  note("")
  ok("#{length(open)} branches are open at once: #{open |> Enum.map(& &1.name) |> Enum.sort() |> Enum.join(" | ")}")
  note("Each one is a process holding a map. Opening a branch copies nothing from Postgres.")

end

# ---------------------------------------------------------------------------------------------------------------------
chapter "Count and sum inside a branch" do
  say("How many head would each paddock hold in A2? Ramal.aggregate asks Postgres about the rows the branch did not touch,")
  say("then adds the rows it did, so the cost follows the size of the branch, not of the table.")

  head_in = fn paddock ->
    Farm.Herd |> Ash.Query.filter(paddock_id == ^paddock.id) |> Ramal.aggregate!(:sum, :head) || 0
  end

  rows =
    for name <- [:l07, :l18, :l22, :l31] do
      paddock = Map.fetch!(p, name)
      in_branch = Ramal.run!(a2, fn -> head_in.(paddock) end)
      [name |> to_string() |> String.upcase(), to_string(paddock.capacity_head), to_string(head_in.(paddock)), to_string(in_branch)]
    end

  table(["paddock", "capacity", "head now (Postgres)", "head in A2"], rows)

  total = fn -> Farm.Herd |> Ramal.aggregate!(:sum, :head) end
  ok("total head: #{total.()} in Postgres, #{Ramal.run!(a2, total)} in A2 (a move changes where, not how many)")

  note("")
  say("The catch: aggregates Ash hands to the database (`Ash.count!`, or an `aggregates do ... end` block) cannot see a branch.")
  in_l22 = Farm.Herd |> Ash.Query.filter(paddock_id == ^p.l22.id)
  plain = Ramal.run!(a2, fn -> Ash.count!(in_l22) end)
  exact = Ramal.run!(a2, fn -> Ramal.aggregate!(in_l22, :count) end)
  show("herds in L22 inside A2:  Ash.count! says #{plain}   Ramal.aggregate says #{exact}")
  note("Use Ramal.aggregate inside a branch. Ramal emits [:ramal, :read, :unpatched_aggregate] when a database aggregate runs in one.")
end

# ---------------------------------------------------------------------------------------------------------------------
chapter "Merge: replay the branch through your real actions" do
  say("A looks good. Merging replays its log, oldest first, through the same actions, in one Postgres transaction.")

  {:ok, result} = Ramal.merge(a, actor: manager)
  ok("merged: #{result.replayed} action replayed, branch status #{result.branch.status}")

  note("")
  label("Postgres now:")
  View.print_herds(View.postgres_herds())
  show("moves logged in Postgres: #{View.postgres_moves()} (the audit row was written by the real `move` action, once)")
end

# ---------------------------------------------------------------------------------------------------------------------
chapter "Stale branches are refused" do
  say("Branch B read herd R7 when R7 was in L07. A has since moved it, so B's picture of the farm is out of date.")

  {:error, %Ramal.Error{reason: :stale, details: %{rows: rows}}} = Ramal.merge(b, actor: manager)

  for row <- rows do
    refused("merge refused: herd #{View.herd_name(row.key)} #{row.reason} since the branch read it (#{inspect(row.resource)})")
  end

  show("Postgres still has R7 where A put it:")
  View.print_herds(Enum.filter(View.postgres_herds(), &(hd(&1) == "R7")))

  note("")
  note("Your options: discard the branch and start again from the new state, or merge with `on_stale: :ignore` when you")
  note("know the change still makes sense (the replay validates again either way). A2 forked from A, so it is stale too.")

  :ok = Ramal.discard(b)
  :ok = Ramal.discard(a2)
end

# ---------------------------------------------------------------------------------------------------------------------
chapter "A merge is all or nothing" do
  say("Branch C creates herd R11 in L22 and moves R9 there. Both fit in L22 at the time.")

  {:ok, c} = Ramal.branch(Farm, name: "C: R11 and R9 to L22")

  Ramal.run!(c, fn ->
    Ash.create!(Farm.Herd, %{name: "R11", head: 10, paddock_id: p.l22.id})
    Ash.update!(View.herd("R9"), %{to_paddock_id: p.l22.id}, action: :move, actor: manager)
  end)

  say("\nMeanwhile somebody writes straight to the database: herd R12, 60 head, also in L22 (capacity 80).")
  Ash.create!(Farm.Herd, %{name: "R12", head: 60, paddock_id: p.l22.id}, authorize?: false)

  say("\nMerging C replays R11's creation, which works, and then R9's move, which now overflows L22 (R12's 60 plus R11's 10):")

  {:error, %Ramal.Error{reason: :merge_failed, details: details}} = Ramal.merge(c, actor: manager)
  refused("merge failed at step #{details.index + 1} (#{inspect(details.action)}): #{View.reason({:error, details.error})}")

  show("Postgres, after the failed merge:")
  View.print_herds(View.postgres_herds())
  r11_in_postgres? = Enum.any?(View.postgres_herds(), &(hd(&1) == "R11"))
  {:ok, c_now} = Ramal.get(c.id)

  ok("R11 in Postgres: #{r11_in_postgres?}. The transaction rolled back, and branch C is still #{c_now.status}, so it can be fixed or discarded.")
  note("The staleness check only knows rows the branch read. The replay's validations catch what it could not know.")

  :ok = Ramal.discard(c)
end

# ---------------------------------------------------------------------------------------------------------------------
chapter "Propose, review, approve" do
  say("When an agent suggests and a person decides, freeze the branch as a proposal. Here an agent recounts herd R9.")

  {:ok, d} = Ramal.branch(Farm, name: "D: recount R9")
  Ramal.run!(d, fn -> Ash.update!(View.herd("R9"), %{head: 27}) end)

  {:ok, _} = Ramal.propose(d, proposed_by: "counting-agent", reason: "the gate counter says 27, not 25")

  {:ok, pending} = Ramal.list(Farm, status: :proposed)
  show("waiting for a decision: #{Enum.map_join(pending, ", ", & &1.name)}")
  {:ok, changes} = Ramal.diff(d)
  show("what the reviewer reads:")
  View.print_diff(changes)

  say("\nMarta approves. Approving is merging, with the decision recorded on the branch.")

  {:ok, %{branch: decided}} = Ramal.approve(d, decided_by: "Marta", actor: manager, reason: "checked at the gate")
  decision = decided.proposal.decision
  ok("#{decision.status} by #{decision.by} at #{Calendar.strftime(decision.at, "%H:%M:%S")}: #{decision.reason}")

  note("Ramal does not decide who may approve. Check that in your own policies before you call approve/2.")
end

# ---------------------------------------------------------------------------------------------------------------------
chapter "Where the farm ended up" do
  View.print_herds(View.postgres_herds())

  {:ok, all} = Ramal.list(Farm)
  note("")
  show("branches Ramal remembers:")
  table(["branch", "status"], all |> Enum.sort_by(& &1.name) |> Enum.map(&[&1.name, to_string(&1.status)]))

  note("")
  note("Branches here live in ETS and disappear when the script ends. In an app, `Ramal.Storage.Postgres` keeps them")
  note("across restarts (`mix ramal.gen.migration`). See the README for the full list of what a branch cannot do.")
end

IO.puts(IO.ANSI.format([:bright, :green, "\nThat is the whole loop: branch, change, diff, fork, merge or discard.", :reset]))
IO.puts("To watch branches as columns in a browser, run: elixir ramal_live/examples/farm_demo.exs (see demo/README.md).\n")
