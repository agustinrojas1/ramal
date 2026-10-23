defmodule Ramal.ClusterNodesTest do
  # Branches in a cluster (ADR 0044) on real nodes: two BEAM VMs started with :peer, sharing the test database, each
  # running Ramal.Supervisor with `cluster: true`. They are cut apart and joined again by disconnecting them. The nodes
  # take a second or two each to start, so this is the only module that does.
  use ExUnit.Case, async: false

  alias Ramal.ClusterNodes, as: Nodes

  @moduletag :cluster

  # Starts two nodes joined to each other and returns `%{a: {peer, node}, b: {peer, node}}`. The branches the test
  # creates are deleted afterwards, through the nodes.
  defp cluster(opts) do
    {pa, a} = Nodes.start("a", opts)
    {pb, b} = Nodes.start("b", opts)
    {:ok, ids} = Agent.start(fn -> [] end)

    on_exit(fn ->
      Nodes.call(pb, Nodes, :delete_branches, [Agent.get(ids, & &1)])
      Agent.stop(ids)
      Nodes.stop(pa)
      Nodes.stop(pb)
    end)

    Nodes.join(pa, pb, b)
    %{a: {pa, a}, b: {pb, b}, ids: ids}
  end

  defp new_branch(%{a: {pa, _}, ids: ids}) do
    {:ok, branch} = Nodes.call(pa, Nodes, :create_branch)
    Agent.update(ids, &[branch.id | &1])
    branch.id
  end

  defp herd(peer, id, name), do: {:ok, _} = Nodes.call(peer, Nodes, :create_herd, [id, name])
  defp created(peer, id), do: Nodes.call(peer, Nodes, :created, [id])
  defp holder(peer, id), do: Nodes.call(peer, Nodes, :holder_node, [id])
  defp events(peer), do: Nodes.call(peer, Nodes, :events)

  defp fenced(peer, id),
    do: for({[:ramal, :branch, :fenced], %{branch_id: ^id} = meta} <- events(peer), do: meta)

  defp eventually(fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait(fun, deadline)
  end

  defp wait(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false, []] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met in time")
        else
          Process.sleep(50)
          wait(fun, deadline)
        end

      value ->
        value
    end
  end

  describe "one process per branch" do
    test "every node reaches the process the branch lives in, and sees what any node writes" do
      %{a: {pa, a}, b: {pb, b}} = nodes = cluster(idle_timeout: 60_000)
      id = new_branch(nodes)

      assert holder(pa, id) == a
      assert holder(pb, id) == a

      herd(pb, id, "from b")
      herd(pa, id, "from a")

      assert created(pa, id) == ["from a", "from b"]
      assert created(pb, id) == ["from a", "from b"]
      assert holder(pb, id) == a
      refute holder(pa, id) == b
    end

    test "a branch nobody holds is loaded by the node that asks, from the shared storage" do
      %{a: {pa, a}, b: {pb, b}} = nodes = cluster(idle_timeout: 300)
      id = new_branch(nodes)
      herd(pa, id, "saved")

      # The idle timeout saves the branch and unloads it on the node that held it.
      eventually(fn -> holder(pa, id) == nil and holder(pb, id) == nil end)

      assert created(pb, id) == ["saved"]
      assert holder(pa, id) == b
      refute holder(pa, id) == a
    end

    test "a node that goes down takes with it what it had not saved, and another node loads the rest" do
      %{a: {pa, _}, b: {pb, b}} = nodes = cluster(idle_timeout: 60_000)
      id = new_branch(nodes)
      herd(pa, id, "unsaved")

      # A crash: halt skips terminate/2, so nothing is saved.
      catch_exit(Nodes.call(pa, :erlang, :halt, []))

      eventually(fn -> holder(pb, id) == nil end)
      assert created(pb, id) == []
      assert holder(pb, id) == b
    end
  end

  describe "fencing" do
    test "a node cut off from the holder loads the branch, and the holder is refused when it saves" do
      %{a: {pa, a}, b: {pb, b}} = nodes = cluster(idle_timeout: 600)
      id = new_branch(nodes)
      herd(pa, id, "only in a")
      assert holder(pb, id) == a

      Nodes.split(pa, a, pb, b)
      eventually(fn -> holder(pb, id) == nil end)

      # b cannot see a's process: it loads the branch as it was last saved, without what a holds.
      assert created(pb, id) == []
      assert holder(pb, id) == b
      herd(pb, id, "only in b")

      # a's process saves when it goes idle, and the storage refuses it.
      [event] = eventually(fn -> fenced(pa, id) end)
      assert event.epoch == 1
      assert %Ramal.Error{reason: :fenced} = event.error
      assert fenced(pb, id) == []
      assert holder(pa, id) == nil

      # b's process saves when it goes idle: its state is what the storage has, and a's write is not in it.
      eventually(fn -> holder(pb, id) == nil end)
      assert Nodes.call(pb, Nodes, :stored, [id]) == ["only in b"]
    end

    test "when the nodes meet again the process with the higher epoch keeps the branch" do
      %{a: {pa, a}, b: {pb, b}} = nodes = cluster(idle_timeout: 60_000)
      id = new_branch(nodes)
      herd(pa, id, "only in a")

      Nodes.split(pa, a, pb, b)
      eventually(fn -> holder(pb, id) == nil end)
      assert created(pb, id) == []
      herd(pb, id, "only in b")
      assert holder(pa, id) == a
      assert holder(pb, id) == b

      Nodes.join(pa, pb, b)

      [event] = eventually(fn -> fenced(pa, id) end)
      assert event.epoch == 1

      # Both nodes now reach the one process, the one that held epoch 2.
      eventually(fn -> holder(pa, id) == b and holder(pb, id) == b end)
      assert created(pa, id) == ["only in b"]
      assert created(pb, id) == ["only in b"]
      assert fenced(pb, id) == []
    end
  end
end
