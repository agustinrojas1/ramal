defmodule Ramal.Storage.CodecTest do
  use Ramal.DataCase, async: false

  alias Ramal.{Branch, Error}
  alias Ramal.Storage.Codec
  alias Ramal.Test.Other.Note

  doctest Ramal.Storage.Codec
  doctest Ramal.Storage

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

  test "an upsert's log entry comes back equal", %{paddocks: paddocks} do
    {:ok, branch} = Ramal.branch(Farm)

    Ramal.run!(branch, fn ->
      Ash.create!(Paddock, %{name: paddocks.l07.name, capacity_head: 120},
        action: :upsert,
        authorize?: false
      )

      Ash.create!(Paddock, %{name: "L99", capacity_head: 5}, action: :upsert, authorize?: false)
    end)

    {:ok, stored} = Ramal.get(branch.id)
    assert {:ok, restored} = round_trip(stored)
    assert restored.log == stored.log

    assert Enum.map(restored.log, &elem(&1, 5)[:upsert]) == [
             {:unique_name, [:capacity_head], false},
             {:unique_name, [:capacity_head], true}
           ]
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

  test "the root and the attributes a caller set outside the input survive a round trip" do
    forced = %{head: 99, name: "R7b", moved_on: ~D[2026-01-02]}
    opts = [key: "k", tenant: nil, nested?: false, root: 221_097_288_452_740, forced: forced]

    branch = %{
      Branch.new(Farm)
      | log: [{:update, Herd, :update, %{}, nil, opts, DateTime.utc_now()}]
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

  test "a proposal and its decision come back equal, without sensitive actor attributes" do
    account =
      struct(Ramal.Test.Other.Account,
        id: Ash.UUID.generate(),
        email: "ana@example.com",
        password_hash: "$2b$12$secret-hash"
      )

    at = DateTime.utc_now()
    stale = [%{resource: Herd, key: Ash.UUID.generate(), reason: :changed}]

    proposed = Branch.propose(Branch.new(Farm), account, "recount", at)

    assert round_trip(proposed) == {:ok, proposed} or
             match?({:ok, %{status: :proposed}}, round_trip(proposed))

    decided =
      Branch.decide(proposed, :approved, at,
        by: %{id: 3},
        reason: "ok",
        replayed: 2,
        stale: stale
      )

    {:ok, state} = Codec.encode_state(decided)
    refute Jason.encode!(state) =~ "secret"

    {:ok, loaded} = round_trip(decided)
    assert loaded.proposal.proposer.email == "ana@example.com"
    assert loaded.proposal.proposer.password_hash == nil
    assert loaded.proposal.decision == decided.proposal.decision

    rejected = Branch.decide(proposed, :rejected, at, by: %{id: 3})
    assert {:ok, %{status: :rejected} = loaded} = round_trip(rejected)
    assert loaded.proposal.decision.status == :rejected
  end

  test "a branch stored before proposals existed loads with no proposal" do
    branch = Branch.new(Farm)
    {:ok, state} = Codec.encode_state(branch)
    old = Map.delete(state, "proposal")
    assert {:ok, %{proposal: nil}} = Codec.decode_state(columns(branch), old)
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

  describe "size" do
    test "dates and times are stored as their ISO 8601 text and come back equal" do
      values = [
        ~U[2026-10-23 09:44:53.198059Z],
        ~U[2026-10-23 09:44:53Z],
        ~U[2026-10-23 09:44:53.100000Z],
        ~N[2026-10-23 09:44:53.123456],
        ~N[0000-01-01 00:00:00],
        ~D[2026-10-23],
        ~T[09:44:53.5],
        ~T[23:59:59]
      ]

      branch = %{Branch.new(Farm) | metadata: %{"values" => values}}
      {:ok, state} = Codec.encode_state(branch)

      assert state["metadata"] == %{
               "values" => [
                 %{"$dt" => "2026-10-23T09:44:53.198059Z"},
                 %{"$dt" => "2026-10-23T09:44:53Z"},
                 %{"$dt" => "2026-10-23T09:44:53.100000Z"},
                 %{"$ndt" => "2026-10-23T09:44:53.123456"},
                 %{"$ndt" => "0000-01-01T00:00:00"},
                 %{"$d" => "2026-10-23"},
                 %{"$tm" => "09:44:53.5"},
                 %{"$tm" => "23:59:59"}
               ]
             }

      assert round_trip(branch) == {:ok, branch}
    end

    test "a date or time the text cannot carry is stored as a struct and comes back equal" do
      values = [
        DateTime.from_naive!(~N[2026-10-23 09:44:53], "Etc/UTC")
        |> Map.put(:time_zone, "Europe/Madrid"),
        %{DateTime.utc_now() | utc_offset: 7200, zone_abbr: "CEST"},
        %{~D[2026-10-23] | calendar: Calendar.Holocene, year: 12_026},
        %{~U[2026-10-23 09:44:53Z] | year: 10_000}
      ]

      branch = %{Branch.new(Farm) | metadata: %{"values" => values}}
      {:ok, state} = Codec.encode_state(branch)

      assert Enum.all?(state["metadata"]["values"], &is_map_key(&1, "$s"))
      assert round_trip(branch) == {:ok, branch}
    end

    test "a stored struct lists only the fields that differ from its defaults" do
      branch = %{Branch.new(Farm) | metadata: %{"error" => Error.new(:storage, "down")}}
      {:ok, state} = Codec.encode_state(branch)

      %{"error" => %{"$s" => "Elixir.Ramal.Error", "f" => fields}} = state["metadata"]

      assert fields |> Map.keys() |> Enum.sort() == ["message", "reason"]
      assert round_trip(branch) == {:ok, branch}
    end

    test "the parts of the non-attribute fields several records have in common are written once",
         %{
           herds: herds
         } do
      [r7, r8, r9] = [herds.r7, herds.r8, herds.r9]
      loaded = Ash.load!(r9, :paddock, authorize?: false)

      branch = %{
        Branch.new(Farm)
        | overlay: %{
            {Herd, r7.id} => {:updated, r7},
            {Herd, r8.id} => {:updated, r8},
            {Herd, loaded.id} => {:updated, loaded},
            {Herd, "gone"} => :deleted
          }
      }

      {:ok, state} = Codec.encode_state(branch)

      # Three records carry the same `__meta__`; it is written in the table and the records refer to it.
      refute Jason.encode!(state["overlay"]) =~ ~s("source":"herds")
      assert Jason.encode!(state["extras"]) =~ ~s("source":"herds")
      assert Jason.encode!(state["overlay"]) =~ ~s("$x")
      assert round_trip(branch) == {:ok, branch}
    end

    test "a state with no extra in common has no table of extras" do
      {:ok, state} = Codec.encode_state(Branch.new(Farm))
      refute Map.has_key?(state, "extras")
    end

    test "a snapshot is stored as what differs from the record, and comes back whole", %{
      herds: herds
    } do
      {:ok, branch} = Ramal.branch(Farm)
      Ramal.run!(branch, fn -> Ash.update!(herds.r7, %{head: 31}, authorize?: false) end)
      {:ok, stored} = Ramal.get(branch.id)
      {:ok, state} = Codec.encode_state(stored)

      [%{"snapshot" => snapshot}] = state["base"]
      assert %{"like" => "overlay", "attrs" => attrs} = snapshot
      assert Map.keys(attrs) |> Enum.sort() == ["head", "updated_at"]

      assert byte_size(Jason.encode!(state["base"])) <
               byte_size(Jason.encode!(state["overlay"])) / 2

      assert round_trip(stored) == {:ok, stored}
    end

    test "a snapshot of a row the branch deleted has no record to compare with and is stored whole",
         %{
           herds: herds
         } do
      {:ok, branch} = Ramal.branch(Farm)
      Ramal.run!(branch, fn -> Ash.destroy!(herds.r9, authorize?: false) end)
      {:ok, stored} = Ramal.get(branch.id)
      {:ok, state} = Codec.encode_state(stored)

      [%{"snapshot" => snapshot}] = state["base"]
      refute Map.has_key?(snapshot, "like")
      assert round_trip(stored) == {:ok, stored}
    end

    test "a snapshot differs from the record in loaded relationships and unloaded attributes too",
         %{herds: herds} do
      loaded = Ash.load!(herds.r7, :paddock, authorize?: false)
      selected = hd(Ash.read!(Ash.Query.select(Herd, [:id, :name]), authorize?: false))

      branch = %{
        Branch.new(Farm)
        | overlay: %{
            {Herd, loaded.id} => {:updated, herds.r7},
            {Herd, selected.id} => {:updated, loaded}
          },
          base: %{
            {Herd, loaded.id} => %{fingerprint: 1, snapshot: loaded},
            {Herd, selected.id} => %{fingerprint: 2, snapshot: selected}
          }
      }

      assert round_trip(branch) == {:ok, branch}
    end

    test "a branch stored by 0.3.0 still loads" do
      id = Ash.UUID.generate()

      state =
        Jason.decode!("""
        {
          "version": 1, "owner": null, "proposal": null, "metadata": {},
          "inserted_at": #{old_datetime(~U[2026-10-23 09:44:53.185622Z])},
          "overlay": [], "base": [],
          "log": [{
            "type": "update", "resource": "Elixir.Ramal.Test.Farm.Herd", "action": "update",
            "params": {"$m": [[{"$a": "head"}, 2]]}, "actor": null,
            "opts": [["key", "#{id}"], ["tenant", null], ["nested?", false]],
            "at": #{old_datetime(~U[2026-10-23 09:44:53.198059Z])}
          }]
        }
        """)

      columns = %{id: id, domain: "Elixir.Ramal.Test.Farm", name: nil, status: "open"}

      assert {:ok, branch} = Codec.decode_state(columns, state)
      assert branch.inserted_at == ~U[2026-10-23 09:44:53.185622Z]

      assert [{:update, Herd, :update, %{head: 2}, nil, opts, ~U[2026-10-23 09:44:53.198059Z]}] =
               branch.log

      assert opts == [key: id, tenant: nil, nested?: false]
    end

    # A DateTime the way 0.3.0 wrote it: a struct with every field.
    defp old_datetime(%DateTime{} = value) do
      fields =
        value
        |> Map.from_struct()
        |> Map.new(fn
          {:calendar, calendar} -> {"calendar", %{"$a" => Atom.to_string(calendar)}}
          {:microsecond, {us, precision}} -> {"microsecond", %{"$t" => [us, precision]}}
          {key, field} -> {Atom.to_string(key), field}
        end)

      Jason.encode!(%{"$s" => "Elixir.DateTime", "f" => fields})
    end

    test "a date that is not text is refused when loading" do
      branch = Branch.new(Farm)
      {:ok, state} = Codec.encode_state(branch)
      state = Map.put(state, "metadata", %{"$dt" => "yesterday"})

      assert {:error, %Error{reason: :storage, message: message}} =
               Codec.decode_state(columns(branch), state)

      assert message =~ "ISO 8601"
    end

    test "a snapshot stored against a record the branch lacks is refused when loading" do
      branch = Branch.new(Farm)
      {:ok, state} = Codec.encode_state(branch)

      base = %{
        "resource" => "Elixir.Ramal.Test.Farm.Herd",
        "key" => "k",
        "fingerprint" => 1,
        "snapshot" => %{"like" => "overlay", "attrs" => %{}}
      }

      assert {:error, %Error{reason: :storage}} =
               Codec.decode_state(columns(branch), Map.put(state, "base", [base]))
    end
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
               Codec.decode_state(columns(branch), %{"version" => 3})

      assert message =~ "version 3"
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

    test "refuses a module name that is a path instead of probing the code path with it" do
      branch = Branch.new(Farm)
      {:ok, state} = Codec.encode_state(branch)
      state = Map.put(state, "metadata", %{"$s" => "Elixir.../../etc/passwd", "f" => %{}})

      assert {:error, %Error{reason: :storage, message: message}} =
               Codec.decode_state(columns(branch), state)

      assert message =~ "is not a module name"

      state = Map.put(state, "metadata", %{"$a" => "Elixir.Ramal.Test.Farm.Herd; DROP"})
      assert {:error, %Error{reason: :storage}} = Codec.decode_state(columns(branch), state)
    end

    test "refuses a stored struct whose module is not a struct" do
      branch = Branch.new(Farm)
      {:ok, state} = Codec.encode_state(branch)
      state = Map.put(state, "metadata", %{"$s" => "Elixir.System", "f" => %{}})

      assert {:error, %Error{reason: :storage, message: message}} =
               Codec.decode_state(columns(branch), state)

      assert message =~ "is not a struct"
    end

    test "state of a shape this module never writes is an error, not a crash, and does not echo the values" do
      branch = Branch.new(Farm)
      {:ok, state} = Codec.encode_state(branch)

      for hostile <- [
            Map.put(state, "metadata", %{"$b" => "not base64 !!"}),
            Map.put(state, "log", [%{"secret" => "hunter2"}]),
            Map.put(state, "overlay", "hunter2"),
            Map.delete(state, "base")
          ] do
        assert {:error, %Error{reason: :storage, message: message}} =
                 Codec.decode_state(columns(branch), hostile)

        refute message =~ "hunter2"
      end
    end
  end
end
