defmodule Ramal.BranchTest do
  use ExUnit.Case, async: true

  alias Ramal.Branch

  doctest Ramal.Branch

  test "a new branch is open, empty and has a fresh UUID" do
    first = Branch.new(MyApp.Farm)
    second = Branch.new(MyApp.Farm)

    assert {:ok, _} = Ecto.UUID.cast(first.id)
    assert first.id != second.id
    assert %{status: :open, overlay: %{}, log: [], base: %{}, metadata: %{}, name: nil} = first
    assert %DateTime{} = first.inserted_at
  end

  test "inspecting a branch shows its identity and nothing it holds" do
    entry =
      {:create, MyApp.Herd, :create, %{password: "hunter2"}, %{token: "s3cret"}, [key: 1],
       DateTime.utc_now()}

    branch = %{
      Branch.new(MyApp.Farm, name: "audit", metadata: %{api_key: "k-123"})
      | log: [entry],
        overlay: %{{MyApp.Herd, 1} => {:created, %{password: "hunter2"}}}
    }

    printed = inspect(branch)

    assert printed =~ branch.id
    assert printed =~ "audit"
    for secret <- ["hunter2", "s3cret", "k-123"], do: refute(printed =~ secret)
    # A crash report prints the state of the branch process, which wraps the struct.
    for secret <- ["hunter2", "s3cret", "k-123"], do: refute(inspect(%{branch: branch}) =~ secret)
  end

  test "name and metadata are kept as given" do
    branch = Branch.new(MyApp.Farm, name: "what if", metadata: %{ticket: 7})

    assert branch.name == "what if"
    assert branch.metadata == %{ticket: 7}
  end

  test "only an open branch is open" do
    branch = Branch.new(MyApp.Farm)

    assert Branch.open?(branch)
    refute Branch.open?(%{branch | status: :merged})
    refute Branch.open?(%{branch | status: :discarded})
  end

  test "discarding empties the overlay, log and base but keeps identity" do
    branch = %{
      Branch.new(MyApp.Farm, name: "x")
      | overlay: %{{A, 1} => :deleted},
        log: [:entry],
        base: %{{A, 1} => %{}}
    }

    discarded = Branch.discard(branch)

    assert %{status: :discarded, overlay: %{}, log: [], base: %{}} = discarded

    assert {discarded.id, discarded.name, discarded.inserted_at} ==
             {branch.id, branch.name, branch.inserted_at}
  end

  describe "sharing" do
    # Terms built at run time and copied the way a message copies them, so no two of them are the same term.
    defp copy(term), do: :erlang.binary_to_term(:erlang.term_to_binary(term))
    defp owner, do: String.duplicate("o", 40)
    defp same?(a, b), do: :erts_debug.same(a, b)

    defp snapshot(n),
      do: %{id: 1, owner: owner(), n: n, tags: Enum.map(1..5, &Integer.to_string/1)}

    defp log_entry(key, actor, n \\ 1),
      do: {:update, A, :update, %{n: n}, actor, [key: key, tenant: nil], DateTime.utc_now()}

    test "an update's record points at the fields of the snapshot it did not change" do
      snapshot = snapshot(1)
      row = %{fingerprint: 1, snapshot: copy(snapshot)}

      {branch, _} =
        Branch.put_write(
          Branch.new(MyApp.Farm),
          :updated,
          {A, 1},
          copy(%{snapshot | n: 2}),
          row,
          log_entry(1, nil)
        )

      {:updated, record} = branch.overlay[{A, 1}]
      kept = branch.base[{A, 1}].snapshot

      assert record == %{snapshot | n: 2}
      assert kept == snapshot
      assert same?(record.owner, kept.owner)
      assert same?(record.tags, kept.tags)
    end

    test "a write points at the fields the write before it of the same resource holds" do
      branch = Branch.new(MyApp.Farm)
      first = %{id: 1, owner: owner(), n: 1, tags: []}
      second = %{id: 2, owner: owner(), n: 2, tags: []}

      {branch, _} =
        Branch.put_write(branch, :created, {A, 1}, copy(first), nil, log_entry(1, nil))

      {branch, _} =
        Branch.put_write(branch, :created, {A, 2}, copy(second), nil, log_entry(2, nil))

      assert {:created, ^second} = branch.overlay[{A, 2}]
      assert same?(elem(branch.overlay[{A, 1}], 1).owner, elem(branch.overlay[{A, 2}], 1).owner)
    end

    test "a log entry holds the key of its ref and the actor of the entry before it" do
      key = String.duplicate("k", 40)
      actor = %{id: owner(), role: :admin}
      branch = Branch.new(MyApp.Farm)

      {branch, _} =
        Branch.put_write(
          branch,
          :created,
          {A, key},
          %{id: copy(key)},
          nil,
          log_entry(copy(key), copy(actor))
        )

      {branch, _} =
        Branch.put_write(branch, :created, {A, "b"}, %{id: "b"}, nil, log_entry("b", copy(actor)))

      [{_, _, _, _, newer_actor, _, _}, {_, _, _, _, older_actor, older_opts, _}] = branch.log

      assert newer_actor == actor
      assert same?(newer_actor, older_actor)
      assert same?(older_opts[:key], key)
    end

    test "share/1 gives back an equal branch whose rows point at their snapshots again" do
      snapshot = snapshot(1)
      branch = Branch.new(MyApp.Farm)

      {branch, _} =
        Branch.put_write(
          branch,
          :updated,
          {A, 1},
          %{snapshot | n: 2},
          %{fingerprint: 1, snapshot: snapshot},
          log_entry(1, %{role: :admin})
        )

      stored = copy(branch)
      {:updated, record} = stored.overlay[{A, 1}]
      refute same?(record.owner, stored.base[{A, 1}].snapshot.owner)

      shared = Branch.share(stored)
      {:updated, record} = shared.overlay[{A, 1}]

      assert shared == stored
      assert same?(record.owner, shared.base[{A, 1}].snapshot.owner)
    end
  end

  describe "put_write/6 and undo/2" do
    defp entry(n), do: {:update, A, :update, %{n: n}, nil, [key: 1], ~U[2026-01-01 00:00:00Z]}
    defp row(n, fingerprint \\ nil), do: %{fingerprint: fingerprint, snapshot: %{n: n}}

    test "the first write to an existing row keeps its snapshot and later writes keep that one" do
      branch = Branch.new(MyApp.Farm)
      {branch, _} = Branch.put_write(branch, :updated, {A, 1}, %{n: 2}, row(1), entry(2))
      {branch, _} = Branch.put_write(branch, :updated, {A, 1}, %{n: 3}, row(2), entry(3))

      assert branch.base == %{{A, 1} => row(1)}
      assert branch.overlay == %{{A, 1} => {:updated, %{n: 3}}}
      assert branch.log == [entry(3), entry(2)]
    end

    test "a fingerprint taken by an earlier read survives the first write" do
      branch = Branch.put_fingerprints(Branch.new(MyApp.Farm), %{{A, 1} => 7})
      {branch, _} = Branch.put_write(branch, :updated, {A, 1}, %{n: 2}, row(1, 9), entry(2))

      assert branch.base == %{{A, 1} => row(1, 7)}
    end

    test "a created row needs no snapshot" do
      {branch, _} =
        Branch.put_write(Branch.new(MyApp.Farm), :created, {A, 1}, %{n: 1}, nil, entry(1))

      assert branch.base == %{}
      assert branch.overlay == %{{A, 1} => {:created, %{n: 1}}}
    end

    test "deleting a created row removes its overlay entry but the log keeps both writes" do
      branch = Branch.new(MyApp.Farm)
      {branch, _} = Branch.put_write(branch, :created, {A, 1}, %{n: 1}, nil, entry(1))
      {branch, _} = Branch.put_write(branch, :deleted, {A, 1}, %{n: 1}, row(1), entry(2))

      assert branch.overlay == %{}
      assert branch.base == %{}
      assert length(branch.log) == 2
    end

    test "undo takes back the newest writes and leaves the others" do
      branch = Branch.put_fingerprints(Branch.new(MyApp.Farm), %{{A, 1} => 7})
      {kept, _} = Branch.put_write(branch, :updated, {A, 1}, %{n: 2}, row(1), entry(2))
      {b2, undo2} = Branch.put_write(kept, :updated, {A, 1}, %{n: 3}, row(2), entry(3))
      {b3, undo3} = Branch.put_write(b2, :deleted, {A, 2}, %{n: 9}, row(9), entry(4))

      assert Branch.undo(b3, [undo3, undo2]) == kept
    end

    test "undo of a first write puts back the fingerprint a read had taken" do
      branch = Branch.put_fingerprints(Branch.new(MyApp.Farm), %{{A, 1} => 7})
      {written, undo} = Branch.put_write(branch, :updated, {A, 1}, %{n: 2}, row(1), entry(2))

      assert Branch.undo(written, [undo]) == branch
    end

    test "undo leaves a write another process made in between" do
      branch = Branch.new(MyApp.Farm)
      {written, undo} = Branch.put_write(branch, :updated, {A, 1}, %{n: 2}, row(1), entry(2))
      {other, _} = Branch.put_write(written, :updated, {A, 2}, %{n: 5}, row(4), entry(5))

      undone = Branch.undo(other, [undo])
      assert undone.overlay == %{{A, 2} => {:updated, %{n: 5}}}
      assert undone.log == [entry(5)]
    end
  end

  describe "put_fingerprints/2" do
    test "keeps the first fingerprint of a row" do
      branch = Branch.put_fingerprints(Branch.new(MyApp.Farm), %{{A, 1} => 1, {A, 2} => 2})
      branch = Branch.put_fingerprints(branch, %{{A, 1} => 9, {A, 3} => 3})

      assert Map.new(branch.base, fn {ref, row} -> {ref, row.fingerprint} end) ==
               %{{A, 1} => 1, {A, 2} => 2, {A, 3} => 3}
    end
  end

  describe "fork/2" do
    test "copies overlay, log and base and gets a new identity" do
      parent = Branch.new(MyApp.Farm, name: "p", metadata: %{ticket: 1})
      {parent, _} = Branch.put_write(parent, :updated, {A, 1}, %{n: 2}, row(1, 5), entry(2))
      fork = Branch.fork(parent)

      assert fork.id != parent.id
      assert {fork.overlay, fork.log, fork.base} == {parent.overlay, parent.log, parent.base}
      assert fork.name == "p"
      assert fork.metadata == %{ticket: 1, forked_from: parent.id}
      assert fork.status == :open
    end

    test "name and metadata can be given" do
      fork = Branch.fork(Branch.new(MyApp.Farm, name: "p"), name: "q", metadata: %{a: 1})

      assert fork.name == "q"
      assert Map.delete(fork.metadata, :forked_from) == %{a: 1}
    end
  end

  describe "diff/2" do
    test "lists changes in the order the log first touched each row" do
      branch = Branch.new(MyApp.Farm)

      {branch, _} =
        Branch.put_write(branch, :updated, {A, 2}, %{n: 2}, row(1), entry(2) |> with_key(2))

      {branch, _} =
        Branch.put_write(branch, :updated, {A, 1}, %{n: 5}, row(1), entry(5) |> with_key(1))

      {branch, _} =
        Branch.put_write(branch, :updated, {A, 2}, %{n: 3}, row(2), entry(3) |> with_key(2))

      assert {:ok, changes} = Branch.diff(branch)
      assert Enum.map(changes, & &1.key) == [2, 1]
    end

    test "a row changed and changed back is left out" do
      branch = Branch.new(MyApp.Farm)
      {branch, _} = Branch.put_write(branch, :updated, {A, 1}, %{n: 2}, row(1), entry(2))
      {branch, _} = Branch.put_write(branch, :updated, {A, 1}, %{n: 1}, row(2), entry(3))

      assert {:ok, []} = Branch.diff(branch)
    end

    test "an updated row without a snapshot is a missing_snapshot error" do
      branch = %{Branch.new(MyApp.Farm) | overlay: %{{A, 1} => {:updated, %{n: 2}}}}

      assert {:error, %Ramal.Error{reason: :missing_snapshot}} = Branch.diff(branch)
    end

    defp with_key({type, resource, action, input, actor, opts, at}, key) do
      {type, resource, action, input, actor, Keyword.put(opts, :key, key), at}
    end
  end
end
