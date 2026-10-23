defmodule Ramal.TestRepo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :ramal

  # The migration generator reads this to pick Postgres features. 16 is what CI and docker-compose run.
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  # The test tenants are created inside each test's sandbox transaction and rolled back, so there is none to migrate.
  def all_tenants, do: []

  def installed_extensions, do: ["ash-functions"]
end
