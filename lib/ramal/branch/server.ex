defmodule Ramal.Branch.Server do
  @moduledoc false
  # One process per open branch. It owns the branch struct (overlay and log) and serialises writes to it.
  #
  # Lifecycle: started on creation or on demand from storage; after `idle_timeout` without a call it persists
  # through the storage and stops; any public function given its id starts it again (see call/2 below).
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
  Records the fingerprints of base rows a read returned (`Ramal.Branch.put_fingerprints/2`). Rejected unless the
  branch is open.
  """
  @spec fingerprints(String.t(), map) :: :ok | {:error, Error.t()}
  def fingerprints(id, fingerprints) do
    with {:ok, :ok, _} <-
           write(id, fn branch -> {:ok, Branch.put_fingerprints(branch, fingerprints)} end) do
      :ok
    end
  end

  @doc """
  Like `update/2` for a function that also has something to tell the caller: `fun` returns `{reply, branch}` and the
  caller gets `{:ok, reply, %{id: id, domain: domain}}`, not the whole branch, so a write does not copy the overlay
  back to the caller. Write capture uses it to learn how to undo the write it just made.
  """
  @spec write(String.t(), (Branch.t() -> {reply, Branch.t()})) ::
          {:ok, reply, %{id: String.t(), domain: module}} | {:error, Error.t()}
        when reply: term
  def write(id, fun) when is_function(fun, 1), do: call(id, {:write, fun})

  @doc """
  Claims the branch for a merge and returns it. While claimed the branch refuses reads of its overlay, writes, discards
  and a second claim, so two merges cannot replay the same log. The claim ends with `finish_merge/2`, or when the
  caller dies.
  """
  @spec begin_merge(String.t(), :open | :proposed) :: {:ok, Branch.t()} | {:error, Error.t()}
  def begin_merge(id, from \\ :open) when from in [:open, :proposed],
    do: call(id, {:begin_merge, from})

  @doc """
  Ends the claim of `begin_merge/1`. `:merged` applies `annotate` to the branch (an approval records its decision
  there), marks it merged, persists it and stops the process; `:aborted` only releases the claim.
  """
  @spec finish_merge(String.t(), :merged | :aborted, (Branch.t() -> Branch.t())) ::
          :ok | {:error, Error.t()}
  def finish_merge(id, outcome, annotate \\ & &1)
      when outcome in [:merged, :aborted] and is_function(annotate, 1),
      do: call(id, {:finish_merge, outcome, annotate})

  @doc """
  Freezes an open branch as a proposal: `fun` turns the branch into the proposed one, which is persisted before the
  call returns, so a proposal survives a restart. The process stays up; the branch refuses writes and reads because it
  is no longer open.
  """
  @spec propose(String.t(), (Branch.t() -> Branch.t())) :: {:ok, Branch.t()} | {:error, Error.t()}
  def propose(id, fun) when is_function(fun, 1), do: call(id, {:propose, fun})

  @doc """
  Rejects a proposed branch: `fun` records the decision, the rejected branch is persisted and the process stops. The
  overlay and log are kept, so the rejected diff can still be read.
  """
  @spec reject(String.t(), (Branch.t() -> Branch.t())) :: {:ok, Branch.t()} | {:error, Error.t()}
  def reject(id, fun) when is_function(fun, 1), do: call(id, {:reject, fun})

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

    {:ok, %{branch: branch, config: config, stop: nil, merging: nil}, config.idle_timeout}
  end

  @impl true
  def handle_call(:get, _from, state), do: reply(state, {:ok, state.branch})

  def handle_call({:slice, resource}, _from, state) do
    if usable?(state) do
      reply(state, {:ok, Overlay.slice(state.branch.overlay, resource)})
    else
      reply(state, {:error, unavailable(state)})
    end
  end

  def handle_call({:update, fun}, _from, state) do
    if usable?(state) do
      branch = fun.(state.branch)
      reply(%{state | branch: branch}, {:ok, branch})
    else
      reply(state, {:error, unavailable(state)})
    end
  end

  def handle_call({:write, fun}, _from, state) do
    if usable?(state) do
      {reply, branch} = fun.(state.branch)
      reply(%{state | branch: branch}, {:ok, reply, %{id: branch.id, domain: branch.domain}})
    else
      reply(state, {:error, unavailable(state)})
    end
  end

  def handle_call({:begin_merge, from}, {pid, _tag}, state) do
    if state.merging == nil and state.branch.status == from do
      ref = Process.monitor(pid)
      reply(%{state | merging: ref}, {:ok, state.branch})
    else
      reply(state, {:error, unavailable(state, from)})
    end
  end

  def handle_call({:finish_merge, outcome, annotate}, _from, %{merging: ref} = state)
      when ref != nil do
    Process.demonitor(ref, [:flush])
    state = %{state | merging: nil}

    case outcome do
      :aborted ->
        reply(state, :ok)

      :merged ->
        branch = %{annotate.(state.branch) | status: :merged}

        case persist(branch, state.config) do
          :ok -> {:stop, :normal, :ok, %{state | branch: branch, stop: :merged}}
          {:error, _} = error -> reply(state, error)
        end
    end
  end

  def handle_call({:finish_merge, _outcome, _annotate}, _from, state), do: reply(state, :ok)

  def handle_call({:propose, fun}, _from, state) do
    if usable?(state) do
      branch = fun.(state.branch)

      case persist(branch, state.config) do
        :ok ->
          Telemetry.branch(:propose, branch)
          reply(%{state | branch: branch}, {:ok, branch})

        {:error, _} = error ->
          reply(state, error)
      end
    else
      reply(state, {:error, unavailable(state)})
    end
  end

  def handle_call({:reject, fun}, _from, %{merging: nil, branch: %{status: :proposed}} = state) do
    branch = fun.(state.branch)

    case persist(branch, state.config) do
      :ok ->
        Telemetry.branch(:reject, branch)
        {:stop, :normal, {:ok, branch}, %{state | branch: branch, stop: :rejected}}

      {:error, _} = error ->
        reply(state, error)
    end
  end

  def handle_call({:reject, _fun}, _from, state),
    do: reply(state, {:error, unavailable(state, :proposed)})

  # A proposer can withdraw a proposal that has not been decided: it is discarded like an open branch.
  def handle_call(:discard, _from, %{merging: nil, branch: %{status: status}} = state)
      when status in [:open, :proposed, :discarded] do
    branch = Branch.discard(state.branch)

    case persist(branch, state.config) do
      :ok ->
        Telemetry.branch(:discard, branch)
        {:stop, :normal, :ok, %{state | branch: branch, stop: :discarded}}

      {:error, _} = error ->
        reply(state, error)
    end
  end

  def handle_call(:discard, _from, state), do: reply(state, {:error, unavailable(state)})

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, %{state | stop: :idle}}

  # The merging process died without finishing: release the claim so the branch can be merged again.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{merging: ref} = state) do
    state = %{state | merging: nil}
    {:noreply, state, timeout(state)}
  end

  def handle_info(_message, state), do: {:noreply, state, timeout(state)}

  @impl true
  def terminate(_reason, %{stop: stop}) when stop in [:discarded, :merged, :rejected], do: :ok

  def terminate(_reason, %{branch: branch, config: config, stop: stop}) do
    # Persist before announcing the unload, so an observer who sees the event can already rehydrate the branch.
    persist(branch, config)
    Telemetry.branch(:unload, branch, %{reason: stop || :shutdown})
  end

  defp reply(state, reply), do: {:reply, reply, state, timeout(state)}

  # A branch being merged must not unload: the merge would lose its claim.
  defp timeout(%{merging: nil, config: config}), do: config.idle_timeout
  defp timeout(_state), do: :infinity

  defp usable?(state), do: Branch.open?(state.branch) and state.merging == nil

  defp unavailable(state, wanted \\ :open)

  defp unavailable(%{merging: nil, branch: branch}, wanted), do: not_open(branch, wanted)

  defp unavailable(%{branch: branch}, _wanted) do
    Error.new(:not_open, "branch #{inspect(branch.id)} is being merged", %{
      id: branch.id,
      status: :merging
    })
  end

  defp not_open(branch, wanted) do
    Error.new(:not_open, "branch #{inspect(branch.id)} is #{branch.status}, not #{wanted}", %{
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
