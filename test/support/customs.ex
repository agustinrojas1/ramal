defmodule Ramal.Test.Customs do
  @moduledoc false
  # A domain of its own for the custom type tests (issue 210, test/ramal/custom_types_test.exs): the Farm domain's tests
  # count its resources, and these columns need a table with types the built-in ones do not cover.
  use Ash.Domain, otp_app: :ramal, validate_config_inclusion?: false

  resources do
    resource(Ramal.Test.Customs.Entry)
  end
end

defmodule Ramal.Test.Customs.Label do
  @moduledoc false
  # A NewType over :string that keeps what the user typed: no trimming, and "" is a value, not nil. With the built-in
  # string a branch that turned "" into nil (or " a " into "a") would read differently from the database.
  use Ash.Type.NewType,
    subtype_of: :string,
    constraints: [trim?: false, allow_empty?: true]
end

defmodule Ramal.Test.Customs.Payload do
  @moduledoc false
  # A JSON type with nested lists of maps. The database column is jsonb, which does not keep key order, so the value a
  # read gives back is the normalised one (string keys). The embedded form is the same JSON-safe term.
  use Ash.Type

  @impl true
  def storage_type(_constraints), do: :map

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, _constraints) when is_map(value) or is_list(value),
    do: {:ok, normalise(value)}

  def cast_input(value, constraints) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> cast_input(decoded, constraints)
      _error -> :error
    end
  end

  def cast_input(_value, _constraints), do: :error

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(value, _constraints) when is_map(value) or is_list(value),
    do: {:ok, normalise(value)}

  def cast_stored(_value, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(value, _constraints), do: {:ok, normalise(value)}

  # Keys become strings and atoms become strings, which is what jsonb gives back.
  defp normalise(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), normalise(value)} end)

  defp normalise(list) when is_list(list), do: Enum.map(list, &normalise/1)

  defp normalise(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp normalise(value), do: value
end

defmodule Ramal.Test.Customs.Point do
  @moduledoc false
  # A value that is a struct in Elixir, a float array in the database and, through the default embedded callbacks, the
  # same float array in the branch's storage. Its forms (what a caller passes, the native one, the embedded one) all
  # differ from the struct, as a PostGIS geometry's do (the Geo struct, the database's binary, the GeoJSON map),
  # without PostGIS in the test database (docker-compose.yml and the CI jobs run plain postgres:16).
  use Ash.Type

  defstruct [:lat, :lon]

  @impl true
  def storage_type(_constraints), do: {:array, :float}

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(%__MODULE__{lat: lat, lon: lon}, _constraints), do: from_pair(lat, lon)
  def cast_input([lat, lon], _constraints), do: from_pair(lat, lon)
  def cast_input(%{"lat" => lat, "lon" => lon}, _constraints), do: from_pair(lat, lon)
  def cast_input(%{lat: lat, lon: lon}, _constraints), do: from_pair(lat, lon)
  def cast_input(_value, _constraints), do: :error

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored([lat, lon], _constraints), do: from_pair(lat, lon)
  def cast_stored(_value, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(%__MODULE__{lat: lat, lon: lon}, _constraints), do: {:ok, [lat, lon]}
  def dump_to_native(_value, _constraints), do: :error

  defp from_pair(lat, lon) when is_number(lat) and is_number(lon),
    do: {:ok, %__MODULE__{lat: lat * 1.0, lon: lon * 1.0}}

  defp from_pair(_lat, _lon), do: :error
end

defmodule Ramal.Test.Customs.Entry do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Customs,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("custom_entries")
    repo(Ramal.TestRepo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:label, Ramal.Test.Customs.Label, public?: true)
    attribute(:payload, Ramal.Test.Customs.Payload, public?: true)
    attribute(:point, Ramal.Test.Customs.Point, public?: true)
  end
end
