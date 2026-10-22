defmodule RamalLive.RouterTest do
  use ExUnit.Case, async: true

  alias RamalLive.Router

  test "the options become a config with a default debounce" do
    assert Router.__config__!(domain: MyApp.Farm, pubsub: MyApp.PubSub) == %{
             domain: MyApp.Farm,
             pubsub: MyApp.PubSub,
             actor: nil,
             debounce: 50
           }
  end

  test "actor and debounce are kept" do
    config =
      Router.__config__!(
        domain: MyApp.Farm,
        pubsub: MyApp.PubSub,
        actor: {MyApp.Inspector, :actor},
        debounce: 0
      )

    assert config.actor == {MyApp.Inspector, :actor}
    assert config.debounce == 0
  end

  test "the domain and the pubsub are required" do
    assert_raise ArgumentError, ~r/:domain option is required/, fn ->
      Router.__config__!(pubsub: MyApp.PubSub)
    end

    assert_raise ArgumentError, ~r/:pubsub option is required/, fn ->
      Router.__config__!(domain: MyApp.Farm)
    end
  end

  test "an unknown option is refused, so a typo does not silently do nothing" do
    assert_raise ArgumentError, ~r/unknown options \[:debounse\]/, fn ->
      Router.__config__!(domain: MyApp.Farm, pubsub: MyApp.PubSub, debounse: 0)
    end
  end

  test "values of the wrong kind are refused" do
    base = [domain: MyApp.Farm, pubsub: MyApp.PubSub]

    assert_raise ArgumentError, ~r/:domain must be a module/, fn ->
      Router.__config__!(Keyword.put(base, :domain, "Farm"))
    end

    assert_raise ArgumentError, ~r/:domain must be a module/, fn ->
      Router.__config__!(Keyword.put(base, :domain, nil))
    end

    assert_raise ArgumentError, ~r/:actor must be/, fn ->
      Router.__config__!(base ++ [actor: &is_nil/1])
    end

    assert_raise ArgumentError, ~r/:debounce must be/, fn ->
      Router.__config__!(base ++ [debounce: -1])
    end

    assert_raise ArgumentError, ~r/expected a keyword list/, fn -> Router.__config__!(:farm) end
  end

  test "the macro mounts one route per call, with its options as route metadata" do
    routes = Phoenix.Router.routes(RamalLive.Test.Router)
    paths = for %{plug: Phoenix.LiveView.Plug, path: path} <- routes, do: path

    assert "/ramal" in paths
    assert "/ramal-debounced" in paths
    assert "/ramal-actor" in paths

    assert %{ramal_inspector: %{domain: RamalLive.Test.Farm, debounce: 40}} =
             Phoenix.Router.route_info(
               RamalLive.Test.Router,
               "GET",
               "/ramal-debounced",
               "localhost"
             )
  end

  test "an option that is wrong stops the router from compiling" do
    assert_raise ArgumentError, ~r/the :pubsub option is required/, fn ->
      Code.eval_string("""
      defmodule RamalLive.RouterTest.Broken do
        use Phoenix.Router
        import RamalLive.Router

        ramal_inspector "/ramal", domain: MyApp.Farm
      end
      """)
    end
  end
end
