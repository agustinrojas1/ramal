defmodule Ramal.AshSeamTest do
  # Ramal.Ash is the only module under lib/ that calls an Ash internal or reads an Ash internal context key: the seam
  # functions there each name the tripwire that guards them (test/ramal/ash_contract_test.exs). This test reads the source
  # of every other file under lib/ and fails when one of them still does it directly.
  #
  # Lines that are not code are skipped: comments (a line whose first non-blank character is `#`) and the text of
  # `@moduledoc`, `@doc` and `@typedoc` heredocs, which describe Ash in prose and are never run. Everything else counts.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @seam Path.join(@root, "lib/ramal/ash.ex")
  @heredoc_end "\"\"\""
  @heredoc_starts [~s(@moduledoc """), ~s(@doc """), ~s(@typedoc """)]

  # Text that only an Ash internal produces: an internal module or function, an internal context key, the lateral-join
  # context. `:accessing_from`, `full_count:` and `:bypass_max_page_size` are the keys themselves, not the names of
  # Ramal's own helpers that happen to contain the word.
  @patterns [
    "Ash.Actions.",
    "[:private]",
    ".private",
    "private:",
    ":internal?",
    ":query_for",
    ":accessing_from",
    ":bypass_max_page_size",
    "full_count:",
    "lateral_join_source",
    "__lateral_join_source__",
    "set_result(",
    "Ash.Filter.list_refs",
    "Ash.Filter.map(",
    "Ash.Filter.hydrate_refs",
    "Ash.Filter.Runtime",
    "Runtime.filter_matches",
    "Ash.Query.do_filter",
    "Sort.runtime_sort",
    "Sort.sorting_on_identity?",
    "Relationships.has_parent_expr?",
    "Read.unpaginated_read"
  ]

  # `{file, pattern}` pairs that may stay, each with the reason, relative to the project root. Empty: every touch of an
  # Ash internal is in Ramal.Ash.
  @allowlist []

  test "no module but Ramal.Ash touches an Ash internal" do
    files = lib_files()
    assert files != [], "the seam test found no source under #{@root}/lib"

    violations =
      for file <- files,
          relative <- [Path.relative_to(file, @root)],
          {line, number} <- code_lines(File.read!(file)),
          pattern <- @patterns,
          String.contains?(line, pattern),
          {relative, pattern} not in @allowlist,
          do:
            "#{relative}:#{number} contains #{inspect(pattern)}: an Ash internal, so route it through Ramal.Ash " <>
              "(add a seam there with its tripwire test)"

    case violations do
      [] -> :ok
      _ -> flunk(Enum.join(violations, "\n"))
    end
  end

  defp lib_files do
    @root
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&(&1 == @seam))
  end

  # The lines of `source` that are code, as `{line, line_number}`.
  defp code_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], false}, fn {line, number}, {acc, in_doc?} ->
      trimmed = String.trim(line)

      cond do
        in_doc? and trimmed == @heredoc_end -> {acc, false}
        in_doc? -> {acc, true}
        trimmed in @heredoc_starts -> {acc, true}
        String.starts_with?(trimmed, "#") -> {acc, false}
        true -> {[{line, number} | acc], false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
