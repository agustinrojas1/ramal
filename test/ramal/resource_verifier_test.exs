defmodule Ramal.Resource.VerifierTest do
  # The compile-time warnings are what a host sees when a resource keeps a limitation a branch cannot lift. They are
  # warnings, not errors, so the resource still compiles and works outside the action that hits the limit.
  use ExUnit.Case, async: true

  import Spark.Test

  test "a primary key the database generates, with no placeholder, warns" do
    {message, _location} =
      assert_dsl_warning {_, _} do
        defmodule Elixir.Ramal.Test.Verifier.SlugKey do
          use Ash.Resource,
            domain: nil,
            data_layer: Ash.DataLayer.Ets,
            extensions: [Ramal.Resource]

          actions do
            defaults([:read, create: :*])
          end

          attributes do
            attribute(:slug, :string,
              primary_key?: true,
              allow_nil?: false,
              generated?: true,
              writable?: false
            )
          end
        end
      end

    assert message =~ "Ramal.Test.Verifier.SlugKey"
    assert message =~ ":database_generated_key"
  end

  test "a custom aggregate warns" do
    warnings =
      dsl_warnings do
        defmodule Elixir.Ramal.Test.Verifier.Child do
          use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

          actions do
            defaults([:read, create: :*])
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:name, :string, public?: true)
            attribute(:parent_id, :uuid, public?: true)
          end

          relationships do
            belongs_to(:parent, Elixir.Ramal.Test.Verifier.CustomAggregate)
          end
        end

        defmodule Elixir.Ramal.Test.Verifier.CustomAggregate do
          use Ash.Resource,
            domain: nil,
            data_layer: Ash.DataLayer.Ets,
            extensions: [Ramal.Resource]

          actions do
            defaults([:read, create: :*])
          end

          attributes do
            uuid_primary_key(:id)
          end

          relationships do
            has_many(:children, Elixir.Ramal.Test.Verifier.Child)
          end

          aggregates do
            custom(:child_names, :children, :string,
              implementation: {Ramal.Test.Farm.StringAgg, field: :name, delimiter: ","}
            )
          end
        end
      end

    assert [{Elixir.Ramal.Test.Verifier.CustomAggregate, payloads}] = warnings

    assert Enum.any?(payloads, fn {message, _location} ->
             message =~ "child_names" and message =~ ":unpatched_aggregate"
           end)
  end

  test "a database-generated integer key gets a placeholder, so nothing warns" do
    refute_dsl_warnings do
      defmodule Elixir.Ramal.Test.Verifier.IntegerKey do
        use Ash.Resource,
          domain: nil,
          data_layer: Ash.DataLayer.Ets,
          extensions: [Ramal.Resource]

        actions do
          defaults([:read, create: :*])
        end

        attributes do
          attribute(:id, :integer,
            primary_key?: true,
            allow_nil?: false,
            generated?: true,
            writable?: false
          )
        end
      end
    end
  end

  test "warnings? false turns the warning off" do
    refute_dsl_warnings do
      defmodule Elixir.Ramal.Test.Verifier.Quiet do
        use Ash.Resource,
          domain: nil,
          data_layer: Ash.DataLayer.Ets,
          extensions: [Ramal.Resource]

        ramal do
          warnings?(false)
        end

        actions do
          defaults([:read, create: :*])
        end

        attributes do
          attribute(:slug, :string,
            primary_key?: true,
            allow_nil?: false,
            generated?: true,
            writable?: false
          )
        end
      end
    end
  end
end
