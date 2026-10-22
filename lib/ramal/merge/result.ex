defmodule Ramal.Merge.Result do
  @moduledoc """
  What `Ramal.merge/2` returns on success.

    * `branch` - the branch, now with status `:merged`
    * `records` - what the replay wrote, keyed like an overlay (`Ramal.Overlay`): `{:created, record}`,
      `{:updated, record}` or `:deleted` per `{resource, key}`, with the records as the real actions returned them
    * `replayed` - how many log entries were replayed; entries written by a hook of another action are not counted,
      because replaying that action ran the hook again
    * `stale` - the rows that had changed under the branch and that `on_stale` let through, each
      `%{resource: module, key: term, reason: :changed | :deleted}`

  ## Example

      %Ramal.Merge.Result{replayed: 2, stale: []} = result
  """

  @type stale_row :: %{resource: module, key: term, reason: :changed | :deleted}

  @type t :: %__MODULE__{
          branch: Ramal.Branch.t(),
          records: Ramal.Overlay.t(),
          replayed: non_neg_integer,
          stale: [stale_row]
        }

  @enforce_keys [:branch]
  defstruct [:branch, records: %{}, replayed: 0, stale: []]
end
