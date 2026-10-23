defmodule Ramal.TestRepo.Migrations.AddRamalBranchOwner do
  use Ecto.Migration

  # Created by `mix ramal.gen.migration`. Adding a stored generated column rewrites the table once.
  def up do
    execute """
    ALTER TABLE ramal_branches ADD COLUMN IF NOT EXISTS owner jsonb
      GENERATED ALWAYS AS (NULLIF(state -> 'owner', 'null'::jsonb)) STORED
    """

    execute """
    CREATE INDEX IF NOT EXISTS ramal_branches_owner_index ON ramal_branches USING hash (owner)
      WHERE owner IS NOT NULL
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS ramal_branches_owner_index"
    execute "ALTER TABLE ramal_branches DROP COLUMN IF EXISTS owner"
  end
end
