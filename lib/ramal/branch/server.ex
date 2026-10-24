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

  @typedoc "Changes with every change of the branch, and with every start of its process."
  @type version :: {reference, non_neg_integer}

  # How long a caller waits for the process. A read or a write only touches memory, so five seconds is generous. A call
  # that persists the whole branch through the storage (finish_merge, propose, reject, discard) can take as long as the
  # storage does for a large branch, and for finish_merge the merge has already committed by then, so it waits longer.
  @call_timeout 5_000
  @persist_timeout 60_000

  # An overlay with fewer entries than this is scanned for each read. Grouping it by resource costs several scans, so it
  # is only done for a large overlay that two reads in a row found unchanged (see index/1).
  @index_min 5_000

  # How long a process started for a handed-over branch waits for it (see start_forked/2).
  @handoff_timeout 5_000

  # A durable branch stores a snapshot, which deletes the deltas it covers, after this many appends (ADR 0048). The
  # chain is what a load after a crash has to apply, and the snapshot is what a compaction writes, so the number trades
  # the first against the second: at 100 a load applies at most 100 deltas and a branch of a thousand rows writes its
  # snapshot once per hundred actions.
  @compact_every 100

  # How long a merge or a proposal waits for the actions running in the branch to end. Less than @call_timeout, so the
  # process answers before its caller gives up and a claim is never granted to a caller that stopped waiting.
  @wait_timeout 4_000

  # -- client side --------------------------------------------------------------------------------------------------

  @doc false
  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}
  end

  @doc false
  def start_link({:handoff, id, _ref, config} = arg) do
    GenServer.start_link(__MODULE__, arg, name: Supervisor.via(id, config))
  end

  def start_link({:load, id, config} = arg) do
    GenServer.start_link(__MODULE__, arg, name: Supervisor.via(id, config))
  end

  def start_link({:scratch, branch, config} = arg) do
    GenServer.start_link(__MODULE__, arg, name: Supervisor.via(branch.id, config))
  end

  def start_link({branch, config}) do
    GenServer.start_link(__MODULE__, {branch, config}, name: Supervisor.via(branch.id, config))
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

  @doc """
  Starts a process for `branch` that is never stored and never unloads: the place where a nested merge replays the
  fork's writes (`Ramal.Merge`, ADR 0043). Stop it with `stop_scratch/1`.
  """
  @spec start_scratch(Branch.t(), Supervisor.config()) :: {:ok, pid} | {:error, Error.t()}
  def start_scratch(branch, config), do: start_child({:scratch, branch, config}, & &1)

  @doc "Stops the process `start_scratch/2` started, and forgets its marks. Nothing was stored, so nothing is written."
  @spec stop_scratch(String.t()) :: :ok
  def stop_scratch(id) do
    case Registry.lookup(Supervisor.registry(), id) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _already_gone -> :ok
        end

      [] ->
        :ok
    end

    Supervisor.clear_too_large(id)
    Supervisor.clear_running(id)
  end

  defp start_child(arg, started) do
    case DynamicSupervisor.start_child(Supervisor.dynamic_supervisor(), {__MODULE__, arg}) do
      {:ok, pid} ->
        {:ok, started.(pid)}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      # A process that could not claim its branch (cluster mode) stops with the storage's error.
      {:error, %Error{} = error} ->
        {:error, error}

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
  def call(id, request), do: call(id, request, @call_timeout, @max_attempts)

  # Calls that persist the whole branch wait `@persist_timeout`, the others `@call_timeout`. A timeout is returned as
  # `{:error, %Ramal.Error{reason: :timeout}}`; the process may still carry the request out afterwards.
  defp persisting_call(id, request), do: call(id, request, @persist_timeout, @max_attempts)

  defp call(id, request, timeout, attempts) do
    with {:ok, config} <- Supervisor.config(),
         {:ok, pid} <- ensure_started(id, config) do
      try do
        GenServer.call(pid, request, timeout)
      catch
        :exit, {reason, {GenServer, :call, _}} when reason in [:noproc, :normal, :shutdown] ->
          # The process stopped between the lookup and the call. The Registry drops its entry a moment after the
          # process dies, so wait for this pid to be gone before looking again, or the retry finds the same corpse.
          # `:global` does the same in a cluster.
          retry_stopped(id, pid, request, timeout, attempts)

        :exit, {{:nodedown, _node}, {GenServer, :call, _}} ->
          # The node of the process went away; `:global` forgets its names once it sees that, so a retry loads the
          # branch from storage on this node, as after a crash of one node.
          retry_stopped(id, pid, request, timeout, attempts)

        :exit, {:timeout, {GenServer, :call, _}} ->
          {:error, timeout_error(id, timeout)}

        :exit, {:killed, {GenServer, :call, _}} ->
          # The watcher marks it too, but asynchronously; mark here so the very next call already sees it.
          Supervisor.mark_too_large(id)
          {:error, too_large_error(id)}
      end
    end
  end

  defp retry_stopped(id, pid, request, timeout, attempts) do
    await_down(pid)

    if attempts > 1,
      do: call(id, request, timeout, attempts - 1),
      else: stopping_error(id)
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

  defp timeout_error(id, timeout) do
    Error.new(
      :timeout,
      "branch #{inspect(id)} did not answer within #{timeout} ms; the request may still be carried out",
      %{id: id, timeout: timeout}
    )
  end

  @doc """
  Waits until the process of branch `id` has handled every request sent before this one, for a caller whose request
  timed out and needs to know whether it was carried out. Waits as long as a persisting call does.
  """
  @spec settle(String.t()) :: :ok | {:error, Error.t()}
  def settle(id) do
    with {:ok, _status} <- call(id, :status, @persist_timeout, @max_attempts), do: :ok
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

      # The process died without terminate/2 (a kill), and its watcher has not marked it yet. Storage is behind what the
      # process held, so loading the branch from there would drop writes its callers were told succeeded.
      Supervisor.running?(id) ->
        Supervisor.mark_too_large(id)
        {:error, too_large_error(id)}

      # In a cluster the process claims the branch itself once `:global` has given it the name (see init/1): claiming
      # here would bump the epoch of the process that holds the branch if another caller won the name first.
      config.cluster ->
        start_child({:load, id, config}, & &1)

      true ->
        with {:ok, branch} <- config.storage.fetch(id, config.storage_config),
             {:ok, branch, recovered} <- recover(branch, config),
             {:ok, pid} <- start(branch, config) do
          compact_recovered(pid, recovered)
        end
    end
  end

  # A branch that came back from a crash is stored again as a snapshot, which deletes the deltas it applied, so the next
  # crash does not start from a longer chain. The process does it once it owns the branch: this caller may have lost the
  # race to start it.
  defp compact_recovered(pid, recovered) do
    if recovered > 0, do: GenServer.cast(pid, :compact)
    {:ok, pid}
  end

  # A durable branch is its snapshot with the deltas of the write log after it applied, in the order their actions
  # ended in (ADR 0048).
  defp recover(%Branch{durable: true} = branch, config) do
    if Ramal.Storage.durable?(config.storage) do
      with {:ok, deltas} <- config.storage.writes_after(branch, config.storage_config) do
        {:ok, apply_deltas(branch, deltas), length(deltas)}
      end
    else
      {:error, Ramal.Storage.durability_unsupported(config.storage)}
    end
  end

  defp recover(branch, _config), do: {:ok, branch, 0}

  defp apply_deltas(branch, deltas),
    do:
      Enum.reduce(deltas, branch, fn {seq, delta}, acc -> Branch.apply_delta(acc, seq, delta) end)

  @doc false
  def too_large_error(id) do
    Error.new(
      :branch_too_large,
      "branch #{inspect(id)} exceeded max_heap_size and was stopped (or its process was killed); its last persisted " <>
        "state remains, discard it or raise the limit",
      %{id: id}
    )
  end

  @doc """
  The branch for `Ramal.fork/2`. Rejected unless the branch is open and not claimed by a merge: the claimed branch's log
  is about to be replayed, and a fork of it would replay the same writes a second time. The writes of actions that are
  still running are left out, because those actions may yet fail and take them back.
  """
  @spec fork_source(String.t()) :: {:ok, Branch.t()} | {:error, Error.t()}
  def fork_source(id), do: call(id, :fork_source)

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
  The domain of the branch and nothing else, for a caller that needs it to name the branch in telemetry and not the
  copy of the whole branch `get/1` makes.
  """
  @spec domain(String.t()) :: {:ok, module} | {:error, Error.t()}
  def domain(id), do: call(id, :domain)

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
  The tenant the branch works in (`nil` for none). Read when a query or changeset on a multitenant resource carries a
  tenant, to check it is the branch's (ADR 0034).
  """
  @spec tenant(String.t()) :: {:ok, term} | {:error, Error.t()}
  def tenant(id), do: call(id, :tenant)

  @doc """
  The overlay entries of `resource` for `keys` only (`Ramal.load/3`), as `key => {kind, record} | :deleted`. Rejected
  unless the branch is open.
  """
  @spec fetch(String.t(), module, [term]) :: {:ok, Overlay.slice()} | {:error, Error.t()}
  def fetch(id, resource, keys), do: call(id, {:fetch, resource, keys})

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
  The branch for a nested merge into it (ADR 0043), with its `version`. Like `begin_merge/2` it waits for the actions
  running in the branch to end, so that the copy holds no write that may yet be taken back, and is rejected unless the
  branch is open and not claimed by a merge. The `version` changes with every change of the branch; `adopt/4` takes it.
  """
  @spec merge_source(String.t()) :: {:ok, Branch.t(), version} | {:error, Error.t()}
  def merge_source(id), do: call(id, {:merge_source, nil})

  @doc """
  Gives the branch the work of a nested fork: `scratch` is a copy of it (`merge_source/1`) in which the fork's writes were
  replayed. Refused with `{:error, :moved}` when the branch changed since the copy was taken, which is what makes the
  replay valid: the branch is then the one the replay saw. Persists the branch before it answers, so that a fork marked
  as merged never outlives the work it gave. Rejected unless the branch is open, not claimed and not already given this
  fork's work.
  """
  @spec adopt(String.t(), Branch.t(), Branch.t(), version) ::
          :ok | {:error, :moved} | {:error, Error.t()}
  def adopt(id, scratch, child, version),
    do: persisting_call(id, {:adopt, scratch, child, version})

  @doc """
  Replaces the branch with the result of `fun`, which runs inside the process, so concurrent updates are serialised.
  `fun` receives the branch and returns the new branch. Rejected unless the branch is open.
  """
  @spec update(String.t(), (Branch.t() -> Branch.t())) :: {:ok, Branch.t()} | {:error, Error.t()}
  def update(id, fun) when is_function(fun, 1), do: call(id, {:update, fun})

  @doc """
  Records the fingerprints of base rows a read returned (`Ramal.Branch.put_fingerprints/2`), and for a nested fork what
  it holds for them (`Ramal.Branch.see/2`). Rejected unless the branch is open. Like a read it does not count as a change
  of the branch (`version`).
  """
  @spec fingerprints(String.t(), Enumerable.t()) :: :ok | {:error, Error.t()}
  def fingerprints(id, fingerprints), do: call(id, {:fingerprints, fingerprints})

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
  Captures one write of an action (`Ramal.Capture`): like `write/2`, and when `fun` replies `{:ok, undo}` the process
  keeps the undo under the calling process until the action ends (`release/1`) or takes the write back (`undo/2`). Until
  then the write is the action's own, as an uncommitted row is a transaction's:

    * a merge and a proposal wait for it, and a fork is taken without it;
    * a write of the same row `ref` by another process is refused with `:row_busy`, as a row lock would make it wait;
    * if the calling process dies, the write is taken back.

  Rejected unless the branch is open, and while a merge or a proposal waits, for a process with no running action.
  """
  @spec capture(String.t(), Overlay.ref(), (Branch.t() -> {reply, Branch.t()})) ::
          {:ok, reply, %{id: String.t(), domain: module}} | {:error, Error.t()}
        when reply: term
  def capture(id, ref, fun) when is_function(fun, 1), do: call(id, {:capture, ref, fun})

  @doc """
  Takes back writes of the calling process's running action (`Ramal.Branch.undo/2`) when the action failed.
  """
  @spec undo(String.t(), [Branch.undo()]) :: :ok | {:error, Error.t()}
  def undo(id, undos), do: call(id, {:undo, undos})

  @doc """
  Marks the branch as it is now for the calling process, so that `rollback/2` can take back everything written since
  (`Ramal.run/3` with `atomic: true`). Until the savepoint is rolled back or dropped with `keep/2` the process does not
  unload, since the savepoint would be lost with it; if the calling process dies the savepoint is dropped.
  """
  @spec savepoint(String.t()) :: {:ok, reference} | {:error, Error.t()}
  def savepoint(id), do: call(id, :savepoint)

  @doc """
  Takes back every write made since `savepoint` (`Ramal.Branch.rollback/2`) and drops it. A durable branch then stores a
  snapshot, which deletes the write log it covers, when an action ended in between: the write log can only be appended
  to, and a snapshot is how it is cut back. Answers `:ok` once that is stored; a refused snapshot is tried again by the
  next compaction and reported as `[:ramal, :branch, :persist_failed]`.
  """
  @spec rollback(String.t(), reference) :: :ok | {:error, Error.t()}
  def rollback(id, savepoint), do: persisting_call(id, {:rollback, savepoint})

  @doc """
  Drops `savepoint`: the writes made since stand. Asynchronous, like `release/1`.
  """
  @spec keep(String.t(), reference) :: :ok
  def keep(id, savepoint) do
    if pid = Supervisor.whereis(id), do: GenServer.cast(pid, {:keep, savepoint})

    :ok
  end

  @doc """
  Tells the process that the calling process's action ended and its writes stand. Asynchronous: a later call of the same
  process is handled after it. A branch with no process has no running action to end, so nothing is started for it.
  """
  @spec release(String.t()) :: :ok
  def release(id) do
    # A cast to a process that has just died is dropped, which is what a release of it needs; so no liveness check.
    if pid = Supervisor.whereis(id), do: GenServer.cast(pid, {:release, self()})

    :ok
  end

  @doc """
  Tells the process of a durable branch (ADR 0048) that the calling process's outermost action ended and its writes
  stand. Unlike `release/1` it is a call: the process appends the writes of the action, and of no other, to the storage's
  write log and answers `:ok` once they are stored, and the action returns only then. It answers
  `{:error, %Ramal.Error{reason: :storage}}` when they are not, and the action fails: the writes stay held, so
  the caller takes them back with `undo/2` like any failed action.

  A branch that is not open any more (discarded while the action ran) has nothing to store, and `:ok` is the answer. A
  process that holds no writes of the caller, because it was restarted since, answers the error, for the writes are gone.
  """
  @spec commit(String.t()) :: :ok | {:error, Error.t()}
  def commit(id), do: persisting_call(id, :commit)

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
  there), marks it merged, persists it and stops the process; `:stored` marks it merged and stops without writing,
  because the storage already holds it as merged (ADR 0035); `:aborted` only releases the claim.

  The merge has committed by the time `:merged` is sent, so a storage failure is not an error of the merge. The process
  keeps the branch as `:merged` (it refuses writes and a second merge), answers `{:persist_failed, error}`, and writes
  it again at its next idle timeout (ADR 0023).
  """
  @spec finish_merge(String.t(), :merged | :stored | :aborted, (Branch.t() -> Branch.t())) ::
          :ok | {:persist_failed, Error.t()} | {:error, Error.t()}
  def finish_merge(id, outcome, annotate \\ & &1)
      when outcome in [:merged, :stored, :aborted] and is_function(annotate, 1),
      do: persisting_call(id, {:finish_merge, outcome, annotate})

  @doc """
  Freezes an open branch as a proposal: `fun` turns the branch into the proposed one, which is persisted before the
  call returns, so a proposal survives a restart. The process stays up; the branch refuses writes and reads because it
  is no longer open.
  """
  @spec propose(String.t(), (Branch.t() -> Branch.t())) :: {:ok, Branch.t()} | {:error, Error.t()}
  def propose(id, fun) when is_function(fun, 1), do: persisting_call(id, {:propose, fun})

  @doc """
  Rejects a proposed branch: `fun` records the decision, the rejected branch is persisted and the process stops. The
  overlay and log are kept, so the rejected diff can still be read.
  """
  @spec reject(String.t(), (Branch.t() -> Branch.t())) :: {:ok, Branch.t()} | {:error, Error.t()}
  def reject(id, fun) when is_function(fun, 1), do: persisting_call(id, {:reject, fun})

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
        persisting_call(id, :discard)
      end
    end
  end

  @doc """
  Removes the record of a branch in a terminal status (`:discarded`, `:merged`, `:rejected`) from storage, with its write
  log, and forgets the marks the supervisor keeps for it.

  The status is read from storage, not from a process: a terminal branch has no process left to ask, and an open or
  proposed one is refused with `:not_terminal` whether or not its process is loaded. A missing branch is `:not_found`.
  """
  @spec purge(String.t()) :: :ok | {:error, Error.t()}
  def purge(id) do
    with {:ok, config} <- Supervisor.config(),
         {:ok, branch} <- config.storage.fetch(id, config.storage_config),
         :ok <- ensure_terminal(branch),
         :ok <- config.storage.delete(id, config.storage_config) do
      Supervisor.clear_too_large(id)
      Supervisor.clear_running(id)
      Telemetry.branch(:delete, branch)
      :ok
    end
  end

  defp ensure_terminal(%{status: status}) when status in [:discarded, :merged, :rejected], do: :ok

  defp ensure_terminal(%{id: id, status: status}) do
    {:error,
     Error.new(
       :not_terminal,
       "branch #{inspect(id)} is #{status}; only a discarded, merged or rejected branch can be deleted " <>
         "(discard it first, or discard it with purge: true)",
       %{id: id, status: status}
     )}
  end

  defp discard_cold(id, config) do
    with {:ok, branch} <- config.storage.fetch(id, config.storage_config),
         {:ok, branch, _recovered} <- recover(branch, config),
         discarded = Branch.discard(branch),
         :ok <- config.storage.put(discarded, config.storage_config) do
      Supervisor.clear_too_large(id)
      Supervisor.clear_running(id)
      Telemetry.branch(:discard, discarded)
      :ok
    end
  end

  # -- server side --------------------------------------------------------------------------------------------------

  @impl true
  def init({:handoff, id, ref, config}) do
    flags(config)
    Supervisor.mark_running(id)
    {:ok, process_state(nil, config), {:continue, {:handoff, ref}}}
  end

  def init({:scratch, branch, config}) do
    flags(config)
    Supervisor.mark_running(branch.id)
    state = process_state(branch, %{config | idle_timeout: :infinity})
    {:ok, %{state | scratch: true}, :infinity}
  end

  def init({:load, id, config}) do
    flags(config)

    with {:ok, branch} <- claim(id, config) do
      {:ok, started(branch, config), config.idle_timeout}
    end
  end

  def init({branch, config}) do
    flags(config)

    # In a cluster the storage, not the caller, says what the branch holds: another node may have saved it since.
    with {:ok, branch} <- if(config.cluster, do: claim(branch.id, config), else: {:ok, branch}) do
      {:ok, started(branch, config), config.idle_timeout}
    end
  end

  defp started(branch, config) do
    branch = branch |> share(config) |> found_adopted(config)
    watch(branch)
    Telemetry.branch(:load, branch)
    Supervisor.mark_running(branch.id)
    process_state(branch, config)
  end

  # Loads the branch and takes its epoch (`c:Ramal.Storage.claim/2`), which makes every earlier holder's writes fail.
  # A durable branch is then read with its write log (ADR 0048), after the claim and not before: once the epoch is
  # taken, the earlier holder can append nothing more, so the log read is every delta it was told was stored.
  defp claim(id, config) do
    with {:ok, branch} <- config.storage.claim(id, config.storage_config),
         {:ok, branch, recovered} <- recover(branch, config) do
      if recovered > 0, do: GenServer.cast(self(), :compact)
      {:ok, branch}
    else
      {:error, error} -> {:stop, error}
    end
  end

  defp flags(config) do
    # Trapping exits makes the supervisor's shutdown call terminate/2, which persists the branch.
    Process.flag(:trap_exit, true)
    heap_limit(config.max_heap_size)
  end

  defp heap_limit(size),
    do: Process.flag(:max_heap_size, %{size: size, kill: true, error_logger: false})

  # Storage hands the branch over as a copy that kept no sharing (`Ramal.Branch.share/1`). Sharing it again leaves about
  # as much garbage as the branch is large, so the limit is lifted for it and a collection drops that garbage before
  # the limit applies again. A fork is not shared here: it would delay the first call to the fork by the whole pass.
  defp share(%Branch{log: []} = branch, _config), do: branch

  defp share(branch, config) do
    heap_limit(0)
    shared = Branch.share(branch)
    :erlang.garbage_collect()
    heap_limit(config.max_heap_size)
    shared
  end

  defp process_state(branch, config),
    do: %{
      branch: branch,
      config: config,
      stop: nil,
      scratch: false,
      # changes with every change of the branch (`bump/1`), so that `adopt/4` can tell the branch it was given a copy of
      version: {make_ref(), 0},
      merging: nil,
      persisted: false,
      # appends to the write log since the last snapshot (durable branches)
      appended: 0,
      index: nil,
      seen: nil,
      # pid => %{monitor: ref, undos: [undo]}: the writes of actions that have not ended (capture/3)
      running: %{},
      # {tag, from, request, timer}: merges and proposals waiting for the running actions to end
      waiting: [],
      # monitor of the run's process => `Branch.savepoint/1`: what an atomic run (`Ramal.run/3`) can take the branch back
      # to. The monitor is the token the run holds, so its death drops the savepoint (see handle_info/2)
      savepoints: %{}
    }

  @impl true
  def handle_continue({:handoff, ref}, state) do
    receive do
      {:handoff, ^ref, branch} ->
        handed_over(branch, state)
    after
      @handoff_timeout -> {:stop, :normal, %{state | stop: :unclaimed}}
    end
  end

  def handle_continue(:compact, state), do: state |> compact() |> compacted()

  # The fork is stored already; in a cluster it is claimed like any branch a process loads (see init/1).
  defp handed_over(branch, %{config: %{cluster: true} = config} = state) do
    case claim(branch.id, config) do
      {:ok, claimed} ->
        {:noreply, %{state | branch: started_branch(claimed)}, config.idle_timeout}

      {:stop, _error} ->
        Supervisor.clear_running(branch.id)
        {:stop, :normal, %{state | stop: :unclaimed}}
    end
  end

  defp handed_over(branch, %{config: config} = state) do
    {:noreply, %{state | branch: started_branch(branch)}, config.idle_timeout}
  end

  defp started_branch(branch) do
    watch(branch)
    Telemetry.branch(:load, branch)
    branch
  end

  @impl true
  def handle_call(:get, _from, state), do: reply(state, {:ok, state.branch})

  # `Ramal.Cluster.resolve/3` asks for it when two processes of a branch meet after a netsplit.
  def handle_call(:epoch, _from, state), do: reply(state, state.branch && state.branch.epoch)

  def handle_call(:fork_source, _from, state) do
    if usable?(state),
      do: reply(state, {:ok, without_running(state)}),
      else: reply(state, {:error, unavailable(state)})
  end

  def handle_call(:status, _from, state), do: reply(state, {:ok, state.branch.status})

  def handle_call(:domain, _from, state), do: reply(state, {:ok, state.branch.domain})

  def handle_call(:tenant, _from, state), do: reply(state, {:ok, state.branch.tenant})

  def handle_call({:diff, opts}, _from, state), do: reply(state, Branch.diff(state.branch, opts))

  def handle_call({:slice, resource}, _from, state) do
    read_overlay(state, fn overlay, index ->
      if index, do: Map.get(index, resource, %{}), else: Overlay.slice(overlay, resource)
    end)
  end

  def handle_call({:fetch, resource, keys}, _from, state) do
    read_overlay(state, fn overlay, index ->
      slice = if index, do: Map.get(index, resource, %{}), else: Overlay.slice(overlay, resource)
      Map.take(slice, keys)
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

    selected =
      read_overlay(state, fn overlay, index ->
        if index,
          do: index |> Map.get(resource, %{}) |> Overlay.select_slice(base_keys, possible?),
          else: Overlay.select(overlay, resource, base_keys, possible?)
      end)

    case selected do
      {:reply, {:ok, {slice, _count}} = reply, state, timeout} ->
        {:reply, reply, see(state, resource, Map.keys(slice)), timeout}

      other ->
        other
    end
  end

  def handle_call({:fingerprints, fingerprints}, _from, state) do
    if usable?(state) do
      refs = Enum.map(fingerprints, &elem(&1, 0))
      branch = state.branch |> Branch.put_fingerprints(fingerprints) |> Branch.see(refs)
      reply(%{state | branch: branch}, :ok)
    else
      reply(state, {:error, unavailable(state)})
    end
  end

  def handle_call({:update, fun}, _from, state) do
    if usable?(state) do
      branch = fun.(state.branch)
      reply(bump(%{state | branch: branch}), {:ok, branch})
    else
      reply(state, {:error, unavailable(state)})
    end
  end

  def handle_call({:write, fun}, _from, state) do
    if usable?(state) do
      {reply, branch} = fun.(state.branch)

      reply(
        bump(%{state | branch: branch}),
        {:ok, reply, %{id: branch.id, domain: branch.domain}}
      )
    else
      reply(state, {:error, unavailable(state)})
    end
  end

  def handle_call({:capture, ref, fun}, {pid, _tag}, state) do
    cond do
      not usable?(state) ->
        reply(state, {:error, unavailable(state)})

      state.waiting != [] and not is_map_key(state.running, pid) ->
        reply(state, {:error, closing(state)})

      busy?(state, ref, pid) ->
        reply(state, {:error, row_busy(state, ref)})

      true ->
        {reply, branch} = fun.(state.branch)
        state = bump(%{state | branch: branch})

        state =
          case reply do
            {:ok, %{ref: _} = undo} -> hold(state, pid, undo)
            _refused -> state
          end

        reply(
          state,
          {:ok, reply, %{id: branch.id, domain: branch.domain, durable: branch.durable}}
        )
    end
  end

  # The undo of a durable branch takes back only what the caller still holds. A caller that gave up waiting for its
  # commit and undoes its writes anyway would otherwise take back writes that are stored by then.
  def handle_call({:undo, undos}, {pid, _tag}, %{branch: %{durable: true}} = state) do
    held = state.running |> Map.get(pid, %{undos: []}) |> Map.fetch!(:undos) |> MapSet.new()
    undos = Enum.filter(undos, &MapSet.member?(held, &1))
    state = state |> take_back(undos) |> drop_undos(pid, undos)
    reply(state, :ok)
  end

  def handle_call({:undo, undos}, {pid, _tag}, state) do
    state = state |> take_back(undos) |> drop_undos(pid, undos)
    reply(state, :ok)
  end

  def handle_call(:savepoint, {pid, _tag}, state) do
    if usable?(state) do
      token = Process.monitor(pid)

      reply(
        %{state | savepoints: Map.put(state.savepoints, token, Branch.savepoint(state.branch))},
        {:ok, token}
      )
    else
      reply(state, {:error, unavailable(state)})
    end
  end

  def handle_call({:rollback, token}, _from, state) do
    {savepoint, state} = pop_savepoint(state, token)

    cond do
      savepoint == nil -> reply(state, {:error, savepoint_lost(state)})
      not usable?(state) -> reply(state, {:error, unavailable(state)})
      true -> rolled_back(state, savepoint)
    end
  end

  def handle_call(:commit, {pid, _tag}, %{branch: %{durable: true}} = state) do
    cond do
      not usable?(state) -> reply(state, :ok)
      not is_map_key(state.running, pid) -> reply(state, {:error, writes_lost(state)})
      true -> commit_writes(state, pid)
    end
  end

  def handle_call(:commit, _from, state), do: reply(state, :ok)

  # A merge or a proposal of a branch with actions running waits for them, as a lock would; see wait/3.
  def handle_call({kind, _arg} = request, from, %{running: running} = state)
      when kind in [:begin_merge, :propose, :merge_source] and map_size(running) > 0 do
    if usable?(state),
      do: wait(state, from, request),
      else: reply(state, {:error, unavailable(state)})
  end

  def handle_call({:merge_source, nil}, _from, state) do
    if usable?(state),
      do: reply(state, {:ok, state.branch, state.version}),
      else: reply(state, {:error, unavailable(state)})
  end

  def handle_call({:adopt, scratch, child, version}, _from, state) do
    cond do
      not usable?(state) ->
        reply(state, {:error, unavailable(state)})

      child.id in state.branch.merged_children ->
        reply(state, {:error, already_adopted(state, child)})

      state.version != version or map_size(state.running) > 0 ->
        reply(state, {:error, :moved})

      true ->
        branch = Branch.adopt(state.branch, scratch, child)

        case persist(state, branch) do
          :ok ->
            Telemetry.branch(:adopt, branch, %{child_id: child.id})
            reply(bump(%{state | branch: branch}), :ok)

          {:error, %Error{reason: :fenced} = error} ->
            {:stop, :normal, {:error, error}, fence(state, error)}

          {:error, _} = error ->
            reply(state, error)
        end
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

      :stored ->
        stop_merged(state)

      :merged ->
        branch = %{annotate.(state.branch) | status: :merged}

        case persist(state, branch) do
          :ok ->
            {:stop, :normal, :ok, %{state | branch: branch, stop: :merged}}

          # Another process holds the branch now and this one may not write it. The commit stands, and so does the
          # merged status the transaction stored; there is nothing left here to keep.
          {:error, %Error{reason: :fenced} = error} ->
            {:stop, :normal, {:persist_failed, error}, fence(%{state | branch: branch}, error)}

          {:error, error} ->
            # The replay has committed, so the merge happened whatever the storage says. Stopping would lose the
            # `:merged` status and leave the stored branch open, to be merged a second time. Keep it loaded as merged;
            # the idle timeout writes it again (see handle_info(:timeout, _)).
            Telemetry.branch(:persist_failed, branch, %{reason: :merged, error: error})
            reply(%{state | branch: branch}, {:persist_failed, error})
        end
    end
  end

  def handle_call({:finish_merge, _outcome, _annotate}, _from, state), do: reply(state, :ok)

  def handle_call({:propose, fun}, _from, state) do
    if usable?(state) do
      branch = fun.(state.branch)

      case persist(state, branch) do
        :ok ->
          Telemetry.branch(:propose, branch)
          reply(%{state | branch: branch}, {:ok, branch})

        {:error, %Error{reason: :fenced} = error} ->
          {:stop, :normal, {:error, error}, fence(state, error)}

        {:error, _} = error ->
          reply(state, error)
      end
    else
      reply(state, {:error, unavailable(state)})
    end
  end

  def handle_call({:reject, fun}, _from, %{merging: nil, branch: %{status: :proposed}} = state) do
    branch = fun.(state.branch)

    case persist(state, branch) do
      :ok ->
        Telemetry.branch(:reject, branch)
        {:stop, :normal, {:ok, branch}, %{state | branch: branch, stop: :rejected}}

      {:error, %Error{reason: :fenced} = error} ->
        {:stop, :normal, {:error, error}, fence(state, error)}

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
    state = Enum.reduce(Map.keys(state.running), state, &drop_running(&2, &1))

    case persist(state, branch) do
      :ok ->
        Telemetry.branch(:discard, branch)
        {:stop, :normal, :ok, %{state | branch: branch, stop: :discarded}}

      {:error, %Error{reason: :fenced} = error} ->
        {:stop, :normal, {:error, error}, fence(state, error)}

      {:error, _} = error ->
        reply(state, error)
    end
  end

  def handle_call(:discard, _from, state), do: reply(state, {:error, unavailable(state)})

  @impl true
  # An idle branch unloads only once its state is safe in storage. If the write fails, stopping would lose the overlay
  # and the log (terminate/2 cannot report the failure to anyone), so the process stays up and tries again at the next
  # idle timeout.
  def handle_info(:timeout, %{branch: branch} = state) do
    case persist(state, branch) do
      :ok ->
        {:stop, :normal, %{state | stop: :idle, persisted: true}}

      {:error, %Error{reason: :fenced} = error} ->
        {:stop, :normal, fence(state, error)}

      {:error, error} ->
        Telemetry.branch(:persist_failed, branch, %{reason: :idle, error: error})
        {:noreply, state, timeout(state)}
    end
  end

  # The merging process died without finishing. If its transaction committed, a storage that marks merges inside the
  # transaction says so, and the process takes that status; otherwise the claim is released so the branch can be merged
  # again (ADR 0035). A commit still in flight can read as open here; the mark refuses the second merge then.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{merging: ref} = state) do
    state = %{state | merging: nil}

    cond do
      stored_merged?(state) -> {:stop, :normal, merged_state(state)}
      adopted?(state.branch, state.config) -> adopted(state)
      true -> {:noreply, state, timeout(state)}
    end
  end

  # The process of an atomic run died: nobody is left to roll it back or to keep it, and its writes stand as they are.
  def handle_info({:DOWN, token, :process, _pid, _reason}, %{savepoints: savepoints} = state)
      when is_map_key(savepoints, token) do
    state = %{state | savepoints: Map.delete(savepoints, token)}
    {:noreply, state, timeout(state)}
  end

  # A process died in the middle of an action: the action did not happen, so its writes are taken back, as a database
  # rolls back the transaction of a connection whose owner died.
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{running: running} = state)
      when is_map_key(running, pid) do
    state =
      case running[pid] do
        %{monitor: ^ref, undos: undos} ->
          state |> take_back(undos) |> drop_running(pid) |> serve_waiting()

        _other_monitor ->
          state
      end

    {:noreply, state, timeout(state)}
  end

  def handle_info({:waited_too_long, tag}, state) do
    case List.keytake(state.waiting, tag, 0) do
      {{^tag, from, _request, _timer}, waiting} ->
        GenServer.reply(from, {:error, busy_error(state)})
        state = %{state | waiting: waiting}
        {:noreply, state, timeout(state)}

      nil ->
        {:noreply, state, timeout(state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state, timeout(state)}

  @impl true
  # `:global` kept the other process of this branch after a netsplit (`Ramal.Cluster.resolve/3`). Unloading saves the
  # branch like an idle one, which the storage refuses if this process is the one that lost the epoch.
  def handle_cast(:superseded, state), do: {:stop, :normal, %{state | stop: :superseded}}

  def handle_cast({:keep, token}, state) do
    {_savepoint, state} = pop_savepoint(state, token)
    {:noreply, state, timeout(state)}
  end

  def handle_cast({:release, pid}, state) do
    state = state |> drop_running(pid) |> serve_waiting()
    {:noreply, state, timeout(state)}
  end

  def handle_cast(:compact, state), do: state |> compact() |> compacted()

  @impl true
  def terminate(reason, state) do
    stopped(reason, state)
  after
    if state.branch, do: Supervisor.clear_running(state.branch.id)
  end

  # A process that never received its branch has nothing to persist; storage already holds the fork.
  defp stopped(_reason, %{branch: nil}), do: :ok

  defp stopped(_reason, %{stop: stop}) when stop in [:discarded, :merged, :rejected, :fenced],
    do: :ok

  defp stopped(_reason, %{scratch: true}), do: :ok

  defp stopped(_reason, %{branch: branch, stop: stop, persisted: persisted} = state) do
    # Persist before announcing the unload, so an observer who sees the event can already rehydrate the branch. On a
    # shutdown there is no process left to keep, so a failed write is reported instead of announced as an unload.
    # A durable branch stores nothing of an action that has not ended (ADR 0048): one that never ends is not stored.
    with false <- persisted,
         {:error, error} <- persist(state, stored_branch(state)) do
      if match?(%Error{reason: :fenced}, error),
        do: announce_fenced(branch, error),
        else:
          Telemetry.branch(:persist_failed, branch, %{reason: stop || :shutdown, error: error})
    else
      _persisted -> Telemetry.branch(:unload, branch, %{reason: stop || :shutdown})
    end
  end

  defp reply(state, reply), do: {:reply, reply, state, timeout(state)}

  defp stored_branch(%{branch: %{durable: true}} = state), do: without_running(state)
  defp stored_branch(state), do: state.branch

  # The storage refused a write of this process because another one loaded the branch after it (ADR 0044). Whatever it
  # held since its last save is gone for good, so the process announces that and stops without saving again.
  defp fence(state, error) do
    announce_fenced(state.branch, error)
    %{state | stop: :fenced}
  end

  defp announce_fenced(branch, error),
    do: Telemetry.branch(:fenced, branch, %{epoch: branch.epoch, error: error})

  # A branch being merged must not unload: the merge would lose its claim. Nor one with actions running: their writes
  # would be stored as if they had ended, and a death of their process would go unnoticed.
  # Nor one with an atomic run open: its savepoint is in the process, and a load from storage would not have it.
  defp timeout(%{
         merging: nil,
         running: running,
         waiting: [],
         savepoints: savepoints,
         config: config
       })
       when map_size(running) == 0 and map_size(savepoints) == 0,
       do: config.idle_timeout

  defp timeout(_state), do: :infinity

  # -- running actions --------------------------------------------------------------------------------------------

  defp hold(state, pid, undo) do
    running =
      Map.update(state.running, pid, %{monitor: Process.monitor(pid), undos: [undo]}, fn held ->
        %{held | undos: [undo | held.undos]}
      end)

    %{state | running: running}
  end

  # A write is taken back only from an open branch: a discarded one holds nothing, and nothing else can happen while an
  # action runs, since a merge and a proposal wait for it.
  defp take_back(%{branch: %{status: :open} = branch} = state, undos),
    do: bump(%{state | branch: Branch.undo(branch, undos)})

  defp take_back(state, _undos), do: state

  defp drop_undos(state, pid, undos) do
    case state.running do
      %{^pid => running} ->
        case running.undos -- undos do
          [] -> state |> drop_running(pid) |> serve_waiting()
          left -> %{state | running: Map.put(state.running, pid, %{running | undos: left})}
        end

      _none ->
        state
    end
  end

  defp drop_running(state, pid) do
    case Map.pop(state.running, pid) do
      {nil, _running} ->
        state

      {held, running} ->
        Process.demonitor(held.monitor, [:flush])
        %{state | running: running}
    end
  end

  # -- atomic runs ------------------------------------------------------------------------------------------------

  defp pop_savepoint(state, token) do
    case Map.pop(state.savepoints, token) do
      {nil, _savepoints} ->
        {nil, state}

      {savepoint, savepoints} ->
        Process.demonitor(token, [:flush])
        {savepoint, %{state | savepoints: savepoints}}
    end
  end

  # The writes since the savepoint are gone from the branch. The write log of a durable branch only grows, so when an
  # action ended since the savepoint (`wal` moved) the deltas it appended are covered by a snapshot of the branch as it
  # is now, which deletes them (`c:Ramal.Storage.put/2`); the snapshot leaves out the writes of actions still running,
  # as a compaction does. A snapshot the storage refuses leaves the deltas where they are until the next compaction
  # stores one (`{:continue, :compact}`), which is the only time a crash would bring the rolled-back writes back.
  defp rolled_back(state, savepoint) do
    before = state.branch
    state = bump(%{state | branch: Branch.rollback(before, savepoint)})
    Telemetry.branch(:rollback, before, %{entries: length(before.log) - length(state.branch.log)})

    if state.branch.durable and state.branch.wal > savepoint.wal do
      snapshot = without_running(state)

      case persist(state, snapshot) do
        :ok ->
          reply(%{state | appended: 0}, :ok)

        {:error, %Error{reason: :fenced} = error} ->
          {:stop, :normal, {:error, error}, fence(state, error)}

        {:error, error} ->
          Telemetry.branch(:persist_failed, snapshot, %{reason: :rollback, error: error})
          {:reply, :ok, state, {:continue, :compact}}
      end
    else
      reply(state, :ok)
    end
  end

  defp savepoint_lost(state) do
    Error.new(
      :savepoint_lost,
      "branch #{inspect(state.branch.id)} no longer holds the savepoint of this atomic run (its process was restarted " <>
        "since), so the writes made since cannot be taken back",
      %{id: state.branch.id}
    )
  end

  # Appends what the action of `pid` added to the branch (ADR 0048). The delta holds the rows that action wrote and no
  # others, and no row is held by two running actions (`busy?/3`), so it holds nothing of an action that has not ended.
  # A failed append makes the action fail; its writes stay held for the undo that follows. The `seq` is given up either
  # way: a storage that failed to answer may have stored the delta, and a snapshot of this branch covering that `seq`,
  # stored right away, deletes it, as the next one does if this one fails. Reusing it could not be told from a
  # duplicate.
  defp commit_writes(state, pid) do
    %{branch: branch, config: config} = state
    delta = Branch.delta(branch, state.running[pid].undos)
    seq = branch.wal + 1
    started = System.monotonic_time()
    result = config.storage.append(branch, seq, delta, config.storage_config)
    duration = System.monotonic_time() - started
    state = %{state | branch: %{branch | wal: seq}}

    case result do
      :ok ->
        Telemetry.branch(
          :append,
          branch,
          %{seq: seq, rows: map_size(delta.overlay) + length(delta.gone)},
          %{
            duration: duration
          }
        )

        state = %{state | appended: state.appended + 1} |> drop_running(pid) |> serve_waiting()

        if state.appended >= @compact_every,
          do: {:reply, :ok, state, {:continue, :compact}},
          else: reply(state, :ok)

      # Another process holds the branch now (ADR 0044): nothing was stored, and nothing this one holds may be. The
      # action fails with the error, and the process stops as it does when a save is refused.
      {:error, %Error{reason: :fenced} = error} ->
        {:stop, :normal, {:error, error}, fence(state, error)}

      {:error, error} ->
        Telemetry.branch(:persist_failed, branch, %{reason: :append, error: error})
        {:reply, {:error, error}, state, {:continue, :compact}}
    end
  end

  # Stores the branch as a snapshot that covers the write log. The writes of running actions are left out, because those
  # actions may yet fail (ADR 0033); their deltas come after the snapshot's `wal`, when the actions end.
  defp compact(%{branch: %{durable: true, status: :open}, merging: nil} = state) do
    snapshot = without_running(state)
    started = System.monotonic_time()

    case persist(state, snapshot) do
      :ok ->
        Telemetry.branch(:compact, snapshot, %{wal: snapshot.wal}, %{
          duration: System.monotonic_time() - started
        })

        %{state | appended: 0}

      {:error, %Error{reason: :fenced} = error} ->
        fence(state, error)

      {:error, error} ->
        Telemetry.branch(:persist_failed, snapshot, %{reason: :compact, error: error})

        # Not again at the next action, which would meet the same storage: after half the interval.
        %{state | appended: div(@compact_every, 2)}
    end
  end

  defp compact(state), do: state

  # A compaction the storage refused because another process holds the branch now ends this one (see `fence/2`).
  defp compacted(%{stop: :fenced} = state), do: {:stop, :normal, state}
  defp compacted(state), do: {:noreply, state, timeout(state)}

  defp writes_lost(state) do
    Error.new(
      :storage,
      "branch #{inspect(state.branch.id)} no longer holds the writes of this action (its process was restarted since " <>
        "they were made), so they cannot be stored",
      %{id: state.branch.id}
    )
  end

  defp busy?(state, ref, pid) do
    Enum.any?(state.running, fn {other, held} ->
      other != pid and Enum.any?(held.undos, &(&1.ref == ref))
    end)
  end

  defp without_running(state) do
    Enum.reduce(state.running, state.branch, fn {_pid, held}, branch ->
      Branch.undo(branch, held.undos)
    end)
  end

  defp wait(state, from, request) do
    tag = make_ref()
    timer = Process.send_after(self(), {:waited_too_long, tag}, @wait_timeout)
    state = %{state | waiting: state.waiting ++ [{tag, from, request, timer}]}
    {:noreply, state, timeout(state)}
  end

  # Once no action runs, the waiting requests are handled in the order they came, as if they had come now.
  defp serve_waiting(%{running: running, waiting: [_ | _] = waiting} = state)
       when map_size(running) == 0 do
    Enum.reduce(waiting, %{state | waiting: []}, fn {_tag, from, request, timer}, state ->
      Process.cancel_timer(timer)
      {:reply, reply, state, _timeout} = handle_call(request, from, state)
      GenServer.reply(from, reply)
      state
    end)
  end

  defp serve_waiting(state), do: state

  defp closing(state) do
    Error.new(
      :not_open,
      "branch #{inspect(state.branch.id)} is waiting for the actions running in it to end before a merge or a " <>
        "proposal, and takes no new ones",
      %{id: state.branch.id, status: :closing}
    )
  end

  defp already_adopted(state, child) do
    Error.new(
      :not_open,
      "branch #{inspect(child.id)} already merged into branch #{inspect(state.branch.id)}",
      %{id: child.id, status: :merged, parent: state.branch.id}
    )
  end

  defp row_busy(state, {resource, key} = ref) do
    Error.new(
      :row_busy,
      "#{inspect(resource)} #{inspect(key)} was written in branch #{inspect(state.branch.id)} by an action that has " <>
        "not ended; retry once it has",
      %{id: state.branch.id, resource: resource, key: key, ref: ref}
    )
  end

  defp busy_error(state) do
    Error.new(
      :timeout,
      "branch #{inspect(state.branch.id)} still had actions running after #{@wait_timeout} ms; nothing was done",
      %{id: state.branch.id, timeout: @wait_timeout}
    )
  end

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

  # A nested fork records what it holds for the rows a read can return (`Ramal.Branch.see/2`). It is not a change of the
  # branch, so the version stays.
  defp see(%{branch: %{parent: nil}} = state, _resource, _keys), do: state

  defp see(state, resource, keys),
    do: %{state | branch: Branch.see(state.branch, Enum.map(keys, &{resource, &1}))}

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

  # A scratch branch is never stored: it lives only for one nested merge.
  defp persist(%{scratch: true}, _branch), do: :ok
  defp persist(%{config: config}, branch), do: config.storage.put(branch, config.storage_config)

  defp bump(%{version: {token, n}} = state), do: %{state | version: {token, n + 1}}

  defp stop_merged(state), do: {:stop, :normal, :ok, merged_state(state)}

  defp merged_state(state) do
    %{state | branch: %{state.branch | status: :merged}, stop: :merged, persisted: true}
  end

  # A nested fork whose parent holds its work, though its own status is still open: the merger died after the parent
  # persisted, or the node restarted before the fork was stored as merged. The fork's work is in the parent, so a write
  # to it now would be lost and a second merge would take the work twice: it is merged (ADR 0043). The parent persists
  # before it adopts, so its storage is what to ask.
  #
  # A durable parent is asked as a load asks it: the snapshot with the write log applied (ADR 0048). The adopt stored a
  # snapshot, so the snapshot already says, and the log after it never changes `merged_children`; reading both keeps
  # the answer true if either changes.
  defp adopted?(%Branch{parent: %{id: parent_id}, id: id, status: :open}, config) do
    with {:ok, parent} <- config.storage.fetch(parent_id, config.storage_config),
         {:ok, %Branch{merged_children: children}, _recovered} <- recover(parent, config) do
      id in children
    else
      _unknown -> false
    end
  end

  defp adopted?(_branch, _config), do: false

  defp found_adopted(branch, config) do
    if adopted?(branch, config), do: %{branch | status: :merged}, else: branch
  end

  # The merged status is written now; if the storage refuses, the process stays up as merged and writes it at its next
  # idle timeout, as for a merge whose commit succeeded (ADR 0023).
  defp adopted(state) do
    branch = %{state.branch | status: :merged}

    case persist(state, branch) do
      :ok ->
        {:stop, :normal, %{state | branch: branch, stop: :merged, persisted: true}}

      {:error, %Error{reason: :fenced} = error} ->
        {:stop, :normal, fence(state, error)}

      {:error, error} ->
        Telemetry.branch(:persist_failed, branch, %{reason: :merged, error: error})
        state = %{state | branch: branch}
        {:noreply, state, timeout(state)}
    end
  end

  defp stored_merged?(%{branch: branch, config: config}) do
    storage = config.storage

    Code.ensure_loaded?(storage) and function_exported?(storage, :mark_merged, 2) and
      match?({:ok, %{status: :merged}}, storage.fetch(branch.id, config.storage_config))
  end

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
