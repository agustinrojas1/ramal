defmodule Ramal.Storage.CodecTest do
  use Ramal.DataCase, async: false

  alias Ramal.{Branch, Error}
  alias Ramal.Storage.Codec
  alias Ramal.Test.Other.Note

  doctest Ramal.Storage.Codec

  setup do
    start_supervised!(Ramal.Supervisor)
    {:ok, Seeds.seed!()}
  end

  defp columns(branch) do
    %{
      id: branch.id,
      domain: Atom.to_string(branch.domain),
      name: branch.name,
      status: Atom.to_string(branch.status)
    }
  end

  defp round_trip(branch) do
    {:ok, state} = Codec.encode_state(branch)
    # What Postgres does to it: a trip through JSON text.
    state = state |> Jason.encode!() |> Jason.decode!()
    Codec.decode_state(columns(branch), state)
  end

  test "a branch with writes of every kind comes back equal", %{herds: herds, paddocks: paddocks} do
    {:ok, branch} = Ramal.branch(Farm, name: "mixed", metadata: %{ticket: 42, tags: ["a", :b]})

    Ramal.run!(branch, fn ->
      Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
      Ash.update!(herds.r7, %{head: 31}, authorize?: false)
      Ash.destroy!(herds.r9, authorize?: false)
      Ash.read!(Paddock, authorize?: false)

      Ash.update!(herds.r8, %{to_paddock_id: paddocks.l18.id},
        action: :move,
        actor: %{role: :admin}
      )
    end)

    {:ok, stored} = Ramal.get(branch.id)
    assert stored.overlay != %{} and stored.log != [] and stored.base != %{}
    assert round_trip(stored) == {:ok, stored}
  end

  test "terms of every shape in action input, actor and metadata survive" do
    now = DateTime.utc_now()

    input = %{
      "string" => "plain",
      :atom_key => :atom_value,
      1 => {:tuple, [1, 2.5, nil, true]},
      "dollar" => %{"$a" => "looks tagged"},
      :nested => %{date: ~D[2026-01-02], decimal: Decimal.new("1.50"), at: now},
      :binary => <<255, 0, 1>>,
      :empty => [],
      :pair => {1, {2, 3}}
    }

    branch = %{
      Branch.new(Farm)
      | metadata: input,
        log: [
          {:create, Herd, :create, input, %{id: 1, role: :admin}, [key: "k", tenant: nil], now}
        ]
    }

    assert round_trip(branch) == {:ok, branch}
  end

  test "an actor record is stored without its sensitive attributes" do
    actor =
      struct(Ramal.Test.Other.Account,
        id: Ash.UUID.generate(),
        email: "ana@example.com",
        password_hash: "$2b$12$secret-hash",
        api_token: "tok_secret"
      )

    branch = %{
      Branch.new(Farm)
      | log: [{:create, Herd, :create, %{}, actor, [key: "k", tenant: nil], DateTime.utc_now()}]
    }

    {:ok, state} = Codec.encode_state(branch)
    json = Jason.encode!(state)
    refute json =~ "secret"
    refute json =~ "tok_"

    {:ok, loaded} = round_trip(branch)
    [{_, _, _, _, stored, _, _}] = loaded.log
    assert stored.email == "ana@example.com"
    assert stored.id == actor.id
    assert stored.password_hash == nil
    assert stored.api_token == nil
  end

  test "an actor that is not a resource record is stored as it is" do
    actor = %{id: 1, role: :admin, token: "kept"}

    branch = %{
      Branch.new(Farm)
      | log: [{:create, Herd, :create, %{}, actor, [key: "k", tenant: nil], DateTime.utc_now()}]
    }

    {:ok, loaded} = round_trip(branch)
    assert [{_, _, _, _, ^actor, _, _}] = loaded.log
  end

  test "attributes round-trip through their Ash types, including nil and unloaded ones" do
    herd = Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
    [selected | _] = Ash.read!(Ash.Query.select(Herd, [:id, :name]), authorize?: false)

    branch = %{
      Branch.new(Farm)
      | overlay: %{
          {Herd, herd.id} => {:updated, herd},
          {Herd, selected.id} => {:created, selected}
        }
    }

    assert {:ok, restored} = round_trip(branch)
    assert restored.overlay == branch.overlay

    assert %Ash.NotLoaded{type: :attribute, field: :head} =
             elem(restored.overlay[{Herd, selected.id}], 1).head
  end

  test "attribute types with a stored form of their own come back as their values" do
    note =
      struct(Note,
        id: Ash.UUID.generate(),
        text: "hello",
        status: :published,
        tags: ["a", "b"],
        payload: %{"k" => [1, 2]},
        score: Decimal.new("9.50"),
        scheduled_on: ~D[2026-03-04],
        blob: <<255, 254>>,
        anything: {:any, %{thing: 1}}
      )

    branch = %{Branch.new(Farm) | overlay: %{{Note, note.id} => {:created, note}}}

    assert round_trip(branch) == {:ok, branch}
  end

  test "composite keys and base rows with fingerprints and snapshots survive", %{herds: herds} do
    row = %{fingerprint: 123_456, snapshot: herds.r7}

    branch = %{
      Branch.new(Farm)
      | base: %{
          {Herd, herds.r7.id} => row,
          {Herd, {1, "b"}} => %{fingerprint: nil, snapshot: nil}
        }
    }

    assert round_trip(branch) == {:ok, branch}
  end

  test "pids, references and functions are refused with the path of the value" do
    for bad <- [self(), make_ref(), fn -> :ok end] do
      branch = %{
        Branch.new(Farm)
        | log: [{:create, Herd, :create, %{nested: [bad]}, nil, [key: "k"], DateTime.utc_now()}]
      }

      assert {:error, %Error{reason: :storage, details: %{path: path}} = error} =
               Codec.encode_state(branch)

      assert path == ["log", "Ramal.Test.Farm.Herd", "create", "params", "nested"]
      assert error.message =~ branch.id
    end
  end

  describe "loading" do
    test "refuses a state from a newer version" do
      branch = Branch.new(Farm)

      assert {:error, %Error{reason: :storage, message: message}} =
               Codec.decode_state(columns(branch), %{"version" => 2})

      assert message =~ "version 2"
    end

    test "refuses a module that is not on the code path" do
      branch = Branch.new(Farm)
      {:ok, state} = Codec.encode_state(branch)

      state =
        Map.put(state, "overlay", [
          %{"resource" => "Elixir.Nope.Nothing", "key" => 1, "op" => "deleted", "record" => nil}
        ])

      assert {:error, %Error{reason: :storage, message: message}} =
               Codec.decode_state(columns(branch), state)

      assert message =~ "Nope.Nothing"
    end

    test "refuses an atom that does not exist instead of creating it" do
      branch = Branch.new(Farm)
      {:ok, state} = Codec.encode_state(%{branch | metadata: %{}})

      state =
        Map.put(state, "metadata", %{"$m" => [[%{"$a" => "ramal_never_seen_this_atom_xyz"}, 1]]})

      assert {:error, %Error{reason: :storage}} = Codec.decode_state(columns(branch), state)

      assert_raise ArgumentError, fn ->
        String.to_existing_atom("ramal_never_seen_this_atom_xyz")
      end
    end

    test "refuses a record whose attribute the resource no longer has" do
      herd = Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
      branch = %{Branch.new(Farm) | overlay: %{{Herd, herd.id} => {:created, herd}}}
      {:ok, state} = Codec.encode_state(branch)
      state = put_in(state, ["overlay", Access.at(0), "record", "attrs", "colour"], "red")

      assert {:error, %Error{reason: :storage, message: message}} =
               Codec.decode_state(columns(branch), state)

      assert message =~ "colour"
    end
  end
end
