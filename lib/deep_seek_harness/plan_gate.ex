defmodule DeepSeekHarness.PlanGate do
  @moduledoc """
  Pure decision logic for DSH's hardcoded "plan -> approve -> execute" gate.

  When a batch of tool calls looks non-trivial (>= 2 file-modifying calls), the
  agent is expected to pause and present a plan for approval before executing.
  This module classifies tool calls, counts modifiers, decides whether the plan
  gate is needed, renders a readable plan, and maps the user's approval-modal
  selection to a decision atom.
  """

  @file_modifiers ~w(write_file replace_file edit_file git_commit)

  # Marker substrings (lowercased) that make a bash command "write-ish/destructive".
  @bash_write_markers [
    "rm ",
    "rm -rf",
    "rm -r",
    "sed -i",
    "mv ",
    "cp ",
    "git commit",
    "git push",
    "git add",
    "git reset",
    "git rm",
    "mkdir",
    "touch",
    "tee",
    "dd ",
    "mkfs",
    "drop database",
    "curl -o",
    "curl --output",
    "wget ",
    "cargo publish",
    "mix hex.publish"
  ]

  @doc """
  Returns true when a tool call is considered file-modifying (write-ish/destructive).

  `tool_name` may be a binary or atom. `args` is a string-keyed map (may be empty).
  A call counts if its name is `write_file`, `replace_file`, `edit_file`, or
  `git_commit`; or if its name is `bash` and its `"command"` looks write-ish.
  """
  def modifier_tool?(tool_name, args \\ %{}) do
    name = normalize_name(tool_name)

    cond do
      name in @file_modifiers -> true
      name == "bash" -> write_ish_bash?(args)
      true -> false
    end
  end

  @doc """
  Returns true when a bash `"command"` string looks write-ish/destructive.

  Pure read-only commands (`ls`, `cat`, `grep`, `git status`, `mix test`, ...)
  return false. Redirection tokens are only counted when they appear as real
  tokens, guarding against false positives like `->` or `=>`.
  """
  def write_ish_bash?(args) when is_map(args) do
    case fetch_command(args) do
      "" -> false
      command -> write_ish_command?(String.downcase(command))
    end
  end

  def write_ish_bash?(_), do: false

  @doc """
  Counts how many tool calls in a batch are modifiers.

  Accepts a list of maps with `"name"`/`:name` and `"arguments"`/`:arguments`
  keys (string or atom). Returns a non-negative integer.
  """
  def count_modifiers(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&normalize_call/1)
    |> Enum.count(fn {name, args} -> modifier_tool?(name, args) end)
  end

  def count_modifiers(_), do: 0

  @doc """
  Returns true when a batch of tool calls should trigger the plan gate.

  True when `count_modifiers(tool_calls) >= threshold`. Empty or nil input
  returns false.
  """
  def needs_plan?(tool_calls, threshold \\ 2) do
    is_list(tool_calls) and tool_calls != [] and count_modifiers(tool_calls) >= threshold
  end

  @doc """
  Renders a `plan` map into a short, readable Markdown-ish binary.

  Accepts optional string keys `"summary"`, `"steps"` (a list of strings or
  maps), and `"files"` (a list). Falls back to a friendly notice when there is
  nothing usable to render.
  """
  def render_plan(plan) when is_map(plan) do
    summary = Map.get(plan, "summary", Map.get(plan, :summary, ""))

    steps =
      Map.get(plan, "steps", Map.get(plan, :steps, []))
      |> normalize_steps()

    files =
      Map.get(plan, "files", Map.get(plan, :files, []))
      |> normalize_list()

    if summary == "" and steps == [] and files == [] do
      "(no plan structure provided)"
    else
      [
        if(summary == "", do: nil, else: "## Summary\n\n#{summary}"),
        if(steps == [],
          do: nil,
          else: "## Steps\n\n" <> Enum.map_join(steps, "\n", &("- " <> &1))
        ),
        if(files == [],
          do: nil,
          else: "## Files\n\n" <> Enum.map_join(files, "\n", &("- `" <> &1 <> "`"))
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")
    end
  end

  def render_plan(_), do: "(no plan structure provided)"

  @doc """
  Maps a user's approval-modal selection to a decision atom.

  Options are matched case-insensitively by substring/prefix: `Approve & execute`
  -> `:approve`, `Request changes` -> `:request_changes`, `Deny` -> `:deny`.
  Anything unrecognized returns `:unknown`.
  """
  def decision_from_selection(selected) when is_binary(selected) do
    down = String.downcase(selected)

    cond do
      String.contains?(down, "approve") -> :approve
      String.contains?(down, "request") or String.contains?(down, "changes") -> :request_changes
      String.contains?(down, "deny") -> :deny
      true -> :unknown
    end
  end

  def decision_from_selection(_), do: :unknown

  # --- Private helpers ---

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name
  defp normalize_name(_), do: ""

  defp fetch_command(args) do
    args
    |> Map.get("command", Map.get(args, :command, ""))
    |> to_string()
  end

  defp write_ish_command?(command) do
    cond do
      Enum.any?(@bash_write_markers, &String.contains?(command, &1)) -> true
      has_real_redirection?(command) -> true
      true -> false
    end
  end

  # A real redirection token is `>` or `>>` surrounded by whitespace or the
  # start/end of the string -- NOT the `>` inside `->` or `=>`.
  defp has_real_redirection?(command) do
    Regex.match?(~r/(^|\s)(>>|>)(\s|$)/, command)
  end

  defp normalize_call(call) when is_map(call) do
    name =
      call
      |> Map.get("name", Map.get(call, :name, ""))
      |> normalize_name()

    args =
      case Map.get(call, "arguments", Map.get(call, :arguments, %{})) do
        %{} = map when map_size(map) > 0 ->
          map

        _ ->
          # Fall back to a top-level bash `command`/`command` key.
          case Map.get(call, "command", Map.get(call, :command)) do
            nil -> %{}
            cmd -> %{"command" => to_string(cmd)}
          end
      end

    {name, args}
  end

  defp normalize_call(_), do: {"", %{}}

  defp normalize_steps(steps) when is_list(steps) do
    Enum.map(steps, fn
      step when is_binary(step) -> step
      step when is_map(step) -> Map.get(step, "description", Map.get(step, :description, ""))
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_steps(_), do: []

  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(_), do: []
end
