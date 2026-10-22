defmodule Ramal do
  @moduledoc """
  Data branches as BEAM processes.

  A branch is a process holding an overlay over an Ash application's data. Inside `run/2`, reads see the base
  data patched with the branch's changes, and writes land in the overlay instead of the data layer. A branch can
  be forked, diffed, merged back through the application's own actions, or discarded.

  Nothing is implemented yet. The public API is specified in `docs/DESIGN.md` and will be filled in milestone 0.1.
  """
end
