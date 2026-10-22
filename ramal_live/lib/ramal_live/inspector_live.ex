defmodule RamalLive.InspectorLive do
  @moduledoc false
  # The inspector page: the open and proposed branches of one domain as columns. Mounted by `ramal_inspector/2`.
  #
  # State: `columns` (see `RamalLive.Column`, ordered for display), `confirming` (`{branch_id, action}` while a column
  # shows its inline "are you sure?"), `banner` (the outcome of an action that removed a column or created one) and,
  # when `:debounce` is not zero, the ids of branches that changed and have not been read again yet.
  #
  # The page reads a branch with `Ramal.get/1` and `Ramal.diff/1` and nothing else, so it shows what the public API
  # shows. Reading loads the branch's process if it was unloaded; processes unload again after `idle_timeout`.

  use Phoenix.LiveView

  alias Phoenix.LiveView.JS
  alias RamalLive.{BranchColumn, Broadcaster, Column, Events, Style}

  @tick :timer.seconds(30)

  # `phx-value-action` arrives as a string. A closed lookup, never `String.to_atom/1`, since it is client input.
  @actions %{
    "fork" => :fork,
    "merge" => :merge,
    "discard" => :discard,
    "approve" => :approve,
    "reject" => :reject
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Ramal",
       config: nil,
       columns: [],
       confirming: nil,
       banner: nil,
       dirty: MapSet.new(),
       flush_timer: nil,
       live?: true,
       now: DateTime.utc_now()
     )}
  end

  # The route's options (domain, PubSub, ...) are not in the session, which a `live` route cannot extend. They are the
  # route's metadata, and `Phoenix.Router.route_info/4` returns it for the URL the page was reached at.
  @impl true
  def handle_params(_params, uri, %{assigns: %{config: nil}} = socket) do
    {:noreply, start(socket, config_for(socket, uri))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp config_for(socket, uri) do
    %URI{host: host, path: path} = URI.parse(uri)

    case Phoenix.Router.route_info(socket.router, "GET", path || "/", host) do
      %{ramal_inspector: config} ->
        config

      _other ->
        raise ArgumentError,
              "#{inspect(socket.router)} has no ramal_inspector route at #{inspect(path)}. " <>
                "RamalLive.InspectorLive reads its options from the route, so mount it with " <>
                "`ramal_inspector path, domain: ..., pubsub: ...` and not with `live`"
    end
  end

  defp start(socket, config) do
    # Subscribe before reading, so that a change between the read and the subscription is not lost.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(config.pubsub, Events.topic(config.domain))
      Process.send_after(self(), :tick, @tick)
    end

    socket
    |> assign(config: config, live?: Broadcaster.attached?(config.pubsub))
    |> load_all()
  end

  # -- reading --------------------------------------------------------------------------------------------------------

  defp load_all(socket) do
    domain = socket.assigns.config.domain

    with {:ok, open} <- Ramal.list(domain, status: :open),
         {:ok, proposed} <- Ramal.list(domain, status: :proposed) do
      columns =
        (open ++ proposed)
        |> Enum.flat_map(&read_listed(socket, &1.id))
        |> Column.sort()

      assign(socket, columns: columns, banner: nil)
    else
      {:error, error} ->
        assign(socket, columns: [], banner: {:error, Exception.message(error)})
    end
  end

  defp read_listed(socket, id) do
    case load_column(socket.assigns.config.domain, id) do
      {:ok, column} -> [keep_ui_state(socket, column)]
      :gone -> []
    end
  end

  # Every read of a branch is announced, so a host (and the tests) can see what the page costs and that a change to
  # one branch reads that branch only.
  defp load_column(domain, id) do
    started = System.monotonic_time()
    column = read_column(id)

    :telemetry.execute(
      [:ramal_live, :column, :read],
      %{duration: System.monotonic_time() - started},
      %{branch_id: id, domain: domain}
    )

    column
  end

  defp read_column(id) do
    case Ramal.get(id) do
      {:ok, %{status: status} = branch} when status in [:open, :proposed] ->
        case Ramal.diff(id) do
          {:ok, changes} -> {:ok, Column.build(branch, changes)}
          {:error, error} -> {:ok, Column.build_unreadable(branch, Exception.message(error))}
        end

      _gone_or_finished ->
        :gone
    end
  end

  # Re-reads one branch: the only place a telemetry event or an action costs a diff, and only for the branch it names.
  defp refresh(socket, id) do
    case load_column(socket.assigns.config.domain, id) do
      {:ok, column} -> put_column(socket, keep_ui_state(socket, column))
      :gone -> drop_column(socket, id)
    end
  end

  # What the person did last (a busy button, the outcome of an action) belongs to the column, not to the branch.
  defp keep_ui_state(socket, column) do
    case Enum.find(socket.assigns.columns, &(&1.id == column.id)) do
      nil -> column
      old -> %{column | busy: old.busy, notice: old.notice}
    end
  end

  defp put_column(socket, column) do
    others = Enum.reject(socket.assigns.columns, &(&1.id == column.id))
    assign(socket, columns: Column.sort([column | others]))
  end

  defp drop_column(socket, id) do
    confirming =
      if match?({^id, _}, socket.assigns.confirming), do: nil, else: socket.assigns.confirming

    assign(socket,
      columns: Enum.reject(socket.assigns.columns, &(&1.id == id)),
      confirming: confirming
    )
  end

  defp update_column(socket, id, fun) do
    assign(socket,
      columns: Enum.map(socket.assigns.columns, &if(&1.id == id, do: fun.(&1), else: &1))
    )
  end

  defp find_column(socket, id), do: Enum.find(socket.assigns.columns, &(&1.id == id))

  # -- messages -------------------------------------------------------------------------------------------------------

  @impl true
  def handle_info({:ramal_live, id, _event}, %{assigns: %{config: %{debounce: 0}}} = socket) do
    {:noreply, refresh(socket, id)}
  end

  def handle_info({:ramal_live, id, _event}, socket) do
    dirty = MapSet.put(socket.assigns.dirty, id)

    # The first change opens the window; the ones after it ride along in the same read.
    timer =
      socket.assigns.flush_timer ||
        Process.send_after(self(), :flush, socket.assigns.config.debounce)

    {:noreply, assign(socket, dirty: dirty, flush_timer: timer)}
  end

  def handle_info(:flush, socket) do
    socket = Enum.reduce(socket.assigns.dirty, socket, &refresh(&2, &1))
    {:noreply, assign(socket, dirty: MapSet.new(), flush_timer: nil)}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick)
    {:noreply, assign(socket, now: DateTime.utc_now())}
  end

  # -- events ---------------------------------------------------------------------------------------------------------

  @impl true
  def handle_event("reload", _params, socket), do: {:noreply, load_all(socket)}
  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, banner: nil)}
  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, confirming: nil)}

  def handle_event("fork", %{"id" => id}, socket) do
    case find_column(socket, id) do
      %Column{status: :open} = column -> {:noreply, fork(socket, column)}
      _missing_or_not_open -> {:noreply, socket}
    end
  end

  # Merge, discard, approve and reject ask first. The confirmation is state on the server, so a client cannot skip it
  # by sending the second event on its own.
  def handle_event("ask", %{"id" => id, "action" => action}, socket) do
    with %Column{} = column <- find_column(socket, id),
         action when action in [:merge, :discard, :approve, :reject] <- Map.get(@actions, action),
         true <- allowed?(column, action) do
      {:noreply,
       socket
       |> update_column(id, &%{&1 | notice: nil})
       |> assign(confirming: {id, action})}
    else
      _unknown -> {:noreply, socket}
    end
  end

  def handle_event("confirm", %{"id" => id, "action" => action}, socket) do
    with {^id, confirmed} <- socket.assigns.confirming,
         ^confirmed <- Map.get(@actions, action),
         %Column{} = column <- find_column(socket, id),
         true <- allowed?(column, confirmed) do
      {:noreply, socket |> assign(confirming: nil) |> perform(confirmed, column)}
    else
      _not_confirmed -> {:noreply, socket}
    end
  end

  defp allowed?(%Column{status: :open}, action), do: action in [:merge, :discard]
  defp allowed?(%Column{status: :proposed}, action), do: action in [:approve, :reject]
  defp allowed?(%Column{}, _action), do: false

  defp fork(socket, column) do
    case Ramal.fork(column.id) do
      {:ok, fork} ->
        socket
        |> refresh(fork.id)
        |> assign(banner: {:info, "Forked #{label(column)} as #{label(fork)}."})

      {:error, error} ->
        fail(socket, column.id, error)
    end
  end

  defp perform(socket, :discard, column) do
    case Ramal.discard(column.id) do
      :ok ->
        socket |> drop_column(column.id) |> assign(banner: {:info, "Discarded #{label(column)}."})

      {:error, error} ->
        fail(socket, column.id, error)
    end
  end

  defp perform(socket, :reject, column) do
    case Ramal.reject(column.id, decided_by: actor(socket)) do
      {:ok, _rejected} ->
        socket |> drop_column(column.id) |> assign(banner: {:info, "Rejected #{label(column)}."})

      {:error, error} ->
        fail(socket, column.id, error)
    end
  end

  # A merge replays the whole log in a transaction and can take a while, so it runs in a task and the column shows
  # a disabled button until it answers.
  defp perform(socket, action, column) when action in [:merge, :approve] do
    opts = decision_opts(action, actor(socket))

    socket
    |> update_column(column.id, &%{&1 | busy: action, notice: nil})
    |> start_async({:decide, column.id, action}, fn -> apply(Ramal, action, [column.id, opts]) end)
  end

  defp decision_opts(:merge, nil), do: []
  defp decision_opts(:merge, actor), do: [actor: actor]
  defp decision_opts(:approve, nil), do: []
  defp decision_opts(:approve, actor), do: [decided_by: actor, actor: actor]

  @impl true
  def handle_async({:decide, id, action}, {:ok, {:ok, %Ramal.Merge.Result{} = result}}, socket) do
    name = label(result.branch)
    verb = if action == :merge, do: "Merged", else: "Approved and merged"
    text = "#{verb} #{name}: #{replayed(result.replayed)} replayed."
    {:noreply, socket |> drop_column(id) |> assign(banner: {:info, text})}
  end

  def handle_async({:decide, id, _action}, {:ok, {:error, error}}, socket) do
    {:noreply, socket |> update_column(id, &%{&1 | busy: nil}) |> fail(id, error)}
  end

  def handle_async({:decide, id, action}, {:exit, reason}, socket) do
    text = "#{action} crashed: #{Exception.format_exit(reason)}"
    {:noreply, socket |> update_column(id, &%{&1 | busy: nil}) |> fail(id, text)}
  end

  defp replayed(1), do: "1 action"
  defp replayed(n), do: "#{n} actions"

  # An action failed. The branch may have changed under the page (merged or discarded elsewhere, which is the usual
  # reason for `:not_open`), so it is read again first: if it is still on the board the error goes in its column, and
  # if it is gone there is no column to put it in, so it goes in the banner.
  defp fail(socket, id, error) do
    text = if is_binary(error), do: error, else: Exception.message(error)
    socket = refresh(socket, id)

    if find_column(socket, id) do
      update_column(socket, id, &%{&1 | notice: %{kind: :error, text: text}})
    else
      assign(socket, banner: {:error, text})
    end
  end

  defp actor(%{assigns: %{config: %{actor: nil}}}), do: nil

  defp actor(%{assigns: %{config: %{actor: {module, function}}}} = socket),
    do: apply(module, function, [socket])

  defp label(%{name: nil, id: id}), do: "branch #{Column.short_id(id)}"
  defp label(%{name: name}), do: "“#{name}”"

  # -- rendering ------------------------------------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="ramal-inspector" class="ramal">
      <style>
        <%= Phoenix.HTML.raw(Style.css()) %>
      </style>

      <header class="rl-head">
        <h1>Ramal</h1>
        <span class="rl-domain rl-data">{inspect(@config.domain)}</span>
        <div class="rl-tools">
          <button type="button" class="rl-btn" phx-click="reload">Reload</button>
          <button
            type="button"
            class="rl-btn"
            phx-click={theme(nil)}
            aria-label="Follow the system theme"
          >Auto</button>
          <button type="button" class="rl-btn" phx-click={theme("light")}>Light</button>
          <button type="button" class="rl-btn" phx-click={theme("dark")}>Dark</button>
        </div>
      </header>
      <div class="rl-baseline" aria-hidden="true"></div>

      <p :if={not @live?} class="rl-banner" role="status">
        <span>
          Live updates are off: add <code>{broadcaster_hint(@config.pubsub)}</code>
          to the supervision tree. Until then the page changes only after an action made here, or on Reload.
        </span>
      </p>

      <p :if={@banner} class="rl-banner" data-kind={elem(@banner, 0)} role="status">
        <span>{elem(@banner, 1)}</span>
        <button type="button" class="rl-btn" phx-click="dismiss">Dismiss</button>
      </p>

      <div class="rl-board">
        <.live_component
          :for={column <- @columns}
          module={BranchColumn}
          id={"branch-#{column.id}"}
          column={column}
          now={@now}
          confirm={confirm_for(@confirming, column.id)}
        />
        <p :if={@columns == []} class="rl-empty-board">
          No open or proposed branches in {inspect(@config.domain)}.
        </p>
      </div>
    </div>
    """
  end

  defp broadcaster_hint(pubsub), do: "{RamalLive.Broadcaster, pubsub: #{inspect(pubsub)}}"

  defp confirm_for({id, action}, id), do: action
  defp confirm_for(_confirming, _id), do: nil

  # The theme is a client-side attribute on the page's own root, so choosing one costs no round trip and touches nothing
  # of the host's. Without one, the stylesheet follows `prefers-color-scheme`.
  defp theme(nil), do: JS.remove_attribute("data-theme", to: "#ramal-inspector")
  defp theme(name), do: JS.set_attribute({"data-theme", name}, to: "#ramal-inspector")
end
