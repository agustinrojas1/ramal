defmodule Ramal.Test.Capture do
  @moduledoc false
  # ETS-backed resources for the write-capture tests that the Farm domain cannot express: a key the database would
  # generate, notifiers, and an action that fails after the capture hook ran. ETS means nothing here touches Postgres.
  use Ash.Domain, otp_app: :ramal, validate_config_inclusion?: false

  resources do
    resource(Ramal.Test.Capture.Ticket)
    resource(Ramal.Test.Capture.Announced)
    resource(Ramal.Test.Capture.Silent)
    resource(Ramal.Test.Capture.Flaky)
    resource(Ramal.Test.Capture.Counter)
  end
end

defmodule Ramal.Test.Capture.Notifier do
  @moduledoc false
  use Ash.Notifier

  # A test registers itself as :ramal_test_notifications to hear what was sent.
  @impl true
  def notify(%Ash.Notifier.Notification{resource: resource, action: action}) do
    if pid = Process.whereis(:ramal_test_notifications) do
      send(pid, {:notified, resource, action.name})
    end

    :ok
  end
end

defmodule Ramal.Test.Capture.Ticket do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Capture,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource]

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    # The database would generate this key; ETS does not, so a branch cannot know it.
    integer_primary_key(:id)
    attribute(:title, :string, public?: true)
  end
end

defmodule Ramal.Test.Capture.Announced do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Capture,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource],
    notifiers: [Ramal.Test.Capture.Notifier]

  ramal do
    notify_in_branch?(true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:text, :string, public?: true)
  end
end

defmodule Ramal.Test.Capture.Silent do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Capture,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource],
    notifiers: [Ramal.Test.Capture.Notifier]

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:text, :string, public?: true)
  end
end

defmodule Ramal.Test.Capture.Flaky do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Capture,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource]

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    # Fails after the capture hook has written, like a database constraint raised by a later hook would.
    create :create_then_fail do
      accept([:text])

      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, _record ->
          {:error, "the after_action hook refused"}
        end)
      end)
    end

    create :upsert do
      accept([:text])
      upsert?(true)
      upsert_identity(:unique_text)
    end

    create :create_then_raise do
      accept([:text])

      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, _record -> raise "boom" end)
      end)
    end
  end

  identities do
    identity(:unique_text, [:text], pre_check_with: Ramal.Test.Capture)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:text, :string, public?: true)
  end
end

defmodule Ramal.Test.Capture.Counter do
  @moduledoc false
  # Updates that carry an atomic expression, which Ash hands to the data layer instead of putting it in the attributes.
  use Ash.Resource,
    domain: Ramal.Test.Capture,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource]

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    update :bump do
      require_atomic?(false)
      accept([:label])
      change(atomic_update(:n, expr(n + 1)))
    end

    update :bump_and_double do
      require_atomic?(false)
      accept([])
      change(atomic_update(:n, expr(n + 1)))
      change(atomic_update(:m, expr(m * 2)))
    end

    update :bump_in_the_database do
      require_atomic?(false)
      accept([])
      change(atomic_update(:n, expr(fragment("? + 1", n))))
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
    attribute(:n, :integer, public?: true, default: 0)
    attribute(:m, :integer, public?: true, default: 1)
  end
end

defmodule Ramal.Test.Tenanted do
  @moduledoc false
  # Resources that use multitenancy, to prove a branch refuses a tenant instead of mixing tenants in one overlay.
  use Ash.Domain, otp_app: :ramal, validate_config_inclusion?: false

  resources do
    resource(Ramal.Test.Tenanted.Task)
    resource(Ramal.Test.Tenanted.Shared)
  end
end

defmodule Ramal.Test.Tenanted.Task do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Tenanted,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource]

  multitenancy do
    strategy(:attribute)
    attribute(:org_id)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org_id, :string, public?: true, allow_nil?: false)
    attribute(:title, :string, public?: true)
  end
end

defmodule Ramal.Test.Tenanted.Shared do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Tenanted,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource]

  multitenancy do
    strategy(:attribute)
    attribute(:org_id)
    global?(true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org_id, :string, public?: true)
    attribute(:title, :string, public?: true)
  end
end
