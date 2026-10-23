defmodule Ramal.TestRepo.Migrations.CreateRamalBranchWrites do
  use Ecto.Migration

  # Created by `mix ramal.gen.migration`. Only a branch with `durable: true` reads or writes it.
  def change do
    create table(:ramal_branch_writes, primary_key: false) do
      add :branch_id, references(:ramal_branches, type: :uuid, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :seq, :bigint, primary_key: true, null: false
      add :delta, :map, null: false
    end
  end
end
