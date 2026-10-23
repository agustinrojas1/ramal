defmodule Ramal.ToolsTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.Tools

  @opts [domain: Farm, owner: "session-1", proposed_by: "planner"]

  setup do
    start_supervised!(Ramal.Supervisor)
    {:ok, Map.put(Seeds.seed!(), :tools, @opts)}
  end

  defp call!(name, args, opts \\ @opts) do
    assert {:ok, result} = Tools.call(name, args, opts)
    result
  end

  defp open!(opts \\ @opts), do: call!("ramal_open_branch", %{"name" => "plan"}, opts)["id"]

  describe "definitions/1" do
    test "describes each tool with a name, a description and a JSON Schema object" do
      definitions = Tools.definitions(@opts)

      assert Enum.map(definitions, & &1.name) == [
               "ramal_open_branch",
               "ramal_list_branches",
               "ramal_fork_branch",
               "ramal_branch_diff",
               "ramal_propose_branch",
               "ramal_discard_branch"
             ]

      for definition <- definitions do
        assert is_binary(definition.description)
        assert %{"type" => "object", "properties" => %{}} = definition.input_schema
        assert {:ok, _json} = Jason.encode(definition)
      end
    end

    test "does not offer merge, approve or reject to the agent" do
      names = @opts |> Tools.definitions() |> Enum.map(& &1.name)
      refute Enum.any?(names, &String.contains?(&1, ["merge", "approve", "reject"]))

      assert {:error, "unknown tool \"ramal_merge_branch\""} =
               Tools.call("ramal_merge_branch", %{}, @opts)
    end

    test "needs the domain" do
      assert_raise ArgumentError, ~r/:domain/, fn -> Tools.definitions([]) end

      assert_raise ArgumentError, ~r/:domain/, fn ->
        Tools.call("ramal_list_branches", %{}, owner: "a")
      end
    end

    test "refuses a nil owner, which would match every unowned branch" do
      assert_raise ArgumentError, ~r/owner: nil/, fn ->
        Tools.call("ramal_list_branches", %{}, domain: Farm, owner: nil)
      end
    end
  end

  describe "open, list, fork and discard" do
    test "opens a branch of the domain owned by the configured owner" do
      assert %{"id" => id, "name" => "plan", "status" => "open", "changed_rows" => 0} =
               call!("ramal_open_branch", %{"name" => "plan"})

      assert {:ok, %Ramal.Branch{domain: Farm, owner: "session-1"}} = Ramal.get(id)
    end

    test "lists only the branches of the owner, optionally by status" do
      mine = open!()
      other = open!(domain: Farm, owner: "session-2")
      call!("ramal_propose_branch", %{"branch_id" => mine, "reason" => "r"})

      assert %{"branches" => [%{"id" => ^mine}]} = call!("ramal_list_branches", %{})

      assert %{"branches" => [%{"id" => ^mine}]} =
               call!("ramal_list_branches", %{"status" => "proposed"})

      assert %{"branches" => []} = call!("ramal_list_branches", %{"status" => "open"})
      refute other == mine
    end

    test "refuses a status it does not know" do
      assert {:error, "status must be one of" <> _} =
               Tools.call("ramal_list_branches", %{"status" => "nope"}, @opts)
    end

    test "forks a branch with what it changed" do
      id = open!()
      Ramal.run!(id, fn -> Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false) end)

      assert %{"id" => fork, "status" => "open", "changed_rows" => 1} =
               call!("ramal_fork_branch", %{"branch_id" => id})

      refute fork == id
    end

    test "discards a branch" do
      id = open!()

      assert %{"id" => ^id, "status" => "discarded"} =
               call!("ramal_discard_branch", %{"branch_id" => id})

      assert {:error, "not_open:" <> _} =
               Tools.call("ramal_fork_branch", %{"branch_id" => id}, @opts)
    end
  end

  describe "diff" do
    test "lists the changes of a branch as JSON-safe data", %{herds: herds} do
      id = open!()

      Ramal.run!(id, fn ->
        Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
        Ash.update!(herds.r7, %{head: 31}, authorize?: false)
      end)

      assert %{"branch" => %{"id" => ^id}, "changes" => changes} =
               call!("ramal_branch_diff", %{"branch_id" => id})

      assert {:ok, _json} = Jason.encode(changes)
      assert changes |> Enum.map(& &1["kind"]) |> Enum.sort() == ["created", "updated"]

      assert %{
               "resource" => "Ramal.Test.Farm.Herd",
               "changes" => %{"head" => %{"before" => 30, "after" => 31}}
             } =
               Enum.find(changes, &(&1["kind"] == "updated"))
    end
  end

  describe "propose" do
    test "freezes the branch and records the configured proposer and the reason" do
      id = open!()

      assert %{"id" => ^id, "status" => "proposed"} =
               call!("ramal_propose_branch", %{"branch_id" => id, "reason" => "crowded"})

      assert {:ok, %{status: :proposed, proposal: %{proposer: "planner", reason: "crowded"}}} =
               Ramal.get(id)
    end

    test "needs a reason" do
      id = open!()

      assert {:error, "reason is required"} =
               Tools.call("ramal_propose_branch", %{"branch_id" => id}, @opts)

      assert {:ok, %{status: :open}} = Ramal.get(id)
    end
  end

  describe "scope" do
    test "a branch of another owner is not found, whatever id the model passes" do
      theirs = open!(domain: Farm, owner: "session-2")

      for tool <- ~w(ramal_fork_branch ramal_branch_diff ramal_discard_branch) do
        assert {:error, "not_found: no branch with that id"} =
                 Tools.call(tool, %{"branch_id" => theirs}, @opts)
      end

      args = %{"branch_id" => theirs, "reason" => "r"}

      assert {:error, "not_found: no branch with that id"} =
               Tools.call("ramal_propose_branch", args, @opts)

      assert {:ok, %{status: :open}} = Ramal.get(theirs)
    end

    test "a branch of another domain is not found" do
      {:ok, branch} = Ramal.branch(Farm, owner: "session-1")

      assert {:error, "not_found" <> _} =
               Tools.call("ramal_branch_diff", %{"branch_id" => branch.id}, domain: Elsewhere)
    end

    test "without an owner the tools see every branch of the domain" do
      mine = open!()
      assert %{"branches" => [%{"id" => ^mine}]} = call!("ramal_list_branches", %{}, domain: Farm)
      assert %{"changes" => []} = call!("ramal_branch_diff", %{"branch_id" => mine}, domain: Farm)
    end

    test "an unknown id and a missing id are reported to the model" do
      assert {:error, "not_found:" <> _} =
               Tools.call("ramal_branch_diff", %{"branch_id" => "nope"}, @opts)

      assert {:error, "branch_id is required"} = Tools.call("ramal_branch_diff", %{}, @opts)

      assert {:error, "branch_id must be a non-empty string"} =
               Tools.call("ramal_branch_diff", %{"branch_id" => 7}, @opts)
    end
  end
end
