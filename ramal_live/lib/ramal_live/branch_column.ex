defmodule RamalLive.BranchColumn do
  @moduledoc false
  # One branch on the board. It is a LiveComponent, with no state of its own, so that LiveView tracks each column's
  # assigns separately: when one branch changes, only that column's markup is sent, and the clock tick that updates the
  # ages does not resend anyone's diff. The buttons carry no `phx-target`, so their events reach
  # `RamalLive.InspectorLive`.

  use Phoenix.LiveComponent

  alias RamalLive.Column

  @impl true
  def render(assigns) do
    ~H"""
    <article id={@id} class="rl-col" data-status={@column.status} aria-labelledby={"#{@id}-name"}>
      <header class="rl-col-head">
        <span class="rl-dot" aria-hidden="true"></span>
        <h2 id={"#{@id}-name"}>{@column.name || "unnamed branch"}</h2>
        <span class="rl-status">{@column.status}</span>
      </header>

      <dl class="rl-meta rl-data">
        <dt>id</dt>
        <dd title={@column.id}>{Column.short_id(@column.id)}</dd>
        <dt>age</dt>
        <dd>{Column.age(@column.inserted_at, @now)}</dd>
        <dt>overlay</dt>
        <dd>{count(@column.overlay_size, "row")} · {count(@column.write_count, "write")}</dd>
        <dt :if={@column.forked_from}>forked from</dt>
        <dd :if={@column.forked_from} title={@column.forked_from}>
          {Column.short_id(@column.forked_from)}
        </dd>
      </dl>

      <div :if={@column.proposal} class="rl-proposal">
        Proposed by <span class="rl-data">{@column.proposal.proposer}</span>
        <span :if={@column.proposal.reason}>: “{@column.proposal.reason}”</span>
      </div>

      <ul :if={@column.changes != []} class="rl-changes">
        <li :for={change <- @column.changes} class="rl-change">
          <div class="rl-change-head">
            <span class="rl-kind" data-kind={change.kind}>{change.kind}</span>
            <span title={change.resource_title}>{change.resource}</span>
            <code>{change.key}</code>
          </div>
          <table class="rl-rows rl-data">
            <thead>
              <tr>
                <th scope="col" aria-label="attribute"></th>
                <th scope="col">before</th>
                <th scope="col">after</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- change.rows}>
                <th scope="row">{row.attribute}</th>
                <td class="rl-before">{row.before}</td>
                <td class="rl-after">{row.after}</td>
              </tr>
            </tbody>
          </table>
        </li>
        <li :if={@column.hidden_changes > 0} class="rl-none">
          … and {count(@column.hidden_changes, "more change")} not shown
        </li>
      </ul>
      <p :if={@column.changes == [] and is_nil(@column.problem)} class="rl-none">No changes yet.</p>

      <p :if={@column.problem} class="rl-notice" data-kind="error" role="alert">
        The diff could not be read: {@column.problem}
      </p>

      <p
        :if={@column.notice}
        class="rl-notice"
        data-kind={@column.notice.kind}
        role={if @column.notice.kind == :error, do: "alert"}
      >
        {@column.notice.text}
      </p>

      <div class="rl-actions">
        <%= cond do %>
          <% @column.busy -> %>
            <button type="button" class="rl-btn" disabled>{busy_label(@column.busy)}</button>
          <% @confirm -> %>
            <p class="rl-confirm" role="alert">{question(@confirm, @column)}</p>
            <button
              type="button"
              class="rl-btn"
              data-variant="danger"
              phx-click="confirm"
              phx-value-id={@column.id}
              phx-value-action={@confirm}
            >
              Yes, {@confirm}
            </button>
            <button type="button" class="rl-btn" phx-click="cancel">Cancel</button>
          <% true -> %>
            <button
              :for={action <- actions(@column.status)}
              type="button"
              class="rl-btn"
              data-variant={if action == :fork, do: "primary"}
              phx-click={if action == :fork, do: "fork", else: "ask"}
              phx-value-id={@column.id}
              phx-value-action={action}
            >
              {action}
            </button>
        <% end %>
      </div>
    </article>
    """
  end

  # What can be done to a branch in each status. Forking needs an open branch, and a proposal can only be decided;
  # withdrawing one is the proposer's `Ramal.discard/1`, not the inspector's.
  defp actions(:open), do: [:fork, :merge, :discard]
  defp actions(:proposed), do: [:approve, :reject]
  defp actions(_status), do: []

  defp busy_label(:merge), do: "Merging…"
  defp busy_label(:approve), do: "Approving…"

  defp question(:merge, column),
    do:
      "Merge #{count(Column.change_count(column), "change")} into the database? Each logged action runs again, with its validations and policies."

  defp question(:approve, column),
    do: "Approve and merge #{count(Column.change_count(column), "change")} into the database?"

  defp question(:discard, _column), do: "Discard this branch? Its changes are lost."

  defp question(:reject, _column),
    do: "Reject this proposal? The branch is kept as a record, but it can no longer be merged."

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
