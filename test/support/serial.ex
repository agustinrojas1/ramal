defmodule Ramal.Test.Serial do
  @moduledoc false
  # Resources whose primary key the database generates (ADR 0042): Note has a serial integer key, Tag a uuid key from
  # a column default. A Note can point at a parent Note and at a Tag, so a test can create a row and a row that refers
  # to it in one branch.
  use Ash.Domain, otp_app: :ramal, validate_config_inclusion?: false

  resources do
    resource(Ramal.Test.Serial.Note)
    resource(Ramal.Test.Serial.Tag)
  end
end

defmodule Ramal.Test.Serial.Note do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Serial,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("serial_notes")
    repo(Ramal.TestRepo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    # A hook that creates a row whose key the database generates: the Note that annotates this one.
    update :annotate do
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, note ->
          Ash.create!(__MODULE__, %{body: "annotation", parent_id: note.id}, authorize?: false)
          {:ok, note}
        end)
      end)
    end

    # A create whose hook creates another Note, the same resource as the action itself, so the key plan of a replay
    # (ADR 0041, 0042) must not hand the hook's key to the action or the action's to the hook.
    create :create_with_sibling do
      accept([:body])

      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, note ->
          Ash.create!(__MODULE__, %{body: note.body <> " sibling"}, authorize?: false)
          {:ok, note}
        end)
      end)
    end

    create :create_with_sibling_early do
      accept([:body])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          body = Ash.Changeset.get_attribute(changeset, :body)
          Ash.create!(__MODULE__, %{body: body <> " sibling"}, authorize?: false)
          changeset
        end)
      end)
    end

    # The same through a managed relationship: the parent is a Note too, created by Ash around the action's write.
    create :create_with_parent do
      accept([:body])
      argument(:parent, :map, allow_nil?: false)
      change(manage_relationship(:parent, type: :create))
    end

    # An upsert on the code: a Note whose key the database generates, found by something other than its key.
    create :upsert do
      accept([:code, :body, :parent_id])
      upsert?(true)
      upsert_identity(:unique_code)
      upsert_fields([:body, :parent_id])
    end
  end

  identities do
    identity(:unique_code, [:code])
  end

  attributes do
    integer_primary_key(:id)
    attribute(:body, :string, public?: true)
    attribute(:code, :string, public?: true)
  end

  relationships do
    belongs_to(:parent, __MODULE__, attribute_type: :integer, public?: true)
    belongs_to(:tag, Ramal.Test.Serial.Tag, attribute_type: :uuid, public?: true)
  end
end

defmodule Ramal.Test.Serial.Tag do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Serial,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("serial_tags")
    repo(Ramal.TestRepo)
    migration_defaults(id: "fragment(\"gen_random_uuid()\")")
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    attribute(:id, :uuid,
      primary_key?: true,
      allow_nil?: false,
      generated?: true,
      writable?: false
    )

    attribute(:label, :string, public?: true)
  end
end
