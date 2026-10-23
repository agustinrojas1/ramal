defmodule RamalAshAiExample.ToolsTest do
  # Ramal.Supervisor is one per node and named, and the ETS table is shared, so this suite cannot run concurrently.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ash.DataLayer.Ets
  alias AshAi.Mcp.Router
  alias RamalAshAiExample.{BranchPlug, Farm, Herd}

  @user %{id: "user-1"}
  @other %{id: "user-2"}

  setup do
    start_supervised!(Ramal.Supervisor)
    reset(Herd)
    on_exit(fn -> reset(Herd) end)

    r7 = Ash.create!(Herd, %{name: "R7", paddock: "L07"}, authorize?: false)
    r8 = Ash.create!(Herd, %{name: "R8", paddock: "L07"}, authorize?: false)
    {:ok, branch} = Ramal.branch(Farm, owner: @user.id)

    {:ok, branch: branch, r7: r7, r8: r8}
  end

  # Ash.DataLayer.Ets.stop/1 returns before the table manager is gone; wait for it.
  defp reset(resource) do
    manager =
      Process.whereis(Module.concat(Ets.Info.table(resource), Ets.TableManager))

    ref = manager && Process.monitor(manager)
    Ets.stop(resource)

    if ref do
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        1_000 -> raise "the ETS table manager did not stop"
      end
    end
  end

  defp stored,
    do: Herd |> Ash.read!(authorize?: false) |> Enum.map(&{&1.name, &1.paddock}) |> Enum.sort()

  defp tool(name),
    do: Enum.find(AshAi.exposed_tools(otp_app: :ramal_ash_ai_example), &(&1.name == name))

  describe "the tools of an agent turn, run with the branch as their context" do
    test "the writes land in the branch, not in the data layer, and the proposal's diff is what the tools wrote",
         %{
           branch: branch,
           r7: r7
         } do
      before = stored()
      context = %{context: Ramal.context(branch)}

      # A scripted turn: the model lists the herds, then moves R7. AshAi runs each tool call with the tool context.
      assert {:ok, listed, _raw} = AshAi.Tools.execute(tool(:list_herds), %{}, context)
      assert listed =~ "R7"

      assert {:ok, moved, _raw} =
               AshAi.Tools.execute(
                 tool(:move_herd),
                 %{"input" => %{"id" => r7.id, "paddock" => "L18"}},
                 context
               )

      assert moved =~ "L18"

      # The data layer never saw the move.
      assert stored() == before

      # The branch did, and the tools read it back.
      assert {:ok, listed_again, _raw} = AshAi.Tools.execute(tool(:list_herds), %{}, context)
      assert listed_again =~ "L18"

      assert {:ok, changes} = Ramal.diff(branch)

      assert [%Ramal.Change{kind: :updated, key: key, changes: %{paddock: {"L07", "L18"}}}] =
               changes

      assert key == r7.id

      assert {:ok, %Ramal.Branch{status: :proposed}} = Ramal.propose(branch, proposed_by: "agent")
      assert stored() == before
    end
  end

  describe "Ramal.Tools and the AshAi tools in one loop" do
    test "the model opens a branch, works in it with AshAi tools and proposes; nothing is merged",
         %{r7: r7} do
      before = stored()
      opts = [domain: Farm, owner: @user.id, proposed_by: "planner"]

      assert {:ok, %{"id" => id}} =
               Ramal.Tools.call("ramal_open_branch", %{"name" => "move R7"}, opts)

      # The host, not the model, turns the branch id into the context of the AshAi tool call.
      context = %{context: Ramal.context(id)}

      assert {:ok, _text, _raw} =
               AshAi.Tools.execute(
                 tool(:move_herd),
                 %{"input" => %{"id" => r7.id, "paddock" => "L18"}},
                 context
               )

      assert {:ok, %{"changes" => [%{"kind" => "updated"}]}} =
               Ramal.Tools.call("ramal_branch_diff", %{"branch_id" => id}, opts)

      assert {:ok, %{"status" => "proposed"}} =
               Ramal.Tools.call(
                 "ramal_propose_branch",
                 %{"branch_id" => id, "reason" => "R7 is overstocked"},
                 opts
               )

      assert stored() == before
    end

    # AshAi 1.4.0 runs an update tool with Ash.bulk_update! (Tool.Execution.run_update/7), which a branch refuses.
    test "an AshAi update tool is refused in a branch and writes nothing", %{
      branch: branch,
      r7: r7
    } do
      before = stored()

      result =
        capture_log(fn ->
          send(
            self(),
            {:result,
             AshAi.Tools.execute(
               tool(:update_herd),
               %{"input" => %{"paddock" => "L18"}, "id" => r7.id},
               %{context: Ramal.context(branch)}
             )}
          )
        end)

      assert result =~ "bulk"
      assert_received {:result, {:error, _message}}

      assert stored() == before
      assert {:ok, []} = Ramal.diff(branch)
    end
  end

  describe "the MCP router" do
    defp call(branch_id, actor, tool_name, arguments) do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => tool_name, "arguments" => arguments}
      }

      Plug.Test.conn(:post, "/", Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("x-ramal-branch", branch_id)
      |> Ash.PlugHelpers.set_actor(actor)
      |> BranchPlug.call(BranchPlug.init([]))
      |> then(fn conn ->
        if conn.halted do
          conn
        else
          Router.call(
            conn,
            Router.init(
              tools: [:list_herds, :move_herd],
              otp_app: :ramal_ash_ai_example
            )
          )
        end
      end)
    end

    test "a tool call of the branch's owner is in the branch", %{branch: branch, r7: r7} do
      before = stored()

      conn =
        call(branch.id, @user, "move_herd", %{"input" => %{"id" => r7.id, "paddock" => "L18"}})

      assert conn.status == 200, conn.resp_body
      assert stored() == before
      assert {:ok, [%Ramal.Change{key: key}]} = Ramal.diff(branch)
      assert key == r7.id
    end

    test "a client that names a branch it does not own is refused and the branch is untouched", %{
      branch: branch,
      r7: r7
    } do
      conn =
        call(branch.id, @other, "move_herd", %{"input" => %{"id" => r7.id, "paddock" => "L18"}})

      assert conn.status == 404
      assert {:ok, []} = Ramal.diff(branch)
      assert stored() == [{"R7", "L07"}, {"R8", "L07"}]
    end

    test "an unknown branch id is refused", %{r7: r7} do
      conn = call("nope", @user, "move_herd", %{"input" => %{"id" => r7.id, "paddock" => "L18"}})
      assert conn.status == 404
      assert stored() == [{"R7", "L07"}, {"R8", "L07"}]
    end
  end
end
