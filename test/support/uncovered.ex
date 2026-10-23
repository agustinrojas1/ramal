defmodule Ramal.Test.Uncovered do
  @moduledoc false
  # A domain with one resource a branch covers, one that has write actions and does not use the extension, and one that
  # opts out explicitly. `Note` is why `Ramal.branch/2` refuses it; `Ramal.Test.OptedOut` shows the explicit way out.
  use Ash.Domain, otp_app: :ramal, validate_config_inclusion?: false

  resources do
    resource(Ramal.Test.Uncovered.Covered)
    resource(Ramal.Test.Uncovered.Note)
  end
end

defmodule Ramal.Test.OptedOut do
  @moduledoc false
  use Ash.Domain, otp_app: :ramal, validate_config_inclusion?: false

  resources do
    resource(Ramal.Test.Uncovered.Covered2)
    resource(Ramal.Test.Uncovered.Log)
    resource(Ramal.Test.Uncovered.Lookup)
  end
end

defmodule Ramal.Test.Uncovered.Covered do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Uncovered,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource]

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end
end

defmodule Ramal.Test.Uncovered.Note do
  @moduledoc false
  use Ash.Resource, domain: Ramal.Test.Uncovered, data_layer: Ash.DataLayer.Ets

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:text, :string, public?: true)
  end
end

defmodule Ramal.Test.Uncovered.Covered2 do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.OptedOut,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource]

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end
end

defmodule Ramal.Test.Uncovered.Log do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.OptedOut,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource]

  ramal do
    branchable?(false)
  end

  actions do
    defaults([:read, create: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:text, :string, public?: true)
  end
end

# No write action, so a branch has nothing to miss.
defmodule Ramal.Test.Uncovered.Lookup do
  @moduledoc false
  use Ash.Resource, domain: Ramal.Test.OptedOut, data_layer: Ash.DataLayer.Ets

  actions do
    defaults([:read])
  end

  attributes do
    uuid_primary_key(:id)
  end
end
