defmodule Ramal.ManyToManyTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  #
  # DESIGN open question 3: a many_to_many join resource is a resource like any other, so it gets overlay entries. The
  # join resource here (`HerdVet`) has a composite primary key, the pair of foreign keys, so its overlay keys are
  # tuples.
  use Ramal.DataCase, async: false

  alias Ramal.Error
  alias Ramal.Merge.Result
  alias Ramal.Storage.Postgres
  alias Ramal.Test.Farm.{HerdVet, Vet}

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    ana = Ash.create!(Vet, %{name: "Ana"}, authorize?: false)
    bruno = Ash.create!(Vet, %{name: "Bruno"}, authorize?: false)
    # The base has one link: R7 is looked after by Ana.
    Ash.create!(HerdVet, %{herd_id: seeds.herds.r7.id, vet_id: ana.id}, authorize?: false)
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch, ana: ana, bruno: bruno})}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)

  defp vets_of(herd) do
    herd
    |> Ash.load!(:vets, authorize?: false)
    |> Map.fetch!(:vets)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  # The links a read of the join resource returns, as {herd_id, vet_id}.
  defp links do
    HerdVet |> Ash.read!(authorize?: false) |> Enum.map(&{&1.herd_id, &1.vet_id}) |> Enum.sort()
  end

  defp get_link!(herd, vet) do
    Ash.get!(HerdVet, %{herd_id: herd.id, vet_id: vet.id}, authorize?: false)
  end

  defp add_vets(herd, vets, extra \\ %{}) do
    input = Map.put(extra, :vet_ids, Enum.map(vets, & &1.id))
    Ash.update!(herd, input, action: :add_vets, authorize?: false)
  end

  defp drop_vets(herd, vets) do
    Ash.update!(herd, %{vet_ids: Enum.map(vets, & &1.id)}, action: :drop_vets, authorize?: false)
  end

  defp summary(changes), do: changes |> Enum.map(&{&1.resource, &1.key, &1.kind}) |> Enum.sort()

  describe "the join resource" do
    test "a read sees links created and destroyed in the branch", %{
      branch: branch,
      herds: herds,
      ana: ana,
      bruno: bruno
    } do
      inside(branch, fn ->
        Ash.create!(HerdVet, %{herd_id: herds.r8.id, vet_id: bruno.id}, authorize?: false)
        Ash.destroy!(get_link!(herds.r7, ana), authorize?: false)

        assert links() == [{herds.r8.id, bruno.id}]
      end)

      assert links() == [{herds.r7.id, ana.id}]
    end

    test "a link is keyed by the pair of foreign keys", %{
      branch: branch,
      herds: herds,
      bruno: bruno
    } do
      inside(branch, fn ->
        Ash.create!(HerdVet, %{herd_id: herds.r8.id, vet_id: bruno.id}, authorize?: false)
      end)

      assert {:ok, changes} = Ramal.diff(branch)
      assert summary(changes) == [{HerdVet, {herds.r8.id, bruno.id}, :created}]
    end

    test "loading the join relationship sees the branch's links", %{
      branch: branch,
      herds: herds,
      ana: ana,
      bruno: bruno
    } do
      inside(branch, fn ->
        add_vets(herds.r7, [bruno])
        herd = Ash.load!(herds.r7, :vets_join_assoc, authorize?: false)

        assert herd.vets_join_assoc |> Enum.map(& &1.vet_id) |> Enum.sort() ==
                 Enum.sort([ana.id, bruno.id])
      end)
    end
  end

  describe "loading the many_to_many relationship" do
    test "sees changes to the destination rows made in the branch", %{
      branch: branch,
      herds: herds,
      ana: ana
    } do
      inside(branch, fn ->
        Ash.update!(ana, %{name: "Ana M."}, authorize?: false)
        assert vets_of(herds.r7) == ["Ana M."]

        Ash.destroy!(ana, authorize?: false)
        assert vets_of(herds.r7) == []
      end)

      assert vets_of(herds.r7) == ["Ana"]
    end

    # Known limit, DESIGN section 4.1 point 7. AshPostgres loads a many_to_many with one SQL query that joins the join
    # table in the database (`lateral_join?/4` in deps/ash/lib/ash/actions/read/relationships.ex), so the links of the
    # branch are not in it. The join relationship and the join resource itself are patched, which is how to read them
    # in a branch.
    test "does not see links created or destroyed in the branch", %{
      branch: branch,
      herds: herds,
      ana: ana,
      bruno: bruno
    } do
      inside(branch, fn ->
        add_vets(herds.r8, [bruno])
        drop_vets(herds.r7, [ana])

        assert links() == [{herds.r8.id, bruno.id}]
        assert vets_of(herds.r8) == []
        assert vets_of(herds.r7) == ["Ana"]
      end)
    end
  end

  describe "writes through manage_relationship" do
    test "append creates the links in the branch and leaves the database alone", %{
      branch: branch,
      herds: herds,
      ana: ana,
      bruno: bruno
    } do
      inside(branch, fn -> add_vets(herds.r8, [ana, bruno]) end)

      assert links() == [{herds.r7.id, ana.id}]
      assert {:ok, changes} = Ramal.diff(branch)

      assert summary(changes) ==
               Enum.sort([
                 {HerdVet, {herds.r8.id, ana.id}, :created},
                 {HerdVet, {herds.r8.id, bruno.id}, :created}
               ])
    end

    test "remove destroys the links one by one", %{branch: branch, herds: herds, ana: ana} do
      inside(branch, fn -> drop_vets(herds.r7, [ana]) end)

      assert links() == [{herds.r7.id, ana.id}]
      assert {:ok, changes} = Ramal.diff(branch)
      assert summary(changes) == [{HerdVet, {herds.r7.id, ana.id}, :deleted}]
    end

    test "append_and_remove works when it has no link to remove", %{
      branch: branch,
      herds: herds,
      ana: ana,
      bruno: bruno
    } do
      inside(branch, fn ->
        Ash.update!(herds.r7, %{vet_ids: [ana.id, bruno.id]},
          action: :set_vets,
          authorize?: false
        )
      end)

      assert {:ok, changes} = Ramal.diff(branch)
      assert summary(changes) == [{HerdVet, {herds.r7.id, bruno.id}, :created}]
    end

    # Known limit, DESIGN section 4.1 point 7. `append_and_remove` unrelates the missing destinations with
    # `Ash.bulk_destroy/4` on the join resource (`bulk_delete_unused_unrelate/8` in
    # deps/ash/lib/ash/actions/managed_relationships.ex), and a branch refuses bulk actions (ADR 0001).
    test "append_and_remove is refused when it has a link to remove, and writes nothing", %{
      branch: branch,
      herds: herds,
      bruno: bruno
    } do
      assert {:ok, {:error, error}} =
               Ramal.run(branch, fn ->
                 Ash.update(herds.r7, %{vet_ids: [bruno.id]},
                   action: :set_vets,
                   authorize?: false
                 )
               end)

      assert %Error{reason: :bulk_unsupported, details: %{resource: HerdVet}} = Error.find(error)
      assert {:ok, []} = Ramal.diff(branch)
    end
  end

  # Known limit, DESIGN section 4.1 point 7. `manage_relationship` decides what to create and remove from the
  # many_to_many load, which does not see the links of the branch, so it cannot remove a link the branch created.
  describe "manage_relationship after the branch changed the links" do
    test "cannot remove a link the branch created", %{branch: branch, herds: herds, bruno: bruno} do
      assert {:ok, {:error, error}} =
               Ramal.run(branch, fn ->
                 add_vets(herds.r8, [bruno])

                 Ash.update(herds.r8, %{vet_ids: [bruno.id]},
                   action: :drop_vets,
                   authorize?: false
                 )
               end)

      assert Exception.message(error) =~ "not found"
    end
  end

  describe "merge" do
    test "replays an update that changes the herd and links vets", %{
      branch: branch,
      herds: herds,
      ana: ana,
      bruno: bruno
    } do
      inside(branch, fn -> add_vets(herds.r8, [ana, bruno], %{head: 36}) end)

      # Replaying the update creates the links again, so the links the first run wrote (nested) are not replayed on
      # their own.
      assert {:ok, %Result{replayed: 1, stale: []}} = Ramal.merge(branch, authorize?: false)

      assert Ash.get!(Herd, herds.r8.id, authorize?: false).head == 36
      assert vets_of(herds.r8) == ["Ana", "Bruno"]
      assert length(links()) == 3
    end

    test "replays links created by an update that changes nothing on the herd", %{
      branch: branch,
      herds: herds,
      bruno: bruno
    } do
      inside(branch, fn -> add_vets(herds.r8, [bruno]) end)

      # Ash does not write an update that changes no attribute, so the log holds the link on its own.
      assert {:ok, %Result{replayed: 1, stale: []}} = Ramal.merge(branch, authorize?: false)
      assert vets_of(herds.r8) == ["Bruno"]
    end

    test "replays a vet created in the branch, its link, and a destroyed link, in order", %{
      branch: branch,
      herds: herds,
      ana: ana
    } do
      inside(branch, fn ->
        cora = Ash.create!(Vet, %{name: "Cora"}, authorize?: false)
        add_vets(herds.r9, [cora])
        drop_vets(herds.r7, [ana])
      end)

      assert {:ok, %Result{stale: []}} = Ramal.merge(branch, authorize?: false)

      assert vets_of(herds.r9) == ["Cora"]
      assert vets_of(herds.r7) == []
    end

    test "a link that the base destroyed meanwhile makes the merge stale", %{
      branch: branch,
      herds: herds,
      ana: ana
    } do
      inside(branch, fn -> drop_vets(herds.r7, [ana]) end)
      Ash.destroy!(get_link!(herds.r7, ana), authorize?: false)

      assert {:error, %Error{reason: :stale, details: %{rows: [row]}}} =
               Ramal.merge(branch, authorize?: false)

      assert row == %{resource: HerdVet, key: {herds.r7.id, ana.id}, reason: :deleted}
    end

    test "a link that the base changed meanwhile makes the merge stale", %{
      branch: branch,
      herds: herds,
      ana: ana
    } do
      inside(branch, fn -> drop_vets(herds.r7, [ana]) end)
      Ash.update!(get_link!(herds.r7, ana), %{assigned_on: ~D[2026-01-01]}, authorize?: false)

      assert {:error, %Error{reason: :stale, details: %{rows: [row]}}} =
               Ramal.merge(branch, authorize?: false)

      assert row == %{resource: HerdVet, key: {herds.r7.id, ana.id}, reason: :changed}
    end
  end

  describe "forks and storage" do
    test "a fork inherits the links of its parent and keeps its own apart", %{
      branch: branch,
      herds: herds,
      bruno: bruno
    } do
      inside(branch, fn -> add_vets(herds.r8, [bruno]) end)
      {:ok, child} = Ramal.fork(branch)
      link = {herds.r8.id, bruno.id}

      inside(child, fn ->
        assert link in links()
        Ash.destroy!(get_link!(herds.r8, bruno), authorize?: false)
        refute link in links()
      end)

      assert link in inside(branch, &links/0)
    end

    test "tuple keys survive the Postgres storage", %{branch: branch, herds: herds, bruno: bruno} do
      inside(branch, fn -> add_vets(herds.r8, [bruno]) end)
      {:ok, stored} = Ramal.get(branch.id)
      assert Map.has_key?(stored.overlay, {HerdVet, {herds.r8.id, bruno.id}})

      assert Postgres.put(stored, repo: TestRepo) == :ok
      assert Postgres.fetch(branch.id, repo: TestRepo) == {:ok, stored}
    end
  end
end
