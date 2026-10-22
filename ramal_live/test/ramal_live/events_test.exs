defmodule RamalLive.EventsTest do
  use ExUnit.Case, async: true

  alias RamalLive.Events

  setup do
    pubsub = :"events_test_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    {:ok, pubsub: pubsub}
  end

  test "the topic belongs to the domain" do
    assert Events.topic(MyApp.Farm) == "ramal_live:Elixir.MyApp.Farm"
    refute Events.topic(MyApp.Farm) == Events.topic(MyApp.Other)
  end

  test "the handler broadcasts the branch id and the event on the domain's topic", %{
    pubsub: pubsub
  } do
    Phoenix.PubSub.subscribe(pubsub, Events.topic(MyApp.Farm))

    Events.handle(
      [:ramal, :write, :capture],
      %{system_time: 1},
      %{branch_id: "b1", domain: MyApp.Farm},
      %{
        pubsub: pubsub
      }
    )

    assert_receive {:ramal_live, "b1", [:ramal, :write, :capture]}
  end

  test "other domains do not hear it", %{pubsub: pubsub} do
    Phoenix.PubSub.subscribe(pubsub, Events.topic(MyApp.Other))

    Events.handle([:ramal, :branch, :create], %{}, %{branch_id: "b1", domain: MyApp.Farm}, %{
      pubsub: pubsub
    })

    refute_receive {:ramal_live, _, _}, 20
  end

  test "the message carries no data from the event's metadata", %{pubsub: pubsub} do
    Phoenix.PubSub.subscribe(pubsub, Events.topic(MyApp.Farm))
    metadata = %{branch_id: "b1", domain: MyApp.Farm, action: :update, resource: MyApp.Herd}
    Events.handle([:ramal, :write, :capture], %{}, metadata, %{pubsub: pubsub})

    assert_receive {:ramal_live, "b1", [:ramal, :write, :capture]} = message
    assert tuple_size(message) == 3
  end

  test "an event without a branch is ignored", %{pubsub: pubsub} do
    Phoenix.PubSub.subscribe(pubsub, Events.topic(MyApp.Farm))

    assert Events.handle([:ramal, :merge, :stop], %{}, %{domain: MyApp.Farm}, %{pubsub: pubsub}) ==
             :ok

    refute_receive {:ramal_live, _, _}, 20
  end

  test "a PubSub that is not running does not make the handler raise" do
    assert Events.handle(
             [:ramal, :branch, :create],
             %{},
             %{branch_id: "b1", domain: MyApp.Farm},
             %{
               pubsub: :no_such_pubsub
             }
           ) == :ok
  end

  test "it listens to every event that changes a column and to none that does not" do
    events = Events.events()

    for step <- [:create, :fork, :discard, :propose, :approve, :reject, :too_large] do
      assert [:ramal, :branch, step] in events
    end

    assert [:ramal, :merge, :stop] in events
    assert [:ramal, :write, :capture] in events
    refute [:ramal, :branch, :load] in events
    refute [:ramal, :branch, :unload] in events
    refute [:ramal, :read, :patch] in events
  end

  test "every event it listens to is one Ramal emits" do
    # Guards against a renamed event in Ramal silently turning the inspector into a static page.
    emitted =
      Ramal.Telemetry.branch_events() ++ [[:ramal, :merge, :stop], [:ramal, :write, :capture]]

    assert Events.events() -- emitted == []
  end
end
