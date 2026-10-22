defmodule RamalLive.BroadcasterTest do
  use RamalLive.LiveCase

  alias RamalLive.{Broadcaster, Events}

  setup do
    Phoenix.PubSub.subscribe(RamalLive.Test.PubSub, Events.topic(RamalLive.Test.Farm))
    :ok
  end

  test "it attaches the handlers while it runs and detaches them when it stops" do
    refute Broadcaster.attached?(RamalLive.Test.PubSub)

    pid = start_supervised!({Broadcaster, pubsub: RamalLive.Test.PubSub})
    assert Broadcaster.attached?(RamalLive.Test.PubSub)

    :ok = stop_supervised(Broadcaster)
    refute Process.alive?(pid)
    refute Broadcaster.attached?(RamalLive.Test.PubSub)
  end

  test "a second broadcaster for the same PubSub is refused, since every event would arrive twice" do
    start_supervised!({Broadcaster, pubsub: RamalLive.Test.PubSub})
    Process.flag(:trap_exit, true)

    assert {:error, {:already_attached, RamalLive.Test.PubSub}} =
             Broadcaster.start_link(pubsub: RamalLive.Test.PubSub)

    # The refused one must not have taken the first one's handlers with it.
    assert Broadcaster.attached?(RamalLive.Test.PubSub)
  end

  test "a branch's life is announced: create, write, propose, reject" do
    start_supervised!({Broadcaster, pubsub: RamalLive.Test.PubSub})
    herd = herd!("R7", 30)

    {:ok, branch} = Ramal.branch(RamalLive.Test.Farm, name: "announce")
    assert_receive {:ramal_live, id, [:ramal, :branch, :create]}
    assert id == branch.id

    Ramal.run!(branch, fn -> Ash.update!(herd, %{head: 31}) end)
    assert_receive {:ramal_live, ^id, [:ramal, :write, :capture]}

    {:ok, _} = Ramal.propose(branch, proposed_by: "agent", reason: "why")
    assert_receive {:ramal_live, ^id, [:ramal, :branch, :propose]}

    {:ok, _} = Ramal.reject(branch)
    assert_receive {:ramal_live, ^id, [:ramal, :branch, :reject]}
  end

  test "a fork, a discard and a merge are announced" do
    start_supervised!({Broadcaster, pubsub: RamalLive.Test.PubSub})
    herd = herd!("R7", 30)
    branch = branch!("parent", fn -> Ash.update!(herd, %{head: 31}) end)
    flush_messages()

    {:ok, fork} = Ramal.fork(branch)
    assert_receive {:ramal_live, fork_id, [:ramal, :branch, :fork]}
    assert fork_id == fork.id

    :ok = Ramal.discard(fork)
    assert_receive {:ramal_live, ^fork_id, [:ramal, :branch, :discard]}

    {:ok, _} = Ramal.merge(branch)
    id = branch.id
    assert_receive {:ramal_live, ^id, [:ramal, :merge, :stop]}
  end

  test "nothing is announced when it is not running" do
    branch!("quiet")
    refute_receive {:ramal_live, _, _}, 30
  end

  test "a PubSub that went away does not crash the branch that emitted the event" do
    pid = start_supervised!({Broadcaster, pubsub: :gone_pubsub})
    assert Broadcaster.attached?(:gone_pubsub)

    assert {:ok, _branch} = Ramal.branch(RamalLive.Test.Farm)
    assert Process.alive?(pid)
    assert Broadcaster.attached?(:gone_pubsub)
  end

  defp flush_messages do
    receive do
      {:ramal_live, _, _} -> flush_messages()
    after
      20 -> :ok
    end
  end
end
