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
          ramal_inspector "/ramal", domain: MyApp.Farm, pubsub: MyApp.PubSub, actor: {MyAppWeb.Inspector, :actor}
        end
      end

  Why it does not open a `live_session` of its own, as `Phoenix.LiveDashboard` does: that would give the page a root
  layout and a socket path other than the host's, and an asset pipeline to carry the JavaScript. See ADR 0015.

  The inspector can merge, approve, reject, discard and fork any branch of the domain. Put it behind the host's own
  authorization; nothing in `RamalLive` checks who is looking. Two mounts in one `live_session` share its authorization,
  because the page reads its options from the route that the URL the browser joins with matches: give mounts that differ
  in who may use them a `live_session` each. See `SECURITY.md` for the full list.

  ## Options

    * `:domain` - the Ash domain whose branches are shown. Required.
    * `:pubsub` - the host's `Phoenix.PubSub` name, which the page subscribes to for live updates. Required, and the same
      one given to `RamalLive.Broadcaster`.
    * `:actor` - `{module, function}`. Required. Called as `module.function(socket)` when someone forks, merges,
      discards, approves or rejects, and returning the actor, or `nil` when nobody is signed in. The actor is recorded as
      `:decided_by` and, for merge and approve, replays the log as that actor (`:actor` of `Ramal.merge/2`). When it
      returns `nil` the page refuses every action. It is required because a page that acts for nobody lets whoever
      reaches the route merge every branch with the actors the writes were captured with, and leaves the decision with no
      decider (ADR 0016). A router that leaves it out does not compile, and a route mounted without it (with `live`)
      raises when the page opens.
    * `:owner` - `{module, function}`. Optional, off by default. Called as `module.function(actor)` with what `:actor`
      returned, and returning the owner of that actor: the term the host passes as `owner:` to `Ramal.branch/2`. When
      given, the page shows only the branches whose owner is that term (`Ramal.list/2` with `owner:`), forks create
      branches owned by it, and every other branch is neither listed, nor refreshed when it changes, nor acted on. When
      the actor is `nil`, or the function returns `nil`, the page shows nothing and refuses every action, because `nil`
      would match the branches that have no owner. Without the option the page shows every branch of the domain, as
      before. This is for giving each user their own board; it does not stop code that holds a branch id from using it
      (ADR 0018). Mounts that differ in `:owner` still share the authorization of their `live_session`.
    * `:debounce` - milliseconds to wait, after a branch changes, before the page reads it again. A branch that writes
      in a loop causes one read per window instead of one per write. `0` reads at once. Default: `50`.

  ## Example

      ramal_inspector "/ramal", domain: MyApp.Farm, pubsub: MyApp.PubSub, actor: {MyAppWeb.Inspector, :actor}
  """

  @options [:domain, :pubsub, :actor, :owner, :debounce]
  @default_debounce 50

  @doc """
  Mounts the inspector at `path`. See the module doc for the options.

  ## Example

      ramal_inspector "/ramal", domain: MyApp.Farm, pubsub: MyApp.PubSub, actor: {MyAppWeb.Inspector, :actor}
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
          actor: {module, atom},
          owner: {module, atom} | nil,
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
      actor: actor!(Keyword.fetch(opts, :actor)),
      owner: owner!(Keyword.get(opts, :owner)),
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

  defp actor!({:ok, {module, function} = mf}) when is_atom(module) and is_atom(function), do: mf

  defp actor!({:ok, other}) do
    raise ArgumentError,
          "ramal_inspector: :actor must be {module, function}, got: #{inspect(other)}"
  end

  defp actor!(:error) do
    raise ArgumentError,
          "ramal_inspector: the :actor option is required. Pass {module, function}: the page calls " <>
            "module.function(socket) and uses what it returns as the actor of a merge or a decision, " <>
            "or refuses to act when it returns nil. Without it, anyone who reaches the route would merge " <>
            "every branch of the domain as nobody in particular. See SECURITY.md"
  end

  defp owner!(nil), do: nil
  defp owner!({module, function} = mf) when is_atom(module) and is_atom(function), do: mf

  defp owner!(other) do
    raise ArgumentError,
          "ramal_inspector: :owner must be {module, function} or left out, got: #{inspect(other)}"
  end

  defp debounce!(ms) when is_integer(ms) and ms >= 0, do: ms

  defp debounce!(other) do
    raise ArgumentError,
          "ramal_inspector: :debounce must be a non-negative integer, got: #{inspect(other)}"
  end
end
