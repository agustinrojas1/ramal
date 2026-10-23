defmodule Ramal.TestRepo.Migrations.AddRamalBranchEpoch do
  use Ecto.Migration

  # Created by `mix ramal.gen.migration`. Only a Ramal.Supervisor with `cluster: true` reads it.
  def up do
    execute "ALTER TABLE ramal_branches ADD COLUMN IF NOT EXISTS epoch bigint NOT NULL DEFAULT 0"
  end

  def down do
    execute "ALTER TABLE ramal_branches DROP COLUMN IF EXISTS epoch"
  end
end
