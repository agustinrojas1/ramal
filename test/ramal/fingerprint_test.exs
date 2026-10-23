defmodule Ramal.FingerprintTest do
  use ExUnit.Case, async: true

  alias Ramal.Resource
  alias Ramal.Test.Farm.{Herd, HerdVet}

  defp herd(attrs),
    do: struct(Herd, Map.merge(%{id: Ash.UUID.generate(), name: "R7", head: 30}, Map.new(attrs)))

  defp loaded(attrs \\ []) do
    herd(
      Map.merge(
        %{
          paddock_id: nil,
          inserted_at: ~U[2026-01-01 00:00:00Z],
          updated_at: ~U[2026-01-01 00:00:00Z]
        },
        Map.new(attrs)
      )
    )
  end

  test "a fingerprint is the hash of the attribute map, so one stored by an earlier version still compares equal" do
    record = loaded()

    assert Resource.fingerprint(record) == :erlang.phash2(Resource.attributes(record))
  end

  test "a record with an attribute that is not loaded has no fingerprint" do
    assert Resource.fingerprint(loaded(head: %Ash.NotLoaded{type: :attribute, field: :head})) ==
             nil

    assert Resource.fingerprint(loaded(head: %Ash.ForbiddenField{field: :head, type: :attribute})) ==
             nil
  end

  test "a record with a different value has a different fingerprint" do
    a = loaded()
    refute Resource.fingerprint(a) == Resource.fingerprint(%{a | head: 31})
  end

  test "fingerprints/2 pairs each row's ref with the fingerprint fingerprint/1 gives, and skips partial rows" do
    a = loaded()
    b = loaded(name: "R8")
    partial = loaded(name: %Ash.NotLoaded{type: :attribute, field: :name})

    assert Resource.fingerprints(Herd, [a, partial, b]) == [
             {{Herd, a.id}, Resource.fingerprint(a)},
             {{Herd, b.id}, Resource.fingerprint(b)}
           ]

    assert Resource.fingerprints(Herd, []) == []
  end

  test "fingerprints/2 keys a row with a composite primary key by a tuple" do
    link =
      struct(HerdVet,
        herd_id: "h",
        vet_id: "v",
        assigned_on: nil,
        inserted_at: nil,
        updated_at: nil
      )

    assert [{{HerdVet, {"h", "v"}}, fingerprint}] = Resource.fingerprints(HerdVet, [link])
    assert fingerprint == Resource.fingerprint(link)
  end
end
