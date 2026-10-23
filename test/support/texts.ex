defmodule Ramal.Test.Texts do
  @moduledoc false
  # A domain of its own for the text collation tests (ADR 0045): the Farm domain's tests count its resources, and these
  # columns need a migration with explicit collations.
  use Ash.Domain, otp_app: :ramal, validate_config_inclusion?: false

  resources do
    resource(Ramal.Test.Texts.Tag)
  end
end

defmodule Ramal.Test.Texts.Tag do
  @moduledoc false
  # One text column for each way Postgres can order text (priv/test_repo/migrations/*_add_tags.exs sets the collations;
  # AshPostgres' migration generator does not know them): the database default, `C`, ICU's root locale and `citext`.
  use Ash.Resource,
    domain: Ramal.Test.Texts,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("tags")
    repo(Ramal.TestRepo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    read :list do
      pagination(
        offset?: true,
        keyset?: true,
        countable: true,
        required?: false,
        default_limit: 2
      )
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:name_c, :string, public?: true)
    attribute(:name_icu, :string, public?: true)
    attribute(:label, :ci_string, public?: true)
    attribute(:kind, :atom, public?: true, constraints: [one_of: [:alpha, :Beta, :gamma, :Delta]])
    attribute(:rank, :integer, public?: true)
  end

  relationships do
    belongs_to(:parent, __MODULE__, public?: true, attribute_writable?: true)
    has_many(:children, __MODULE__, destination_attribute: :parent_id, public?: true)
  end

  aggregates do
    min(:min_child_name, :children, :name, public?: true)
    max(:max_child_name, :children, :name, public?: true)
    min(:min_child_name_c, :children, :name_c, public?: true)
    min(:min_child_name_icu, :children, :name_icu, public?: true)
    max(:max_child_label, :children, :label, public?: true)
    first(:first_child_name, :children, :name, public?: true, sort: [name: :asc])
    list(:child_names, :children, :name, public?: true, sort: [name: :asc])
    list(:child_names_icu_desc, :children, :name_icu, public?: true, sort: [name_icu: :desc])
  end
end

defmodule Ramal.Test.BrokenRepo do
  @moduledoc false
  # A repo whose queries fail, to prove a collation query that fails is an error and not a wrong order.
  def query(_sql, _params), do: {:error, %RuntimeError{message: "the database is gone"}}
end
