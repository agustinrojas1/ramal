defmodule RamalLive.InspectorLiveTest do
  use RamalLive.LiveCase

  alias RamalLive.Broadcaster

  defp column(branch), do: "#branch-#{branch.id}"

  defp click(view, branch, button, action) do
    view
    |> element("#{column(branch)} button[phx-click=#{button}][phx-value-action=#{action}]")
    |> render_click()
  end

  defp base_head(herd), do: Ash.get!(Herd, herd.id).head

  defp column_ids(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("article")
    |> LazyHTML.attribute("id")
  end

  describe "the board" do
    test "an empty domain says so", %{conn: conn} do
      {:ok, view, html} = live(conn, "/ramal")

      assert html =~ "No open or proposed branches in RamalLive.Test.Farm"
      refute has_element?(view, "article")
    end

    test "the page title comes from the page, for the host's root layout", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/ramal")
      assert page_title(view) =~ "Ramal"
    end

    test "an open branch is a column with its name, status, age, overlay size and diff", %{
      conn: conn
    } do
      herd = herd!("R7", 30)
      branch = branch!("count again", fn -> Ash.update!(herd, %{head: 31}) end)

      {:ok, view, _html} = live(conn, "/ramal")

      assert has_element?(view, "#{column(branch)} h2", "count again")
      assert has_element?(view, "#{column(branch)} .rl-status", "open")
      assert has_element?(view, "#{column(branch)} .rl-meta", "0s")
      assert has_element?(view, "#{column(branch)} .rl-meta", "1 row · 1 write")
      assert has_element?(view, "#{column(branch)} .rl-kind", "updated")
      assert has_element?(view, "#{column(branch)} .rl-change-head", "Herd")
      assert has_element?(view, "#{column(branch)} tr", "head")
      assert has_element?(view, "#{column(branch)} .rl-before", "30")
      assert has_element?(view, "#{column(branch)} .rl-after", "31")
    end

    test "created and deleted rows show as such", %{conn: conn} do
      doomed = herd!("R1", 8)

      branch =
        branch!("churn", fn ->
          Ash.create!(Herd, %{name: "R9", head: 12})
          Ash.destroy!(doomed)
        end)

      {:ok, view, _html} = live(conn, "/ramal")

      assert has_element?(view, "#{column(branch)} .rl-kind[data-kind=created]")
      assert has_element?(view, "#{column(branch)} .rl-kind[data-kind=deleted]")
      assert has_element?(view, "#{column(branch)} .rl-after", "R9")
      assert has_element?(view, "#{column(branch)} .rl-before", "R1")
    end

    test "a branch with no writes says so", %{conn: conn} do
      branch = branch!("empty")
      {:ok, view, _html} = live(conn, "/ramal")

      assert has_element?(view, column(branch), "No changes yet.")
      assert has_element?(view, "#{column(branch)} .rl-meta", "0 rows · 0 writes")
    end

    test "a fork shows the branch it came from", %{conn: conn} do
      parent = branch!("parent")
      {:ok, fork} = Ramal.fork(parent)

      {:ok, view, _html} = live(conn, "/ramal")

      assert has_element?(view, "#{column(fork)} .rl-meta", String.slice(parent.id, 0, 8))
      refute has_element?(view, "#{column(parent)} dt", "forked from")
    end

    test "a proposal is a column after the open ones, with who proposed it and why", %{conn: conn} do
      proposed = branch!("proposal")
      {:ok, _} = Ramal.propose(proposed, proposed_by: "agent-3", reason: "R7 is crowding L07")
      open = branch!("open, and newer")

      {:ok, view, _html} = live(conn, "/ramal")

      assert has_element?(view, "#{column(proposed)} .rl-status", "proposed")
      assert has_element?(view, "#{column(proposed)} .rl-proposal", "agent-3")
      assert has_element?(view, "#{column(proposed)} .rl-proposal", "R7 is crowding L07")

      assert column_ids(view) == ["branch-#{open.id}", "branch-#{proposed.id}"]
    end

    test "merged, rejected and discarded branches are not on the board", %{conn: conn} do
      herd = herd!("R7", 30)
      merged = branch!("merged", fn -> Ash.update!(herd, %{head: 31}) end)
      {:ok, _} = Ramal.merge(merged)

      discarded = branch!("discarded")
      :ok = Ramal.discard(discarded)

      rejected = branch!("rejected")
      {:ok, _} = Ramal.propose(rejected)
      {:ok, _} = Ramal.reject(rejected)

      kept = branch!("kept")

      {:ok, view, _html} = live(conn, "/ramal")

      assert has_element?(view, column(kept))
      for gone <- [merged, discarded, rejected], do: refute(has_element?(view, column(gone)))
    end

    test "the page works with the theme left to the system, and names both themes in its CSS", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, "/ramal")

      assert html =~ "prefers-color-scheme: dark"
      assert html =~ ~s(data-theme="dark")
      assert html =~ ~s(data-theme="light")
      # Slate for the base line, copper for branches: the logo's two colors.
      assert html =~ "#243044"
      assert html =~ "#d98324"
      assert html =~ "Barlow Condensed"
      assert html =~ "IBM Plex Mono"
    end

    test "the theme buttons set an attribute on the page's own root, on the client", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/ramal")

      assert view |> element("button", "Dark") |> render() =~ "set_attr"
      assert view |> element("button", "Auto") |> render() =~ "remove_attr"
      assert has_element?(view, "#ramal-inspector.ramal")
    end

    test "a route mounted with plain live, which carries no options, says what to do" do
      socket = %Phoenix.LiveView.Socket{
        router: RamalLive.Test.Router,
        assigns: %{__changed__: %{}, config: nil}
      }

      assert_raise ArgumentError, ~r/mount it with `ramal_inspector path/, fn ->
        RamalLive.InspectorLive.handle_params(%{}, "http://localhost/bare", socket)
      end
    end

    test "Reload reads the branches again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/ramal")
      branch = branch!("opened elsewhere")

      refute has_element?(view, column(branch))
      view |> element("button", "Reload") |> render_click()
      assert has_element?(view, column(branch))
    end
  end

  describe "fork" do
    test "forks the branch with no confirmation and shows the fork next to it", %{conn: conn} do
      herd = herd!("R7", 30)
      parent = branch!("parent", fn -> Ash.update!(herd, %{head: 31}) end)

      {:ok, view, _html} = live(conn, "/ramal")
      click(view, parent, "fork", "fork")

      {:ok, branches} = Ramal.list(RamalLive.Test.Farm, status: :open)
      assert [fork] = Enum.reject(branches, &(&1.id == parent.id))
      assert fork.metadata.forked_from == parent.id

      assert has_element?(view, column(fork))
      assert has_element?(view, "#{column(fork)} .rl-after", "31")
      assert has_element?(view, ".rl-banner", "Forked “parent” as “parent”")
    end

    test "a proposal has no fork button, since a proposal is frozen", %{conn: conn} do
      proposed = branch!("proposal")
      {:ok, _} = Ramal.propose(proposed)

      {:ok, view, _html} = live(conn, "/ramal")

      refute has_element?(view, "#{column(proposed)} button", "fork")
    end

    test "a forged fork event for a proposal is ignored", %{conn: conn} do
      proposed = branch!("proposal")
      {:ok, _} = Ramal.propose(proposed)
      {:ok, view, _html} = live(conn, "/ramal")

      render_click(view, "fork", %{"id" => proposed.id})

      {:ok, branches} = Ramal.list(RamalLive.Test.Farm, status: :open)
      assert branches == []
    end
  end

  describe "merge" do
    test "asks first, and changes nothing until it is confirmed", %{conn: conn} do
      herd = herd!("R7", 30)
      branch = branch!("count again", fn -> Ash.update!(herd, %{head: 31}) end)
      {:ok, view, _html} = live(conn, "/ramal")

      html = click(view, branch, "ask", "merge")

      assert html =~ "Merge 1 change into the database?"
      assert has_element?(view, "#{column(branch)} button[phx-click=confirm]", "Yes, merge")
      assert has_element?(view, "#{column(branch)} button", "Cancel")
      refute has_element?(view, "#{column(branch)} button[phx-value-action=discard]")
      assert base_head(herd) == 30
      assert {:ok, %{status: :open}} = Ramal.get(branch.id)
    end

    test "Cancel puts the buttons back", %{conn: conn} do
      branch = branch!("changed my mind")
      {:ok, view, _html} = live(conn, "/ramal")

      click(view, branch, "ask", "merge")
      view |> element("#{column(branch)} button", "Cancel") |> render_click()

      assert has_element?(view, "#{column(branch)} button[phx-value-action=merge]")
      refute has_element?(view, "#{column(branch)} button[phx-click=confirm]")
    end

    test "merging writes the base through the real actions and removes the column", %{conn: conn} do
      herd = herd!("R7", 30)
      branch = branch!("count again", fn -> Ash.update!(herd, %{head: 31}) end)
      {:ok, view, _html} = live(conn, "/ramal")

      click(view, branch, "ask", "merge")
      click(view, branch, "confirm", "merge")
      render_async(view)

      assert base_head(herd) == 31
      refute has_element?(view, column(branch))
      assert has_element?(view, ".rl-banner", "Merged “count again”: 1 action replayed.")
      assert {:ok, %{status: :merged}} = Ramal.get(branch.id)
    end

    test "a confirm that was never asked for does nothing", %{conn: conn} do
      herd = herd!("R7", 30)
      branch = branch!("count again", fn -> Ash.update!(herd, %{head: 31}) end)
      {:ok, view, _html} = live(conn, "/ramal")

      render_click(view, "confirm", %{"id" => branch.id, "action" => "merge"})
      render_async(view)

      assert base_head(herd) == 30
      assert {:ok, %{status: :open}} = Ramal.get(branch.id)
    end

    test "a confirm for another action than the one asked is ignored", %{conn: conn} do
      herd = herd!("R7", 30)
      branch = branch!("count again", fn -> Ash.update!(herd, %{head: 31}) end)
      {:ok, view, _html} = live(conn, "/ramal")

      click(view, branch, "ask", "merge")
      render_click(view, "confirm", %{"id" => branch.id, "action" => "discard"})

      assert {:ok, %{status: :open}} = Ramal.get(branch.id)
      assert has_element?(view, "#{column(branch)} button[phx-click=confirm]", "Yes, merge")
    end

    test "a merge that fails is explained in the column, which keeps its buttons", %{conn: conn} do
      herd = herd!("R7", 30)
      branch = branch!("count again", fn -> Ash.update!(herd, %{head: 31}) end)
      {:ok, view, _html} = live(conn, "/ramal")

      # The branch is frozen as a proposal by someone else; the page has not heard (no broadcaster is running).
      {:ok, _} = Ramal.propose(branch)

      click(view, branch, "ask", "merge")
      click(view, branch, "confirm", "merge")
      render_async(view)

      assert has_element?(view, "#{column(branch)} .rl-notice[data-kind=error]")
      assert base_head(herd) == 30
      # It was read again to find out why, so the column now shows what it is.
      assert has_element?(view, "#{column(branch)} .rl-status", "proposed")
      assert has_element?(view, "#{column(branch)} button[phx-value-action=approve]")
    end

    test "a merge that fails on a branch that has left the board is explained in the banner", %{
      conn: conn
    } do
      branch = branch!("gone")
      {:ok, view, _html} = live(conn, "/ramal")
      :ok = Ramal.discard(branch)

      click(view, branch, "ask", "merge")
      click(view, branch, "confirm", "merge")
      render_async(view)

      refute has_element?(view, column(branch))
      assert has_element?(view, ".rl-banner[data-kind=error]")
    end

    test "the error stays when the branch is read again, and goes with the next action", %{
      conn: conn
    } do
      branch = branch!("changing")
      {:ok, view, _html} = live(conn, "/ramal")
      {:ok, _} = Ramal.propose(branch)

      click(view, branch, "ask", "merge")
      click(view, branch, "confirm", "merge")
      render_async(view)
      view |> element("button", "Reload") |> render_click()
      assert has_element?(view, "#{column(branch)} .rl-notice[data-kind=error]")

      click(view, branch, "ask", "reject")
      refute has_element?(view, "#{column(branch)} .rl-notice")
    end
  end

  describe "an answer from a merge that did not finish well" do
    setup do
      branch = branch!("slow merge")

      config = %{
        domain: RamalLive.Test.Farm,
        pubsub: RamalLive.Test.PubSub,
        actor: nil,
        debounce: 0
      }

      {:ok, column} = {:ok, RamalLive.Column.build(branch, [])}

      socket = %Phoenix.LiveView.Socket{
        router: RamalLive.Test.Router,
        assigns: %{
          __changed__: %{},
          config: config,
          columns: [%{column | busy: :merge}],
          confirming: nil,
          banner: nil
        }
      }

      %{socket: socket, branch: branch}
    end

    test "a crash re-enables the buttons and says why", %{socket: socket, branch: branch} do
      {:noreply, socket} =
        RamalLive.InspectorLive.handle_async({:decide, branch.id, :merge}, {:exit, :boom}, socket)

      assert [%{busy: nil, notice: %{kind: :error, text: text}}] = socket.assigns.columns
      assert text =~ "merge crashed"
      assert text =~ "boom"
    end

    test "an error re-enables the buttons and says why", %{socket: socket, branch: branch} do
      error = Ramal.Error.new(:stale, "1 row(s) changed in the base", %{rows: []})

      {:noreply, socket} =
        RamalLive.InspectorLive.handle_async(
          {:decide, branch.id, :merge},
          {:ok, {:error, error}},
          socket
        )

      assert [%{busy: nil, notice: %{kind: :error, text: "1 row(s) changed in the base"}}] =
               socket.assigns.columns
    end
  end

  describe "discard" do
    test "asks first, then discards", %{conn: conn} do
      branch = branch!("scratch")
      {:ok, view, _html} = live(conn, "/ramal")

      html = click(view, branch, "ask", "discard")
      assert html =~ "Discard this branch? Its changes are lost."
      assert {:ok, %{status: :open}} = Ramal.get(branch.id)

      click(view, branch, "confirm", "discard")

      refute has_element?(view, column(branch))
      assert has_element?(view, ".rl-banner", "Discarded “scratch”.")
      assert {:ok, %{status: :discarded}} = Ramal.get(branch.id)
    end
  end

  describe "proposals" do
    setup do
      herd = herd!("R7", 30)
      branch = branch!("move R7", fn -> Ash.update!(herd, %{head: 31}) end)
      {:ok, _} = Ramal.propose(branch, proposed_by: "agent-3", reason: "count")
      %{herd: herd, branch: branch}
    end

    test "can be approved or rejected, and nothing else", %{conn: conn, branch: branch} do
      {:ok, view, _html} = live(conn, "/ramal")

      assert has_element?(view, "#{column(branch)} button[phx-value-action=approve]")
      assert has_element?(view, "#{column(branch)} button[phx-value-action=reject]")
      refute has_element?(view, "#{column(branch)} button[phx-value-action=merge]")
      refute has_element?(view, "#{column(branch)} button[phx-value-action=discard]")
    end

    test "approving asks first, then merges and records the decision", %{
      conn: conn,
      herd: herd,
      branch: branch
    } do
      {:ok, view, _html} = live(conn, "/ramal")

      html = click(view, branch, "ask", "approve")
      assert html =~ "Approve and merge 1 change into the database?"
      assert base_head(herd) == 30

      click(view, branch, "confirm", "approve")
      render_async(view)

      assert base_head(herd) == 31
      refute has_element?(view, column(branch))
      assert has_element?(view, ".rl-banner", "Approved and merged “move R7”")

      assert {:ok, %{status: :merged, proposal: %{decision: %{status: :approved, replayed: 1}}}} =
               Ramal.get(branch.id)
    end

    test "rejecting asks first, then keeps the branch as a record", %{
      conn: conn,
      herd: herd,
      branch: branch
    } do
      {:ok, view, _html} = live(conn, "/ramal")

      html = click(view, branch, "ask", "reject")
      assert html =~ "Reject this proposal?"
      assert {:ok, %{status: :proposed}} = Ramal.get(branch.id)

      click(view, branch, "confirm", "reject")

      refute has_element?(view, column(branch))
      assert has_element?(view, ".rl-banner", "Rejected “move R7”.")
      assert base_head(herd) == 30

      assert {:ok, %{status: :rejected, proposal: %{decision: %{status: :rejected}}}} =
               Ramal.get(branch.id)
    end

    test "a forged ask for merge on a proposal is ignored", %{conn: conn, branch: branch} do
      {:ok, view, _html} = live(conn, "/ramal")

      render_click(view, "ask", %{"id" => branch.id, "action" => "merge"})

      refute has_element?(view, "#{column(branch)} button[phx-click=confirm]")
    end

    test "an unknown action in a forged event is ignored", %{conn: conn, branch: branch} do
      {:ok, view, _html} = live(conn, "/ramal")

      render_click(view, "ask", %{"id" => branch.id, "action" => "format_disk"})
      render_click(view, "ask", %{"id" => "no-such-branch", "action" => "merge"})

      refute has_element?(view, "button[phx-click=confirm]")
    end
  end

  describe "the actor" do
    test "the host's actor decides, and is recorded as the decider", %{conn: conn} do
      herd = herd!("R7", 30)
      branch = branch!("move R7", fn -> Ash.update!(herd, %{head: 31}) end)
      {:ok, _} = Ramal.propose(branch)
      {:ok, view, _html} = live(conn, "/ramal-actor")

      click(view, branch, "ask", "approve")
      click(view, branch, "confirm", "approve")
      render_async(view)

      assert {:ok, %{proposal: %{decision: %{by: %{name: "Marta", role: :admin}}}}} =
               Ramal.get(branch.id)
    end

    test "rejecting records the actor too", %{conn: conn} do
      branch = branch!("move R7")
      {:ok, _} = Ramal.propose(branch)
      {:ok, view, _html} = live(conn, "/ramal-actor")

      click(view, branch, "ask", "reject")
      click(view, branch, "confirm", "reject")

      assert {:ok, %{proposal: %{decision: %{by: %{name: "Marta"}}}}} = Ramal.get(branch.id)
    end

    test "without an actor option the decision has no decider", %{conn: conn} do
      branch = branch!("move R7")
      {:ok, _} = Ramal.propose(branch)
      {:ok, view, _html} = live(conn, "/ramal")

      click(view, branch, "ask", "reject")
      click(view, branch, "confirm", "reject")

      assert {:ok, %{proposal: %{decision: %{by: nil}}}} = Ramal.get(branch.id)
    end
  end

  describe "live updates" do
    test "without the broadcaster the page says live updates are off", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/ramal")

      assert has_element?(view, ".rl-banner", "Live updates are off")
      assert has_element?(view, ".rl-banner code", "RamalLive.Broadcaster")
    end

    test "with it the page does not", %{conn: conn} do
      start_supervised!({Broadcaster, pubsub: RamalLive.Test.PubSub})
      {:ok, view, _html} = live(conn, "/ramal")

      refute has_element?(view, ".rl-banner")
    end

    test "a new branch appears and a write to it shows in its diff, with no click", %{conn: conn} do
      start_supervised!({Broadcaster, pubsub: RamalLive.Test.PubSub})
      herd = herd!("R7", 30)
      {:ok, view, _html} = live(conn, "/ramal")

      {:ok, branch} = Ramal.branch(RamalLive.Test.Farm, name: "appears")
      eventually(fn -> has_element?(view, column(branch)) end)
      assert has_element?(view, "#{column(branch)}", "No changes yet.")

      Ramal.run!(branch, fn -> Ash.update!(herd, %{head: 33}) end)
      eventually(fn -> has_element?(view, "#{column(branch)} .rl-after", "33") end)
      assert has_element?(view, "#{column(branch)} .rl-meta", "1 row · 1 write")
    end

    test "a change to one branch reads that branch and no other", %{conn: conn} do
      start_supervised!({Broadcaster, pubsub: RamalLive.Test.PubSub})
      herd = herd!("R7", 30)
      quiet = branch!("quiet")
      busy = branch!("busy")
      {:ok, view, _html} = live(conn, "/ramal")

      reads = capture_reads()
      Ramal.run!(busy, fn -> Ash.update!(herd, %{head: 35}) end)
      eventually(fn -> has_element?(view, "#{column(busy)} .rl-after", "35") end)

      assert Enum.uniq(drain_reads(reads)) == [busy.id]
      refute busy.id == quiet.id
    end

    test "proposing moves the column to the proposals; discarding removes it", %{conn: conn} do
      start_supervised!({Broadcaster, pubsub: RamalLive.Test.PubSub})
      first = branch!("first")
      second = branch!("second")
      {:ok, view, _html} = live(conn, "/ramal")

      {:ok, _} = Ramal.propose(first, proposed_by: "agent")
      eventually(fn -> has_element?(view, "#{column(first)} .rl-status", "proposed") end)

      assert column_ids(view) == ["branch-#{second.id}", "branch-#{first.id}"]

      :ok = Ramal.discard(second)
      eventually(fn -> not has_element?(view, column(second)) end)
    end

    test "a merge made elsewhere removes the column", %{conn: conn} do
      start_supervised!({Broadcaster, pubsub: RamalLive.Test.PubSub})
      herd = herd!("R7", 30)
      branch = branch!("merged elsewhere", fn -> Ash.update!(herd, %{head: 31}) end)
      {:ok, view, _html} = live(conn, "/ramal")

      {:ok, _} = Ramal.merge(branch)
      eventually(fn -> not has_element?(view, column(branch)) end)
    end
  end

  describe "a burst of writes with a debounce window" do
    test "is read fewer times than it wrote, and ends on the last state", %{conn: conn} do
      start_supervised!({Broadcaster, pubsub: RamalLive.Test.PubSub})
      herd = herd!("R7", 0)
      branch = branch!("busy")
      {:ok, view, _html} = live(conn, "/ramal-debounced")

      reads = capture_reads()

      Ramal.run!(branch, fn ->
        Enum.reduce(1..20, herd, fn n, herd -> Ash.update!(herd, %{head: n}) end)
      end)

      eventually(fn -> has_element?(view, "#{column(branch)} .rl-after", "20") end)
      assert has_element?(view, "#{column(branch)} .rl-meta", "20 writes")

      read_count = length(drain_reads(reads))
      assert read_count >= 1
      assert read_count < 20
    end
  end

  # Sends {:read, branch_id} to the test for every branch the page reads, until the test ends.
  defp capture_reads do
    test = self()
    handler = "reads-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:ramal_live, :column, :read],
      fn _event, _measurements, %{branch_id: id}, _config -> send(test, {:read, id}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  defp drain_reads(handler, acc \\ []) do
    receive do
      {:read, id} -> drain_reads(handler, [id | acc])
    after
      60 -> Enum.reverse(acc)
    end
  end
end
