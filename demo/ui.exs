# Printing helpers for the walkthrough: chapter headings, narration, and a pause between chapters. Nothing here is Ramal.

defmodule Demo.UI do
  @moduledoc false
  import IO.ANSI, only: [format: 1]

  # `chapter "title" do ... end` prints a heading with the line of walkthrough.exs it lives on, waits for Enter, then runs
  # the block. `--fast` (or a non-interactive stdin) skips the wait.
  defmacro chapter(title, do: block) do
    line = __CALLER__.line

    quote do
      Demo.UI.heading(unquote(title), unquote(line))
      unquote(block)
    end
  end

  def heading(title, line) do
    n = Process.get(:chapter, 0) + 1
    Process.put(:chapter, n)
    pause()
    IO.puts("")
    IO.puts(format([:bright, :cyan, "━━ #{n}. #{title} ", :faint, "(tour.exs:#{line})", :reset]))
  end

  def pause do
    if interactive?() and not fast?() do
      IO.write(format([:faint, "   [Enter to continue] ", :reset]))
      IO.gets("")
    end

    :ok
  end

  # What the next step does, in plain words.
  def say(text), do: text |> String.split("\n") |> Enum.each(&IO.puts(format(["   ", :bright, &1, :reset])))

  # What came back.
  def show(text), do: text |> String.split("\n") |> Enum.each(&IO.puts("     " <> &1))

  def ok(text), do: IO.puts(format(["   ", :green, "✓ ", text, :reset]))
  def refused(text), do: IO.puts(format(["   ", :yellow, "✗ ", text, :reset]))
  def note(text), do: IO.puts(format(["   ", :faint, text, :reset]))
  def label(text), do: IO.puts(format(["   ", :magenta, text, :reset]))

  # Rows as an aligned table, rows being lists of strings.
  def table(header, rows) do
    all = [header | rows]
    widths = all |> Enum.zip_with(& &1) |> Enum.map(fn col -> col |> Enum.map(&String.length/1) |> Enum.max() end)

    line = fn row ->
      row |> Enum.zip(widths) |> Enum.map_join("  ", fn {cell, w} -> String.pad_trailing(cell, w) end) |> String.trim_trailing()
    end

    show(IO.ANSI.format([:faint, line.(header)]) |> IO.iodata_to_binary())
    Enum.each(rows, &show(line.(&1)))
  end

  defp fast?, do: "--fast" in System.argv()
  defp interactive?, do: match?({:ok, _}, :io.columns()) or System.get_env("RAMAL_DEMO_PAUSE") == "1"
end

defmodule Demo.View do
  @moduledoc false
  # How the walkthrough looks at the farm. `herds/0` goes through Ash, so inside `Ramal.run!/2` it shows the branch's
  # version; `postgres_herds/0` goes around Ash with plain SQL, so it always shows what is really in the database.
  import Demo.UI

  def herds do
    names = paddock_names()

    Farm.Herd
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(&natural(&1.name))
    |> Enum.map(&[&1.name, to_string(&1.head), Map.get(names, &1.paddock_id, "-")])
  end

  def postgres_herds do
    %{rows: rows} =
      Farm.Repo.query!("""
      SELECT h.name, h.head::text, coalesce(p.name, '-')
      FROM herds h LEFT JOIN paddocks p ON p.id = h.paddock_id
      """)

    Enum.sort_by(rows, &natural(hd(&1)))
  end

  def print_herds(rows), do: table(["herd", "head", "paddock"], rows)

  def postgres_moves do
    %{rows: [[n]]} = Farm.Repo.query!("SELECT count(*) FROM moves")
    n
  end

  def herd(name), do: Farm.Herd |> Ash.read!(authorize?: false) |> Enum.find(&(&1.name == name))

  def paddock_names, do: Farm.Paddock |> Ash.read!(authorize?: false) |> Map.new(&{&1.id, &1.name})

  # One line per change, with ids turned back into names so a person can read it.
  def print_diff(changes) do
    names = paddock_names()
    herd_names = Farm.Herd |> Ash.read!(authorize?: false) |> Map.new(&{&1.id, &1.name})

    for change <- changes do
      what =
        case {change.resource, change.kind} do
          {Farm.Herd, :created} -> "herd #{elem(change.changes.name, 1)}"
          {Farm.Herd, _} -> "herd #{Map.get(herd_names, change.key, change.key)}"
          {Farm.Move, _} -> "move log row"
          {other, _} -> inspect(other)
        end

      show("#{String.pad_trailing(to_string(change.kind), 8)} #{what}  (#{fields(change, names, herd_names)})")
    end

    :ok
  end

  # A move log row is described by the move it records; any other row by the attributes that differ.
  defp fields(%{resource: Farm.Move, changes: changes}, names, herd_names) do
    {_, herd_id} = changes.herd_id
    {_, from} = changes.from_paddock_id
    {_, to} = changes.to_paddock_id
    "herd #{Map.get(herd_names, herd_id, "?")}: #{pretty(from, names)} → #{pretty(to, names)}"
  end

  defp fields(%{changes: changes}, names, _herd_names) do
    Enum.map_join(changes, ", ", fn {field, {before, after_value}} ->
      "#{field}: #{pretty(before, names)} → #{pretty(after_value, names)}"
    end)
  end

  def herd_name(id), do: Farm.Herd |> Ash.read!(authorize?: false) |> Enum.find_value("?", &(&1.id == id && &1.name))

  # The message Ash would show a person, not the whole exception.
  def reason({:error, %{errors: [first | _]}}), do: reason_of(first)
  def reason({:error, other}), do: Exception.message(other)

  defp reason_of(%Ash.Error.Forbidden.Policy{}), do: "not authorized (the :move policy needs a manager)"
  defp reason_of(%{message: message}) when is_binary(message), do: message
  defp reason_of(other), do: Exception.message(other)

  defp pretty(nil, _names), do: "nil"
  defp pretty(value, names) when is_map_key(names, value), do: Map.fetch!(names, value)
  defp pretty(value, _names), do: inspect(value)

  # R7 before R10.
  defp natural(name), do: {String.length(name), name}
end
