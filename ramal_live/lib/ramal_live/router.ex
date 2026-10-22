defmodule RamalLive.Router do
  @moduledoc """
  The router macro that mounts the inspector.

  Import it in the host's router and put the macro where the page should live, inside the host's own `scope`, pipeline
  and `live_session`, so the page gets the host's root layout, its LiveView socket and its JavaScript, and goes through
  the host's authentication:

      import RamalLive.Router

      scope "/admin", MyAppWeb do
        pipe_through [:browser, :require_admin]

        live_session :admin, on_mount: [{MyAppWeb.UserAuth, :ensure_admin}] do
          ramal_inspector "/ramal", domain: MyApp.Farm, pubsub: MyApp.PubSub
        end
      end

  Why it does not open a `live_session` of its own, as `Phoenix.LiveDashboard` does: that would give the page a root
  layout and a socket path other than the host's, and an asset pipeline to carry the JavaScript. See ADR 0014.

  The inspector can merge, approve, reject and discard any branch of the domain. Put it behind the host's own
  authorization; nothing in `RamalLive` checks who is looking.

  ## Options

    * `:domain` - the Ash domain whose branches are shown. Required.
    * `:pubsub` - the host's `Phoenix.PubSub` name, which the page subscribes to for live updates. Required, and the same
      one given to `RamalLive.Broadcaster`.
    * `:actor` - `{module, function}`, called as `module.function(socket)` when someone merges, approves or rejects, and
      returning the actor (or `nil`). The actor is recorded as `:decided_by` and, for merge and approve, replays the log
      as that actor (`:actor` of `Ramal.merge/2`). Default: none, so a merge replays each write as the actor it was
      captured with.
    * `:debounce` - milliseconds to wait, after a branch changes, before the page reads it again. A branch that writes
      in a loop causes one read per window instead of one per write. `0` reads at once. Default: `50`.

  ## Example

      ramal_inspector "/ramal", domain: MyApp.Farm, pubsub: MyApp.PubSub, actor: {MyAppWeb.Inspector, :actor}
  """

  @options [:domain, :pubsub, :actor, :debounce]
  @default_debounce 50

  @doc """
  Mounts the inspector at `path`. See the module doc for the options.

  ## Example

      ramal_inspector "/ramal", domain: MyApp.Farm, pubsub: MyApp.PubSub
  """
  defmacro ramal_inspector(path, opts) do
    opts = Macro.expand_literals(opts, %{__CALLER__ | function: {:ramal_inspector, 2}})

    quote bind_quoted: [path: path, opts: opts] do
      config = RamalLive.Router.__config__!(opts)

      scope path, alias: false, as: false do
        import Phoenix.LiveView.Router, only: [live: 4]

        # The page finds its configuration again through the route's metadata (see `RamalLive.InspectorLive`).
        live "/", RamalLive.InspectorLive, :index,
          as: :ramal_inspector,
          metadata: %{ramal_inspector: config}
      end
    end
  end

  @doc false
  @spec __config__!(keyword) :: %{
          domain: module,
          pubsub: module,
          actor: {module, atom} | nil,
          debounce: non_neg_integer
        }
  def __config__!(opts) when is_list(opts) do
    case Keyword.keys(opts) -- @options do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "ramal_inspector: unknown options #{inspect(unknown)}, expected #{inspect(@options)}"
    end

    %{
      domain: atom!(opts, :domain),
      pubsub: atom!(opts, :pubsub),
      actor: actor!(opts[:actor]),
      debounce: debounce!(Keyword.get(opts, :debounce, @default_debounce))
    }
  end

  def __config__!(other) do
    raise ArgumentError,
          "ramal_inspector: expected a keyword list of options, got: #{inspect(other)}"
  end

  defp atom!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_atom(value) and not is_nil(value) ->
        value

      {:ok, value} ->
        raise ArgumentError,
              "ramal_inspector: #{inspect(key)} must be a module, got: #{inspect(value)}"

      :error ->
        raise ArgumentError, "ramal_inspector: the #{inspect(key)} option is required"
    end
  end

  defp actor!(nil), do: nil
  defp actor!({module, function} = mf) when is_atom(module) and is_atom(function), do: mf

  defp actor!(other) do
    raise ArgumentError,
          "ramal_inspector: :actor must be {module, function}, got: #{inspect(other)}"
  end

  defp debounce!(ms) when is_integer(ms) and ms >= 0, do: ms

  defp debounce!(other) do
    raise ArgumentError,
          "ramal_inspector: :debounce must be a non-negative integer, got: #{inspect(other)}"
  end
end
