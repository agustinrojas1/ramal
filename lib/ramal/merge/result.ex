defmodule Ramal.Merge.Result do
  @moduledoc """
  What `Ramal.merge/2` returns on success.

    * `branch` - the branch, now with status `:merged`
    * `records` - what the replay wrote, keyed like an overlay (`Ramal.Overlay`): `{:created, record}`,
      `{:updated, record}` or `:deleted` per `{resource, key}`, with the records as the real actions returned them
    * `keys` - for each row a replayed create wrote with a key the database generated, the placeholder the branch gave it
      and the real key: `%{{resource, placeholder} => real_key}`. `records` is keyed by the real key (ADR 0042)
    * `replayed` - how many log entries were replayed; entries written by a hook of another action are not counted,
      because replaying that action ran the hook again
    * `stale` - the rows that had changed under the branch and that `on_stale` let through, each
      `%{resource: module, key: term, reason: :changed | :deleted}`
    * `persist_failed` - `nil`, or the `Ramal.Error` of the storage when the merge committed but the `:merged` status
      could not be stored. The merge happened: the rows are in the database. The branch is `:merged` in its process, which
      writes it again when it unloads; until then the stored copy still says open (ADR 0023, `docs/adr/0023-merge-commit-is-final.md`)

  ## Example

      %Ramal.Merge.Result{replayed: 2, stale: []} = result
  """

  @type stale_row :: %{resource: module, key: term, reason: :changed | :deleted}

  @type t :: %__MODULE__{
          branch: Ramal.Branch.t(),
          records: Ramal.Overlay.t(),
          keys: %{optional({module, term}) => term},
          replayed: non_neg_integer,
          stale: [stale_row],
          persist_failed: Ramal.Error.t() | nil
        }

  @enforce_keys [:branch]
  defstruct [:branch, records: %{}, keys: %{}, replayed: 0, stale: [], persist_failed: nil]
end
