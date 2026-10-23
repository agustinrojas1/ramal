defmodule Ramal.LimitsTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.{Error, Limits}

  doctest Ramal.Limits

  # A storage that does not define the optional `count/3`, so the limit has to count with `list/3`.
  defmodule NoCount do
    @moduledoc false
    @behaviour Ramal.Storage

    defdelegate put(branch, config), to: Ramal.Storage.ETS
    defdelegate fetch(id, config), to: Ramal.Storage.ETS
    defdelegate delete(id, config), to: Ramal.Storage.ETS
    defdelegate list(domain, filters, config), to: Ramal.Storage.ETS
  end

  @rate_window :timer.hours(1)

  defp start(opts), do: start_supervised!({Ramal.Supervisor, opts})

  describe "build/1" do
    test "no option means no limit" do
      assert Limits.build([]) == %{max_active: nil, rate: nil}
      assert Ramal.Supervisor.build_config([]).limits == %{max_active: nil, rate: nil}
    end

    test "a value that is not what the option takes stops the supervisor from starting" do
      for bad <- [0, -1, 1.5, "10", :many] do
        assert_raise ArgumentError,
                     ~r/:max_active_branches must be a positive integer or nil/,
                     fn ->
                       Limits.build(max_active_branches: bad)
                     end
      end

      for bad <- [10, {0, 1000}, {10, 0}, {10, 1.5}, {10}, [10, 1000]] do
        assert_raise ArgumentError,
                     ~r/:branch_rate must be \{count, window_in_milliseconds\}/,
                     fn ->
                       Limits.build(branch_rate: bad)
                     end
      end
    end
  end

  describe "with no limit set" do
    test "branches and forks are created as before" do
      start([])

      for _ <- 1..30 do
        assert {:ok, branch} = Ramal.branch(Farm)
        assert {:ok, _fork} = Ramal.fork(branch)
      end

      assert {:ok, branches} = Ramal.list(Farm)
      assert length(branches) == 60
    end

    test "nothing is counted in the supervisor's table" do
      start([])
      {:ok, branch} = Ramal.branch(Farm)
      {:ok, _} = Ramal.fork(branch)

      assert :ets.match(Ramal.Supervisor.table(), {{:rate, :_, :_}, :_}) == []
    end
  end

  for {label, storage_opts} <- [
        ets: [storage: Ramal.Storage.ETS],
        postgres: [storage: Ramal.Storage.Postgres, repo: Ramal.TestRepo],
        "a storage without count/3": [storage: NoCount]
      ] do
    describe "max_active_branches with #{label}" do
      setup do
        start([max_active_branches: 2] ++ unquote(storage_opts))
        :ok
      end

      test "refuses a branch past the limit and says which limit and how many are active" do
        assert {:ok, _} = Ramal.branch(Farm)
        assert {:ok, _} = Ramal.branch(Farm)

        assert {:error, %Error{reason: :limit_reached} = error} = Ramal.branch(Farm)
        assert %{limit: :max_active_branches, max: 2, active: 2, domain: Farm} = error.details
        assert error.message =~ ":max_active_branches is 2"
        assert {:ok, branches} = Ramal.list(Farm)
        assert length(branches) == 2
      end

      test "a fork counts like a branch" do
        {:ok, branch} = Ramal.branch(Farm)
        assert {:ok, _fork} = Ramal.fork(branch)

        assert {:error, %Error{reason: :limit_reached}} = Ramal.fork(branch)
        assert {:error, %Error{reason: :limit_reached}} = Ramal.branch(Farm)
      end

      test "a proposed branch still counts, a discarded or merged one does not" do
        {:ok, first} = Ramal.branch(Farm)
        {:ok, second} = Ramal.branch(Farm)
        {:ok, _} = Ramal.propose(second)
        assert {:error, %Error{reason: :limit_reached}} = Ramal.branch(Farm)

        :ok = Ramal.discard(first)
        assert {:ok, third} = Ramal.branch(Farm)
        assert {:error, %Error{reason: :limit_reached}} = Ramal.branch(Farm)

        assert {:ok, _} = Ramal.merge(third, authorize?: false)
        assert {:ok, _} = Ramal.branch(Farm)
      end

      test "another domain is counted on its own" do
        {:ok, _} = Ramal.branch(Farm)
        {:ok, _} = Ramal.branch(Farm)

        assert {:ok, _} = Ramal.branch(Ramal.Test.Capture)
      end

      test "a refusal for a branch that is not open comes first" do
        {:ok, branch} = Ramal.branch(Farm)
        {:ok, _} = Ramal.branch(Farm)
        :ok = Ramal.discard(branch)
        {:ok, _} = Ramal.branch(Farm)

        assert {:error, %Error{reason: :not_open}} = Ramal.fork(branch)
      end
    end
  end

  describe "branch_rate" do
    test "refuses creations past the count in the window, branches and forks together" do
      start(branch_rate: {3, @rate_window})

      {:ok, branch} = Ramal.branch(Farm)
      {:ok, _} = Ramal.fork(branch)
      {:ok, _} = Ramal.fork(branch)

      assert {:error, %Error{reason: :limit_reached} = error} = Ramal.fork(branch)
      assert %{limit: :branch_rate, max: 3, window: @rate_window, domain: Farm} = error.details
      assert {:error, %Error{reason: :limit_reached}} = Ramal.branch(Farm)
    end

    test "a refused call creates nothing" do
      start(branch_rate: {1, @rate_window})
      {:ok, _} = Ramal.branch(Farm)
      {:error, _} = Ramal.branch(Farm)

      assert {:ok, [_only]} = Ramal.list(Farm)
    end

    test "each domain has its own count" do
      start(branch_rate: {1, @rate_window})

      assert {:ok, _} = Ramal.branch(Farm)
      assert {:error, %Error{reason: :limit_reached}} = Ramal.branch(Farm)
      assert {:ok, _} = Ramal.branch(Ramal.Test.Capture)
    end

    test "concurrent callers cannot get past it" do
      start(branch_rate: {5, @rate_window})

      results =
        1..40
        |> Task.async_stream(fn _ -> Ramal.branch(Farm) end, max_concurrency: 40)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 5
      assert Enum.count(results, &match?({:error, %Error{reason: :limit_reached}}, &1)) == 35
    end

    test "a new window starts the count again and forgets the old one" do
      start(branch_rate: {1, 30})

      assert {:ok, _} = Ramal.branch(Farm)
      Process.sleep(40)
      assert {:ok, _} = Ramal.branch(Farm)

      assert [[_current]] = :ets.match(Ramal.Supervisor.table(), {{:rate, Farm, :"$1"}, :_})
    end
  end

  describe "both limits" do
    test "the one that is reached first answers" do
      start(max_active_branches: 1, branch_rate: {10, @rate_window})

      {:ok, _} = Ramal.branch(Farm)

      assert {:error, %Error{details: %{limit: :max_active_branches}}} = Ramal.branch(Farm)
    end
  end

  describe "telemetry" do
    test "a refusal emits [:ramal, :limit, :reached] with the domain, the operation and the limit" do
      start(max_active_branches: 1)
      id = "limits-test-#{System.unique_integer([:positive])}"
      test = self()

      :telemetry.attach(
        id,
        [:ramal, :limit, :reached],
        fn _event, _measurements, metadata, _ -> send(test, {:limit, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      {:ok, branch} = Ramal.branch(Farm)
      {:error, _} = Ramal.branch(Farm)
      {:error, _} = Ramal.fork(branch)

      assert_receive {:limit, %{domain: Farm, operation: :branch, limit: :max_active_branches}}
      assert_receive {:limit, %{domain: Farm, operation: :fork, limit: :max_active_branches}}
    end
  end

  describe "a limit that cannot be checked" do
    test "refuses the call with the storage error instead of letting it through" do
      start(max_active_branches: 5, storage: Ramal.Storage.Postgres, repo: nil)

      assert {:error, %Error{reason: :storage}} = Ramal.branch(Farm)
    end
  end
end
