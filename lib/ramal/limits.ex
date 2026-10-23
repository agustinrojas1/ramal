defmodule Ramal.Limits do
  @moduledoc false
  # The optional ceilings on how many branches a domain can have and how fast they are made (ADR 0016). Both are off
  # unless the host sets them on `Ramal.Supervisor`, so a library user who sets nothing sees no difference.
  #
  # Both are counted per domain: one runaway client of one domain cannot starve another.
  #
  # `:max_active_branches` is a soft limit. The count is read and the branch is created afterwards, so callers that
  # check at the same moment can all pass, by at most the number of concurrent callers. `:branch_rate` is exact: the
  # counter is bumped atomically with `:ets.update_counter/4`, in fixed windows, so a burst that straddles the end of a
  # window can reach twice the rate for an instant.

  alias Ramal.{Error, Supervisor, Telemetry}

  @active [:open, :proposed]

  @type limits :: %{max_active: pos_integer | nil, rate: {pos_integer, pos_integer} | nil}

  @doc """
  Builds the limits from the supervisor options (`:max_active_branches` and `:branch_rate`), raising `ArgumentError` on
  a value that is not what the option takes, so a typo stops the application at start and not at the first fork.

  ## Example

      iex> Ramal.Limits.build(max_active_branches: 50, branch_rate: {10, 1_000})
      %{max_active: 50, rate: {10, 1000}}
      iex> Ramal.Limits.build([])
      %{max_active: nil, rate: nil}
  """
  @spec build(keyword) :: limits
  def build(opts) do
    %{
      max_active: max_active!(Keyword.get(opts, :max_active_branches)),
      rate: rate!(Keyword.get(opts, :branch_rate))
    }
  end

  defp max_active!(nil), do: nil
  defp max_active!(max) when is_integer(max) and max > 0, do: max

  defp max_active!(other) do
    raise ArgumentError,
          "Ramal.Supervisor: :max_active_branches must be a positive integer or nil, got: #{inspect(other)}"
  end

  defp rate!(nil), do: nil

  defp rate!({count, window} = rate)
       when is_integer(count) and count > 0 and is_integer(window) and window > 0, do: rate

  defp rate!(other) do
    raise ArgumentError,
          "Ramal.Supervisor: :branch_rate must be {count, window_in_milliseconds} with both positive integers, " <>
            "or nil, got: #{inspect(other)}"
  end

  @doc """
  Checks the limits before a branch of `domain` is created by `operation` (`:branch` or `:fork`).

  Returns `:ok` when no limit is set or none is reached, `{:error, %Ramal.Error{reason: :limit_reached}}` when one is,
  and the storage error when counting fails (a limit that cannot be checked refuses the call rather than passing it).
  Emits `[:ramal, :limit, :reached]` when it refuses.
  """
  @spec check(module, :branch | :fork, Supervisor.config()) :: :ok | {:error, Error.t()}
  def check(_domain, _operation, %{limits: %{max_active: nil, rate: nil}}), do: :ok

  def check(domain, operation, %{limits: limits} = config) do
    with :ok <- check_active(domain, operation, limits.max_active, config) do
      check_rate(domain, operation, limits.rate)
    end
  end

  defp check_active(_domain, _operation, nil, _config), do: :ok

  defp check_active(domain, operation, max, config) do
    with {:ok, active} <- count_active(domain, config) do
      if active < max do
        :ok
      else
        refuse(
          domain,
          operation,
          :max_active_branches,
          "#{inspect(domain)} has #{active} open or proposed branches and :max_active_branches is #{max}; " <>
            "merge, reject or discard some before creating more",
          %{max: max, active: active}
        )
      end
    end
  end

  defp count_active(domain, %{storage: storage, storage_config: storage_config}) do
    Code.ensure_loaded(storage)

    if function_exported?(storage, :count, 3) do
      storage.count(domain, @active, storage_config)
    else
      with {:ok, branches} <- storage.list(domain, [], storage_config) do
        {:ok, Enum.count(branches, &(&1.status in @active))}
      end
    end
  end

  defp check_rate(_domain, _operation, nil), do: :ok

  defp check_rate(domain, operation, {max, window}) do
    table = Supervisor.table()
    current = div(System.monotonic_time(:millisecond), window)
    key = {:rate, domain, current}

    case :ets.update_counter(table, key, 1, {key, 0}) do
      1 ->
        # First creation in this window: the counters of the windows before it are no use any more.
        :ets.select_delete(table, [{{{:rate, domain, :"$1"}, :_}, [{:<, :"$1", current}], [true]}])

        :ok

      count when count <= max ->
        :ok

      _over ->
        refuse(
          domain,
          operation,
          :branch_rate,
          "#{inspect(domain)} created #{max} branches in the last #{window} ms and :branch_rate is " <>
            "{#{max}, #{window}}; try again in a moment",
          %{max: max, window: window}
        )
    end
  end

  defp refuse(domain, operation, limit, message, details) do
    Telemetry.limit(:reached, %{domain: domain, operation: operation, limit: limit})

    {:error,
     Error.new(:limit_reached, message, Map.merge(details, %{domain: domain, limit: limit}))}
  end
end
