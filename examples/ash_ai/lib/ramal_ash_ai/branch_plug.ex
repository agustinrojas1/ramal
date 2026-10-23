defmodule RamalAshAiExample.BranchPlug do
  @moduledoc """
  Puts every tool call of an MCP request in the branch the caller owns.

  The client names the branch in a header, so the header is not trusted: the branch must belong to the caller, or any
  client could read and write any branch. The caller is the actor the host's authentication put on the conn
  (`Ash.PlugHelpers.get_actor/1`); here the actor is a map with an `:id`.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with [branch_id] <- get_req_header(conn, "x-ramal-branch"),
         %{id: actor_id} <- Ash.PlugHelpers.get_actor(conn),
         {:ok, %Ramal.Branch{owner: ^actor_id, status: :open}} <- Ramal.get(branch_id) do
      Ash.PlugHelpers.set_context(conn, Ramal.context(branch_id))
    else
      _ -> conn |> send_resp(404, "no such branch") |> halt()
    end
  end
end
