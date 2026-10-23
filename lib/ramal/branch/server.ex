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

  alias Ramal.{Branch, Error, Overlay, Prefilter, Supervisor, Telemetry}

  @max_attempts 6

  # An overlay with fewer entries than this is scanned for each read. Grouping it by resource costs several scans, so it
  # is only done for a large overlay that two reads in a row found unchanged (see index/1).
  @index_min 5_000

  # How long a process started for a handed-over branch waits for it (see start_forked/2).
  @handoff_timeout 5_000

  # -- client side --------------------------------------------------------------------------------------------------

  @doc false
  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}
  end

  @doc false
  def start_link({:handoff, id, _ref, _config} = arg) do
    GenServer.start_link(__MODULE__, arg, name: Supervisor.via(id))
  end

  def start_link({branch, config}) do
    GenServer.start_link(__MODULE__, {branch, config}, name: Supervisor.via(branch.id))
  end

  @doc """
  Starts the process for `branch` under the dynamic supervisor.
  Returns the pid of the process that holds the branch, which is an already running one if another caller won the race.
  """
  @spec start(Branch.t(), Supervisor.config()) :: {:ok, pid} | {:error, Error.t()}
  def start(branch, config), do: start_child({branch, config}, & &1)

  @doc """
  Like `start/2`, for a branch the caller holds that is large: the process starts empty and the caller sends it the
  branch in one message. `start/2` puts the branch in the child specification, so it is copied into the dynamic
  supervisor and again into the new process; here it is copied once, which is what a fork of a large branch costs
  least. The process takes no call before it has the branch (it waits for it in `handle_continue/2`, which runs before
  the first call), and stops if the branch does not arrive.
  """
  @spec start_forked(Branch.t(), Supervisor.config()) :: {:ok, pid} | {:error, Error.t()}
  def start_forked(branch, config) do
    ref = make_ref()

    start_child({:handoff, branch.id, ref, config}, fn pid ->
      send(pid, {:handoff, ref, branch})
      pid
    end)
  end

  defp start_child(arg, started) do
    case DynamicSupervisor.start_child(Supervisor.dynamic_supervisor(), {__MODULE__, arg}) do
      {:ok, pid} ->
        {:ok, started.(pid)}

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
  The status of the branch and nothing else. `get/1` copies the whole branch (overlay, log and base) to the caller, which
  is what a caller that only needs to know whether the branch is open must not pay for.
  """
  @spec status(String.t()) :: {:ok, Branch.status()} | {:error, Error.t()}
  def status(id), do: call(id, :status)

  @doc """
  The changes of the branch (`Ramal.Branch.diff/2`), computed inside the process. Only the changes cross the process
  boundary, not the overlay, the log and the base `get/1` copies, which is most of what a diff of a large branch cost.
  Like `get/1` it answers whatever the status of the branch is, so a rejected or proposed branch can still be reviewed.
  """
  @spec diff(String.t(), keyword) :: {:ok, [Ramal.Change.t()]} | {:error, Error.t()}
  def diff(id, opts), do: call(id, {:diff, opts})

  @doc """
  The overlay slice of one resource, for read patching. Only that slice crosses the process boundary, not the whole
  overlay. Rejected unless the branch is open.
  """
  @spec slice(String.t(), module) :: {:ok, Overlay.slice()} | {:error, Error.t()}
  def slice(id, resource), do: call(id, {:slice, resource})

  @doc """
  The primary keys of the overlay entries of `resource`, for a caller that needs which rows the branch touched and not
  what it put in them (`Ramal.aggregate/4`). Rejected unless the branch is open.
  """
  @spec keys(String.t(), module) :: {:ok, [term]} | {:error, Error.t()}
  def keys(id, resource), do: call(id, {:keys, resource})

  @doc """
  Whether the branch holds any overlay entry for `resource`. A read asks it first, because without one the read needs
  nothing else from the process. Rejected unless the branch is open.
  """
  @spec overlay?(String.t(), module) :: {:ok, boolean} | {:error, Error.t()}
  def overlay?(id, resource), do: call(id, {:overlay?, resource})

  @doc """
  What a read of `resource` needs from the overlay (`Ramal.Overlay.select/4`) and the number of entries the resource has.

  The read returned `base_keys` from the database, and `plan` is `Ramal.Prefilter.compile/1` of its filter. Only the
  entries that can change the result cross the process boundary, so the cost of a read follows what it returns and not
  the size of the overlay. Rejected unless the branch is open.
  """
  @spec select(String.t(), module, [term], Prefilter.t()) ::
          {:ok, Overlay.slice(), non_neg_integer} | {:error, Error.t()}
  def select(id, resource, base_keys, plan) do
    with {:ok, {slice, count}} <- call(id, {:select, resource, base_keys, plan}) do
      {:ok, slice, count}
    end
  end

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
  @spec fingerprints(String.t(), Enumerable.t()) :: :ok | {:error, Error.t()}
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
  def init({:handoff, _id, ref, config}) do
    flags(config)
    {:ok, process_state(nil, config), {:continue, {:handoff, ref}}}
  end

  def init({branch, config}) do
    flags(config)
    watch(branch)
    Telemetry.branch(:load, branch)

    {:ok, process_state(branch, config), config.idle_timeout}
  end

  defp flags(config) do
    # Trapping exits makes the supervisor's shutdown call terminate/2, which persists the branch.
    Process.flag(:trap_exit, true)
    Process.flag(:max_heap_size, %{size: config.max_heap_size, kill: true, error_logger: false})
  end

  defp process_state(branch, config),
    do: %{
      branch: branch,
      config: config,
      stop: nil,
      merging: nil,
      persisted: false,
      index: nil,
      seen: nil
    }

  @impl true
  def handle_continue({:handoff, ref}, %{config: config} = state) do
    receive do
      {:handoff, ^ref, branch} ->
        watch(branch)
        Telemetry.branch(:load, branch)
        {:noreply, %{state | branch: branch}, config.idle_timeout}
    after
      @handoff_timeout -> {:stop, :normal, %{state | stop: :unclaimed}}
    end
  end

  @impl true
  def handle_call(:get, _from, state), do: reply(state, {:ok, state.branch})

  def handle_call(:status, _from, state), do: reply(state, {:ok, state.branch.status})

  def handle_call({:diff, opts}, _from, state), do: reply(state, Branch.diff(state.branch, opts))

  def handle_call({:slice, resource}, _from, state) do
    read_overlay(state, fn overlay, index ->
      if index, do: Map.get(index, resource, %{}), else: Overlay.slice(overlay, resource)
    end)
  end

  def handle_call({:keys, resource}, _from, state) do
    read_overlay(state, fn overlay, index ->
      if index,
        do: index |> Map.get(resource, %{}) |> Map.keys(),
        else: Overlay.keys(overlay, resource)
    end)
  end

  def handle_call({:overlay?, resource}, _from, state) do
    read_overlay(state, fn overlay, index ->
      if index, do: is_map_key(index, resource), else: Overlay.any?(overlay, resource)
    end)
  end

  def handle_call({:select, resource, base_keys, plan}, _from, state) do
    possible? = &Prefilter.possible?(plan, &1)

    read_overlay(state, fn overlay, index ->
      if index,
        do: index |> Map.get(resource, %{}) |> Overlay.select_slice(base_keys, possible?),
        else: Overlay.select(overlay, resource, base_keys, possible?)
    end)
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
  # An idle branch unloads only once its state is safe in storage. If the write fails, stopping would lose the overlay
  # and the log (terminate/2 cannot report the failure to anyone), so the process stays up and tries again at the next
  # idle timeout.
  def handle_info(:timeout, %{branch: branch, config: config} = state) do
    case persist(branch, config) do
      :ok ->
        {:stop, :normal, %{state | stop: :idle, persisted: true}}

      {:error, error} ->
        Telemetry.branch(:persist_failed, branch, %{reason: :idle, error: error})
        {:noreply, state, timeout(state)}
    end
  end

  # The merging process died without finishing: release the claim so the branch can be merged again.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{merging: ref} = state) do
    state = %{state | merging: nil}
    {:noreply, state, timeout(state)}
  end

  def handle_info(_message, state), do: {:noreply, state, timeout(state)}

  @impl true
  # A process that never received its branch has nothing to persist; storage already holds the fork.
  def terminate(_reason, %{branch: nil}), do: :ok
  def terminate(_reason, %{stop: stop}) when stop in [:discarded, :merged, :rejected], do: :ok

  def terminate(_reason, %{branch: branch, config: config, stop: stop, persisted: persisted}) do
    # Persist before announcing the unload, so an observer who sees the event can already rehydrate the branch. On a
    # shutdown there is no process left to keep, so a failed write is reported instead of announced as an unload.
    with false <- persisted,
         {:error, error} <- persist(branch, config) do
      Telemetry.branch(:persist_failed, branch, %{reason: stop || :shutdown, error: error})
    else
      _persisted -> Telemetry.branch(:unload, branch, %{reason: stop || :shutdown})
    end
  end

  defp reply(state, reply), do: {:reply, reply, state, timeout(state)}

  # A branch being merged must not unload: the merge would lose its claim.
  defp timeout(%{merging: nil, config: config}), do: config.idle_timeout
  defp timeout(_state), do: :infinity

  defp usable?(state), do: Branch.open?(state.branch) and state.merging == nil

  # Answers a read of the overlay with `fun.(overlay, index)`, where `index` is the overlay grouped by resource
  # (`Ramal.Overlay.index/1`) or `nil` when it is scanned instead.
  defp read_overlay(state, fun) do
    if usable?(state) do
      {index, state} = index(state)
      reply(state, {:ok, fun.(state.branch.overlay, index)})
    else
      reply(state, {:error, unavailable(state)})
    end
  end

  # A scan of the overlay costs what the overlay holds, whichever resource the read is for. For a large overlay the
  # process groups it by resource, once it has seen two reads of the same overlay in a row: a write, which changes the
  # overlay, throws the index away, so a branch that alternates writes and reads keeps scanning and never pays for an
  # index. `==` finds a changed overlay quickly (the maps share most of their structure) and an identical one at once.
  defp index(%{branch: %{overlay: overlay}} = state) when map_size(overlay) < @index_min,
    do: {nil, %{state | index: nil, seen: nil}}

  defp index(%{branch: %{overlay: overlay}, index: {indexed, by_resource}} = state)
       when indexed == overlay,
       do: {by_resource, state}

  defp index(%{branch: %{overlay: overlay}, seen: seen} = state) when seen == overlay do
    by_resource = Overlay.index(overlay)
    {by_resource, %{state | index: {overlay, by_resource}, seen: nil}}
  end

  defp index(%{branch: %{overlay: overlay}} = state),
    do: {nil, %{state | index: nil, seen: overlay}}

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
