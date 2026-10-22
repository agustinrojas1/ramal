defmodule Ramal.Branch.Server do
  @moduledoc false
  # One process per open branch. It owns the branch struct (overlay and log) and serialises writes to it.
  #
  # Lifecycle: started on creation or on demand from storage; after `idle_timeout` without a call it persists
  # through the storage and stops; any public function given its id starts it again (see `Ramal.Branch.Server.call/2`).
  #
  # Verified against the locked OTP/Elixir:
  #   * `Process.flag(:max_heap_size, %{size: n, kill: true, error_logger: false})` kills the process with exit reason
  #     `:killed` when the heap exceeds `n` words. The kill cannot be trapped, so a separate watcher process notices it.
  #   * A GenServer reply tuple `{:reply, reply, state, timeout}` delivers `:timeout` only when no message arrived in
  #     `timeout` ms, which is how idle detection works without timers.
  use GenServer

  alias Ramal.{Branch, Error, Overlay, Supervisor, Telemetry}

  @max_attempts 6

  # -- client side --------------------------------------------------------------------------------------------------

  @doc false
  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}
  end

  @doc false
  def start_link({branch, config}) do
    GenServer.start_link(__MODULE__, {branch, config}, name: Supervisor.via(branch.id))
  end

  @doc """
  Starts the process for `branch` under the dynamic supervisor.
  Returns the pid of the process that holds the branch, which is an already running one if another caller won the race.
  """
  @spec start(Branch.t(), Supervisor.config()) :: {:ok, pid} | {:error, Error.t()}
  def start(branch, config) do
    case DynamicSupervisor.start_child(
           Supervisor.dynamic_supervisor(),
           {__MODULE__, {branch, config}}
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        {:error,
         Error.new(:storage, "could not start the branch process: #{inspect(reason)}", %{
           reason: reason
         })}
    end
  end

  @doc """
  Sends `request` to the process of branch `id`, starting it from storage when it is not running.

  A process can stop between the lookup and the call (idle unload). That is retried, so callers never see it.
  """
  @spec call(String.t(), term) :: term | {:error, Error.t()}
  def call(id, request), do: call(id, request, @max_attempts)

  defp call(id, request, attempts) do
    with {:ok, config} <- Supervisor.config(),
         {:ok, pid} <- ensure_started(id, config) do
      try do
        GenServer.call(pid, request)
      catch
        :exit, {reason, {GenServer, :call, _}} when reason in [:noproc, :normal, :shutdown] ->
          # The process stopped between the lookup and the call. The Registry drops its entry a moment after the
          # process dies, so wait for this pid to be gone before looking again, or the retry finds the same corpse.
          await_down(pid)
          if attempts > 1, do: call(id, request, attempts - 1), else: stopping_error(id)

        :exit, {:killed, {GenServer, :call, _}} ->
          # The watcher marks it too, but asynchronously; mark here so the very next call already sees it.
          Supervisor.mark_too_large(id)
          {:error, too_large_error(id)}
      end
    end
  end

  defp await_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      100 -> Process.demonitor(ref, [:flush])
    end

    # One scheduler tick for the Registry to process the exit of the process it monitors.
    Process.sleep(1)
  end

  defp stopping_error(id) do
    {:error,
     Error.new(:storage, "branch #{inspect(id)} kept stopping while being called", %{id: id})}
  end

  @doc false
  @spec ensure_started(String.t(), Supervisor.config()) :: {:ok, pid} | {:error, Error.t()}
  def ensure_started(id, config) do
    cond do
      pid = Supervisor.whereis(id) ->
        {:ok, pid}

      Supervisor.too_large?(id) ->
        {:error, too_large_error(id)}

      true ->
        with {:ok, branch} <- config.storage.fetch(id, config.storage_config) do
          start(branch, config)
        end
    end
  end

  @doc false
  def too_large_error(id) do
    Error.new(
      :branch_too_large,
      "branch #{inspect(id)} exceeded max_heap_size and was stopped; its last persisted state remains, discard it or raise the limit",
      %{id: id}
    )
  end

  @doc "The branch struct as the process holds it."
  @spec get(String.t()) :: {:ok, Branch.t()} | {:error, Error.t()}
  def get(id), do: call(id, :get)

  @doc """
  The overlay slice of one resource, for read patching. Only that slice crosses the process boundary, not the whole
  overlay. Rejected unless the branch is open.
  """
  @spec slice(String.t(), module) :: {:ok, Overlay.slice()} | {:error, Error.t()}
  def slice(id, resource), do: call(id, {:slice, resource})

  @doc """
  Replaces the branch with the result of `fun`, which runs inside the process, so concurrent updates are serialised.
  `fun` receives the branch and returns the new branch. Rejected unless the branch is open.
  """
  @spec update(String.t(), (Branch.t() -> Branch.t())) :: {:ok, Branch.t()} | {:error, Error.t()}
  def update(id, fun) when is_function(fun, 1), do: call(id, {:update, fun})

  @doc """
  Like `update/2` for a function that also has something to tell the caller: `fun` returns `{reply, branch}` and the
  caller gets `{:ok, reply, branch}`. Write capture uses it to learn how to undo the write it just made.
  """
  @spec write(String.t(), (Branch.t() -> {reply, Branch.t()})) ::
          {:ok, reply, Branch.t()} | {:error, Error.t()}
        when reply: term
  def write(id, fun) when is_function(fun, 1), do: call(id, {:write, fun})

  @doc """
  Discards the branch: its process persists the discarded state and stops.

  A branch whose process was killed for being too large has no process to ask, so it is discarded from its last
  persisted state instead, which also clears the too-large mark.
  """
  @spec discard(String.t()) :: :ok | {:error, Error.t()}
  def discard(id) do
    with {:ok, config} <- Supervisor.config() do
      if Supervisor.too_large?(id) and is_nil(Supervisor.whereis(id)) do
        discard_cold(id, config)
      else
        call(id, :discard)
      end
    end
  end

  defp discard_cold(id, config) do
    with {:ok, branch} <- config.storage.fetch(id, config.storage_config),
         discarded = Branch.discard(branch),
         :ok <- config.storage.put(discarded, config.storage_config) do
      Supervisor.clear_too_large(id)
      Telemetry.branch(:discard, discarded)
      :ok
    end
  end

  # -- server side --------------------------------------------------------------------------------------------------

  @impl true
  def init({branch, config}) do
    # Trapping exits makes the supervisor's shutdown call terminate/2, which persists the branch.
    Process.flag(:trap_exit, true)
    Process.flag(:max_heap_size, %{size: config.max_heap_size, kill: true, error_logger: false})

    watch(branch)
    Telemetry.branch(:load, branch)

    {:ok, %{branch: branch, config: config, stop: nil}, config.idle_timeout}
  end

  @impl true
  def handle_call(:get, _from, state), do: reply(state, {:ok, state.branch})

  def handle_call({:slice, resource}, _from, state) do
    if Branch.open?(state.branch) do
      reply(state, {:ok, Overlay.slice(state.branch.overlay, resource)})
    else
      reply(state, {:error, not_open(state.branch)})
    end
  end

  def handle_call({:update, fun}, _from, state) do
    if Branch.open?(state.branch) do
      branch = fun.(state.branch)
      reply(%{state | branch: branch}, {:ok, branch})
    else
      reply(state, {:error, not_open(state.branch)})
    end
  end

  def handle_call({:write, fun}, _from, state) do
    if Branch.open?(state.branch) do
      {reply, branch} = fun.(state.branch)
      reply(%{state | branch: branch}, {:ok, reply, branch})
    else
      reply(state, {:error, not_open(state.branch)})
    end
  end

  def handle_call(:discard, _from, %{branch: %{status: status}} = state)
      when status in [:open, :discarded] do
    branch = Branch.discard(state.branch)

    case persist(branch, state.config) do
      :ok ->
        Telemetry.branch(:discard, branch)
        {:stop, :normal, :ok, %{state | branch: branch, stop: :discarded}}

      {:error, _} = error ->
        reply(state, error)
    end
  end

  def handle_call(:discard, _from, state), do: reply(state, {:error, not_open(state.branch)})

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, %{state | stop: :idle}}
  def handle_info(_message, state), do: {:noreply, state, state.config.idle_timeout}

  @impl true
  def terminate(_reason, %{stop: :discarded}), do: :ok

  def terminate(_reason, %{branch: branch, config: config, stop: stop}) do
    # Persist before announcing the unload, so an observer who sees the event can already rehydrate the branch.
    persist(branch, config)
    Telemetry.branch(:unload, branch, %{reason: stop || :shutdown})
  end

  defp reply(state, reply), do: {:reply, reply, state, state.config.idle_timeout}

  defp not_open(branch) do
    Error.new(:not_open, "branch #{inspect(branch.id)} is #{branch.status}, not open", %{
      id: branch.id,
      status: branch.status
    })
  end

  defp persist(branch, config), do: config.storage.put(branch, config.storage_config)

  # The kill from max_heap_size is untrappable, so the dying process cannot report it. A watcher process, unlinked,
  # monitors it instead. Exit reason :killed is also what an external `Process.exit(pid, :kill)` produces; such a
  # kill is reported as too_large as well, which is documented as a limit of the detection.
  defp watch(branch) do
    server = self()
    id = branch.id
    summary = Map.take(branch, [:id, :domain])

    spawn(fn ->
      ref = Process.monitor(server)

      receive do
        {:DOWN, ^ref, :process, ^server, :killed} ->
          Supervisor.mark_too_large(id)
          Telemetry.branch(:too_large, summary)

        {:DOWN, ^ref, :process, ^server, _reason} ->
          :ok
      end
    end)
  end
end
