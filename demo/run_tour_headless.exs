# Runs the code cells of demo/ramal_tour.livemd one after the other, the way Livebook does (bindings, imports and requires
# carry over from cell to cell), and stops at the first cell that fails. It is how the notebook is checked without a
# browser:
#
#     docker compose -f demo/docker-compose.yml up -d
#     elixir demo/run_tour_headless.exs
#
# The Postgres variables of demo/README.md apply, and so does RAMAL_TOUR_SOURCE=path.

notebook = Path.join(__DIR__, "ramal_tour.livemd")

cells =
  ~r/^```elixir\n(.*?)^```$/ms
  |> Regex.scan(File.read!(notebook), capture: :all_but_first)
  |> Enum.map(fn [code] -> code end)

IO.puts("#{length(cells)} code cells in #{Path.relative_to_cwd(notebook)}")

Enum.reduce(Enum.with_index(cells, 1), {[], __ENV__}, fn {code, n}, {binding, env} ->
  first = code |> String.split("\n", parts: 2) |> hd()
  IO.puts(IO.ANSI.format([:faint, "\n--- cell #{n}: #{first}", :reset]))

  try do
    quoted = Code.string_to_quoted!(code, file: notebook)
    {_result, binding, env} = Code.eval_quoted_with_env(quoted, binding, %{env | file: notebook, line: 1})
    {binding, env}
  rescue
    error ->
      IO.puts(IO.ANSI.format([:red, "cell #{n} failed: #{Exception.format(:error, error, __STACKTRACE__)}", :reset]))
      System.halt(1)
  end
end)

IO.puts(IO.ANSI.format([:green, "\nall #{length(cells)} cells ran", :reset]))
