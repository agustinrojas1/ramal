defmodule Ramal.TestRepo.Migrations.CreateRamalBranches do
  use Ecto.Migration

  # Created by `mix ramal.gen.migration`. `state` holds the overlay, base, log and metadata as Ramal.Storage.Codec
  # writes them.
  def change do
    create table(:ramal_branches, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :domain, :text, null: false
      add :name, :text
      add :status, :text, null: false
      add :state, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:ramal_branches, [:domain, :status])
  end
end
