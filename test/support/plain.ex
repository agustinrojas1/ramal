defmodule Ramal.Test.Plain do
  @moduledoc false
  # Two views of the `herds` table that the transparency tests compare with the Farm resources: one without the
  # extension, and one that has it but opted out.
  use Ash.Domain, otp_app: :ramal, validate_config_inclusion?: false

  resources do
    resource(Ramal.Test.Plain.Herd)
    resource(Ramal.Test.Plain.Excluded)
  end
end

defmodule Ramal.Test.Plain.Herd do
  @moduledoc false
  use Ash.Resource, domain: Ramal.Test.Plain, data_layer: AshPostgres.DataLayer

  postgres do
    table("herds")
    repo(Ramal.TestRepo)
  end

  actions do
    defaults([:read])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:head, :integer, public?: true)
    attribute(:paddock_id, :uuid, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end

defmodule Ramal.Test.Plain.Excluded do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Plain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Ramal.Resource]

  postgres do
    table("herds")
    repo(Ramal.TestRepo)
  end

  ramal do
    branchable?(false)
  end

  actions do
    defaults([:read])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:head, :integer, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end

defmodule Ramal.Test.Other do
  @moduledoc false
  # A second branchable domain, so tests can show that a branch lists and reads only its own domain.
  use Ash.Domain, otp_app: :ramal, validate_config_inclusion?: false

  resources do
    resource(Ramal.Test.Other.Note)
    resource(Ramal.Test.Other.Slot)
    resource(Ramal.Test.Other.Account)
    resource(Ramal.Test.Other.Credential)
  end
end

defmodule Ramal.Test.Other.Note do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Other,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource]

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:text, :string, public?: true)
    # The storage codec tests need attribute types with a stored form of their own.
    attribute(:status, :atom, constraints: [one_of: [:draft, :published]], public?: true)
    attribute(:tags, {:array, :string}, public?: true)
    attribute(:payload, :map, public?: true)
    attribute(:score, :decimal, public?: true)
    attribute(:scheduled_on, :date, public?: true)
    attribute(:blob, :binary, public?: true)
    attribute(:anything, :term, public?: true)
  end
end

defmodule Ramal.Test.Other.Slot do
  @moduledoc false
  # A resource with a composite primary key, for the aggregate delta and the overlay keys.
  use Ash.Resource,
    domain: Ramal.Test.Other,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource]

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    attribute(:day, :date, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:bay, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:load, :integer, public?: true)
    attribute(:weight, :decimal, public?: true)
  end
end

defmodule Ramal.Test.Other.Account do
  @moduledoc false
  # An actor-shaped resource with a secret, for the codec's actor redaction.
  use Ash.Resource,
    domain: Ramal.Test.Other,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults([:read])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:email, :string, public?: true)
    attribute(:password_hash, :string, sensitive?: true)
    attribute(:api_token, :string, sensitive?: true, public?: true)
  end
end

defmodule Ramal.Test.Other.Credential do
  @moduledoc false
  # A branchable resource with a secret, for the redaction of diffs that leave the application.
  use Ash.Resource,
    domain: Ramal.Test.Other,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource]

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
    attribute(:secret, :string, sensitive?: true, public?: true)
  end
end
