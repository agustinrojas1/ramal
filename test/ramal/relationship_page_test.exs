defmodule Ramal.RelationshipPageTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  #
  # A relationship loaded with a page (or a limit or offset) is read by AshPostgres as one lateral join that pages per
  # source record. A branch cannot leave that to the database once it has changed the destination or a join resource
  # (ADR 0038).
  use Ramal.DataCase, async: false

  require Ash.Query

  alias Ramal.Test.Farm.{HerdVet, Vet}

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    ana = Ash.create!(Vet, %{name: "Ana"}, authorize?: false)
    bruno = Ash.create!(Vet, %{name: "Bruno"}, authorize?: false)
    carla = Ash.create!(Vet, %{name: "Carla"}, authorize?: false)
    # R7 is looked after by Ana and Bruno, R8 by Carla.
    for {herd, vet} <- [{seeds.herds.r7, ana}, {seeds.herds.r7, bruno}, {seeds.herds.r8, carla}] do
      Ash.create!(HerdVet, %{herd_id: herd.id, vet_id: vet.id}, authorize?: false)
    end

    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch, vets: %{ana: ana, bruno: bruno, carla: carla}})}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)

  # Every paddock's page of herds, as %{paddock name => {herd names, count, more?}}.
  defp herd_pages(page, action \\ :list) do
    herds = Herd |> Ash.Query.for_read(action) |> Ash.Query.sort(:name) |> Ash.Query.page(page)

    Paddock
    |> Ash.Query.load(herds: herds)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.name, summary(&1.herds)})
  end

  defp vet_pages(page) do
    vets = Vet |> Ash.Query.for_read(:list) |> Ash.Query.sort(:name) |> Ash.Query.page(page)

    Herd
    |> Ash.Query.load(vets: vets)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.name, summary(&1.vets)})
  end

  defp summary(%{results: results, count: count, more?: more?}),
    do: {Enum.map(results, & &1.name), count, more?}

  describe "a has_many loaded a page at a time" do
    test "outside a branch the database pages it" do
      assert herd_pages(limit: 1, count: true) == %{
               "L07" => {["R7"], 2, true},
               "L18" => {["R9"], 1, false}
             }
    end

    test "a herd created in the branch takes its place in its paddock's page", %{
      branch: branch,
      paddocks: p
    } do
      inside(branch, fn ->
        Ash.create!(Herd, %{name: "A0", head: 1, paddock_id: p.l07.id}, authorize?: false)

        assert herd_pages(limit: 1, count: true) == %{
                 "L07" => {["A0"], 3, true},
                 "L18" => {["R9"], 1, false}
               }

        assert herd_pages(limit: 2, offset: 1, count: true) == %{
                 "L07" => {["R7", "R8"], 3, false},
                 "L18" => {[], 1, false}
               }
      end)
    end

    test "a herd destroyed in the branch shortens its paddock's page", %{
      branch: branch,
      herds: h
    } do
      inside(branch, fn ->
        Ash.destroy!(h.r7, authorize?: false)

        assert herd_pages(limit: 1, count: true) == %{
                 "L07" => {["R8"], 1, false},
                 "L18" => {["R9"], 1, false}
               }
      end)
    end

    test "a herd moved to another paddock leaves one page and joins the other", %{
      branch: branch,
      herds: h,
      paddocks: p
    } do
      inside(branch, fn ->
        Ash.update!(h.r7, %{paddock_id: p.l18.id}, authorize?: false)

        assert herd_pages(limit: 5, count: true) == %{
                 "L07" => {["R8"], 1, false},
                 "L18" => {["R7", "R9"], 2, false}
               }
      end)
    end

    test "a herd renamed in the branch sorts where its new name puts it", %{
      branch: branch,
      herds: h
    } do
      inside(branch, fn ->
        Ash.update!(h.r8, %{name: "A8"}, authorize?: false)

        assert herd_pages(limit: 1, count: true)["L07"] == {["A8"], 2, true}
      end)
    end

    test "a keyset page starts after the cursor of the patched page", %{
      branch: branch,
      paddocks: p
    } do
      inside(branch, fn ->
        Ash.create!(Herd, %{name: "A0", head: 1, paddock_id: p.l07.id}, authorize?: false)

        herds =
          Herd
          |> Ash.Query.for_read(:keyset_list)
          |> Ash.Query.sort(:name)
          |> Ash.Query.page(limit: 1)

        [l07] =
          Paddock
          |> Ash.Query.filter(name == "L07")
          |> Ash.Query.load(herds: herds)
          |> Ash.read!(authorize?: false)

        assert {["A0"], _count, true} = summary(l07.herds)
        [first] = l07.herds.results

        after_first =
          Ash.Query.page(herds, limit: 1, after: first.__metadata__.keyset, count: true)

        [l07] =
          Paddock
          |> Ash.Query.filter(name == "L07")
          |> Ash.Query.load(herds: after_first)
          |> Ash.read!(authorize?: false)

        assert {["R7"], 3, true} = summary(l07.herds)
      end)
    end

    test "the next page of one paddock's herds is the next of the patched list", %{
      branch: branch,
      paddocks: p
    } do
      inside(branch, fn ->
        Ash.create!(Herd, %{name: "A0", head: 1, paddock_id: p.l07.id}, authorize?: false)

        herds =
          Herd
          |> Ash.Query.for_read(:list)
          |> Ash.Query.sort(:name)
          |> Ash.Query.page(limit: 1, count: true)

        [l07] =
          Paddock
          |> Ash.Query.filter(name == "L07")
          |> Ash.Query.load(herds: herds)
          |> Ash.read!(authorize?: false)

        second = Ash.page!(l07.herds, :next)
        assert summary(second) == {["R7"], 3, true}
        assert summary(Ash.page!(second, :next)) == {["R8"], 3, false}
      end)
    end

    test "a paddock created in the branch pages the herds created for it", %{branch: branch} do
      inside(branch, fn ->
        north = Ash.create!(Paddock, %{name: "North", capacity_head: 50}, authorize?: false)

        for name <- ["N2", "N1", "N3"] do
          Ash.create!(Herd, %{name: name, head: 1, paddock_id: north.id}, authorize?: false)
        end

        assert herd_pages(limit: 2, count: true)["North"] == {["N1", "N2"], 3, true}
      end)
    end

    test "a limit without a page is applied to each paddock", %{branch: branch, paddocks: p} do
      inside(branch, fn ->
        Ash.create!(Herd, %{name: "A0", head: 1, paddock_id: p.l18.id}, authorize?: false)
        herds = Herd |> Ash.Query.sort(:name) |> Ash.Query.limit(1)

        loaded =
          Paddock
          |> Ash.Query.sort(:name)
          |> Ash.Query.load(herds: herds)
          |> Ash.read!(authorize?: false)

        assert Enum.map(loaded, &{&1.name, Enum.map(&1.herds, fn herd -> herd.name end)}) ==
                 [{"L07", ["R7"]}, {"L18", ["A0"]}]
      end)
    end

    test "a branch that did not touch the herds leaves the database's page", %{
      branch: branch
    } do
      inside(branch, fn ->
        Ash.create!(Paddock, %{name: "L99", capacity_head: 10}, authorize?: false)

        assert herd_pages(limit: 1, count: true) == %{
                 "L07" => {["R7"], 2, true},
                 "L18" => {["R9"], 1, false},
                 "L99" => {[], 0, false}
               }
      end)
    end
  end

  describe "a many_to_many loaded a page at a time" do
    test "outside a branch the database pages it" do
      assert vet_pages(limit: 1, count: true) == %{
               "R7" => {["Ana"], 2, true},
               "R8" => {["Carla"], 1, false},
               "R9" => {[], 0, false}
             }
    end

    test "a link created in the branch joins its herd's page", %{
      branch: branch,
      herds: h,
      vets: v
    } do
      inside(branch, fn ->
        Ash.create!(HerdVet, %{herd_id: h.r9.id, vet_id: v.bruno.id}, authorize?: false)
        Ash.create!(HerdVet, %{herd_id: h.r8.id, vet_id: v.ana.id}, authorize?: false)

        assert vet_pages(limit: 1, count: true) == %{
                 "R7" => {["Ana"], 2, true},
                 "R8" => {["Ana"], 2, true},
                 "R9" => {["Bruno"], 1, false}
               }
      end)
    end

    test "a link destroyed in the branch shortens its herd's page", %{
      branch: branch,
      herds: h,
      vets: v
    } do
      inside(branch, fn ->
        link = Ash.get!(HerdVet, %{herd_id: h.r7.id, vet_id: v.ana.id}, authorize?: false)
        Ash.destroy!(link, authorize?: false)

        assert vet_pages(limit: 1, count: true)["R7"] == {["Bruno"], 1, false}
      end)
    end

    test "a vet renamed in the branch sorts where its new name puts it", %{
      branch: branch,
      vets: v
    } do
      inside(branch, fn ->
        Ash.update!(v.bruno, %{name: "Aaron"}, authorize?: false)

        assert vet_pages(limit: 1, count: true)["R7"] == {["Aaron"], 2, true}
      end)
    end

    test "a vet created and linked in the branch is on the page", %{branch: branch, herds: h} do
      inside(branch, fn ->
        zoe = Ash.create!(Vet, %{name: "Aaron"}, authorize?: false)
        Ash.create!(HerdVet, %{herd_id: h.r7.id, vet_id: zoe.id}, authorize?: false)

        assert vet_pages(limit: 2, offset: 1, count: true)["R7"] == {["Ana", "Bruno"], 3, false}
      end)
    end
  end
end
