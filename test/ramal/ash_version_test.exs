defmodule Ramal.AshVersionTest do
  use ExUnit.Case, async: true

  alias Ramal.Ash

  doctest Ramal.Ash

  @range "~> 3.36.0 or ~> 3.37.0"

  describe "check_version/2" do
    test "a version inside the tested range is ok" do
      assert Ash.check_version(:ash, "3.36.1") == :ok
      assert Ash.check_version(:ash, "3.37.0") == :ok
    end

    test "a version below the tested range is untested" do
      assert Ash.check_version(:ash, "3.35.0") == {:untested, "3.35.0", @range}
    end

    test "a version above the tested range is untested" do
      assert Ash.check_version(:ash, "3.38.0") == {:untested, "3.38.0", @range}
    end

    test "a pre-release of a tested version is untested" do
      assert Ash.check_version(:ash, "3.37.0-dev") == {:untested, "3.37.0-dev", @range}
    end

    test "AshPostgres is checked against its own range" do
      assert Ash.check_version(:ash_postgres, "2.15.1") == :ok
      assert Ash.check_version(:ash_postgres, "2.16.0") == {:untested, "2.16.0", "~> 2.15.0"}
    end

    test "an app that is not installed is ok" do
      assert Ash.check_version(:ash_postgres, nil) == :ok
      assert Ash.check_version(:ash, nil) == :ok
    end

    test "a version string Version cannot parse is untested, not an error" do
      assert Ash.check_version(:ash, "latest") == {:untested, "latest", @range}
    end
  end

  describe "tested_range/1" do
    test "Ash is tested on 3.36 and 3.37" do
      assert Ash.tested_range(:ash) == @range
    end

    test "AshPostgres is tested on 2.15" do
      assert Ash.tested_range(:ash_postgres) == "~> 2.15.0"
    end
  end

  describe "the tested range and mix.lock" do
    # The Ash matrix (RAMAL_ASH_VERSION in mix.exs) resolves other versions into mix.lock on purpose, so the guard
    # checks the locked versions only when the matrix is not running.
    @tag skip:
           System.get_env("RAMAL_ASH_VERSION", "") != "" &&
             "RAMAL_ASH_VERSION resolves other versions"
    test "the locked Ash and AshPostgres are inside the tested range" do
      # A regex, not Code.eval_file: the lock's quoted keys make the compiler warn about them.
      lock = File.read!(Path.expand("../../mix.lock", __DIR__))
      [_, ash] = Regex.run(~r/"ash": \{:hex, :ash, "([^"]+)"/, lock)
      [_, ash_postgres] = Regex.run(~r/"ash_postgres": \{:hex, :ash_postgres, "([^"]+)"/, lock)

      assert Ash.installed_version(:ash) == ash
      assert Ash.installed_version(:ash_postgres) == ash_postgres
      assert Ash.check_version(:ash, ash) == :ok
      assert Ash.check_version(:ash_postgres, ash_postgres) == :ok
    end
  end

  describe "untested_message/3" do
    test "names the app, the version and the tested range" do
      message = Ash.untested_message(:ash, "3.35.0", @range)

      assert message =~ "ash 3.35.0"
      assert message =~ @range
      assert message =~ "Ramal.Ash"
    end
  end
end
