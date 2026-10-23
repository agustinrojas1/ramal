defmodule Ramal.Test.DurableStorage do
  @moduledoc false
  # ETS storage whose write log a test can break. A test registers itself under one of these names:
  #
  #   :ramal_test_append_down  - append refuses, and stores nothing
  #   :ramal_test_append_lost  - append stores the delta and then answers with an error, as a database does when the
  #                              connection drops after the commit
  #
  # Every successful append sends `{:appended, seq}` to a test registered as :ramal_test_append_watch, so a test can
  # tell what had been stored by the time an action returned.
  @behaviour Ramal.Storage

  alias Ramal.Error
  alias Ramal.Storage.ETS

  defdelegate put(branch, config), to: ETS
  defdelegate fetch(id, config), to: ETS
  defdelegate delete(id, config), to: ETS
  defdelegate list(domain, filters, config), to: ETS
  defdelegate count(domain, statuses, config), to: ETS
  defdelegate writes_after(branch, config), to: ETS

  def append(branch, seq, delta, config) do
    cond do
      Process.whereis(:ramal_test_append_down) ->
        {:error, Error.new(:storage, "the write log is down")}

      Process.whereis(:ramal_test_append_lost) ->
        :ok = ETS.append(branch, seq, delta, config)
        {:error, Error.new(:storage, "the write log answered too late")}

      true ->
        :ok = ETS.append(branch, seq, delta, config)
        if pid = Process.whereis(:ramal_test_append_watch), do: send(pid, {:appended, seq})
        :ok
    end
  end
end

defmodule Ramal.Test.PlainStorage do
  @moduledoc false
  # A custom backend written before the write log existed: the required callbacks and nothing else.
  @behaviour Ramal.Storage

  alias Ramal.Storage.ETS

  defdelegate put(branch, config), to: ETS
  defdelegate fetch(id, config), to: ETS
  defdelegate delete(id, config), to: ETS
  defdelegate list(domain, filters, config), to: ETS
end
