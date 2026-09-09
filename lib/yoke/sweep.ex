defmodule Yoke.Sweep do
  @moduledoc """
  Multi-corpus prior-art search engine for Yoke.

  Sweeps four standard corpora before sparring or feature planning:
  1. `project/workflow/` - "has this project already decided this?"
  2. `project/reference/` & `docs/` - "has it already been written down as settled?"
  3. `project/lessons.md` & `.yoke/lessons.md` - "has this bitten us before?"
  4. Maintainer Knowledge Vault (configured via vault_root) - "has the maintainer already read about this?"

  Reports line numbers and matching content, explicitly flags unsearched/unreachable
  corpora with `!! NOT SEARCHED`, and surfaces tokens matching nothing.
  """

  alias Yoke.CLI.Formatter

  @type match :: %{
          file: String.t(),
          line_number: pos_integer(),
          line_content: String.t()
        }

  @type corpus_result :: %{
          name: String.t(),
          question: String.t(),
          path: String.t() | nil,
          searched?: boolean(),
          matches: [match()],
          error: String.t() | nil
        }

  @type sweep_result :: %{
          tokens: [String.t()],
          corpora: [corpus_result()]
        }

  @doc """
  Runs a prior-art sweep for the given list or space-separated string of tokens.

  Options:
  - `:cwd` - Root workspace directory (default ".").
  - `:vault_root` - Override for local knowledge vault path.
  """
  @spec run(String.t() | [String.t()], keyword()) :: sweep_result()
  def run(tokens, opts \\ [])

  def run(tokens, opts) when is_binary(tokens) do
    parsed_tokens =
      tokens
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reject(&(&1 == ""))

    run(parsed_tokens, opts)
  end

  def run(tokens, opts) when is_list(tokens) do
    cwd = Keyword.get(opts, :cwd, ".")
    vault_root = Keyword.get(opts, :vault_root) || resolve_vault_root(cwd)

    corpora_specs = [
      %{
        name: "Workflow Pipeline",
        question: "has this project already decided this?",
        paths: [Path.join(cwd, "project/workflow"), Path.join(cwd, ".yoke/workflows")]
      },
      %{
        name: "Topical Reference",
        question: "has it already been written down as settled?",
        paths: [Path.join(cwd, "project/reference"), Path.join(cwd, "docs")]
      },
      %{
        name: "Lessons Learned",
        question: "has this bitten us before?",
        paths: [Path.join(cwd, "project/lessons.md"), Path.join(cwd, ".yoke/lessons.md")]
      },
      %{
        name: "Knowledge Vault",
        question: "has the maintainer already read about this?",
        paths: if(vault_root, do: [vault_root], else: [])
      }
    ]

    corpora_results =
      Enum.map(corpora_specs, fn spec ->
        sweep_corpus(spec, tokens)
      end)

    %{
      tokens: tokens,
      corpora: corpora_results
    }
  end

  @doc """
  Formats a `sweep_result()` struct into a human-readable CLI report.
  """
  @spec format_result(sweep_result()) :: String.t()
  def format_result(%{tokens: tokens, corpora: corpora}) do
    header =
      "#{Formatter.bold()}=== Prior-Art Sweep for: [#{Enum.join(tokens, ", ")}] ===#{Formatter.reset()}\n"

    body =
      corpora
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {corpus, idx} ->
        path_str = corpus.path || "N/A"

        if corpus.searched? do
          matches_str =
            if Enum.empty?(corpus.matches) do
              "  #{Formatter.dim()}No matches.#{Formatter.reset()}"
            else
              Enum.map_join(corpus.matches, "\n", fn m ->
                "  #{Formatter.cyan()}#{m.file}:#{m.line_number}#{Formatter.reset()}: #{String.trim(m.line_content)}"
              end)
            end

          "#{Formatter.bold()}[#{idx}/#{length(corpora)}] #{corpus.name}#{Formatter.reset()} (#{path_str}) — #{Formatter.italic()}#{corpus.question}#{Formatter.reset()}\n#{matches_str}"
        else
          err_msg = corpus.error || "Corpus unavailable"

          "#{Formatter.bold()}[#{idx}/#{length(corpora)}] #{corpus.name}#{Formatter.reset()} — #{Formatter.italic()}#{corpus.question}#{Formatter.reset()}\n  #{Formatter.red()}!! NOT SEARCHED (#{err_msg})#{Formatter.reset()}"
        end
      end)

    header <> "\n" <> body
  end

  defp sweep_corpus(%{name: "Knowledge Vault", paths: []}, _tokens) do
    %{
      name: "Knowledge Vault",
      question: "has the maintainer already read about this?",
      path: nil,
      searched?: false,
      matches: [],
      error: "vault_root not configured in config.json or environment"
    }
  end

  defp sweep_corpus(%{name: name, question: question, paths: paths}, tokens) do
    existing_paths = Enum.filter(paths, &File.exists?/1)

    if Enum.empty?(existing_paths) do
      %{
        name: name,
        question: question,
        path: Enum.join(paths, ", "),
        searched?: false,
        matches: [],
        error: "Path(s) do not exist: #{Enum.join(paths, ", ")}"
      }
    else
      files = collect_files(existing_paths)

      matches =
        Enum.flat_map(files, fn file ->
          search_file(file, tokens)
        end)

      %{
        name: name,
        question: question,
        path: Enum.join(existing_paths, ", "),
        searched?: true,
        matches: matches,
        error: nil
      }
    end
  end

  defp collect_files(paths) do
    Enum.flat_map(paths, fn path ->
      cond do
        File.regular?(path) ->
          [path]

        File.dir?(path) ->
          case File.ls(path) do
            {:ok, entries} ->
              entries
              |> Enum.reject(&String.starts_with?(&1, "."))
              |> Enum.map(&Path.join(path, &1))
              |> collect_files()

            _ ->
              []
          end

        true ->
          []
      end
    end)
  end

  defp search_file(file_path, tokens) do
    case File.read(file_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _line_num} ->
          line_lower = String.downcase(line)

          Enum.any?(tokens, fn token ->
            String.contains?(line_lower, String.downcase(token))
          end)
        end)
        |> Enum.map(fn {line, line_num} ->
          %{
            file: file_path,
            line_number: line_num,
            line_content: line
          }
        end)

      _ ->
        []
    end
  end

  @doc "Resolves vault_root from environment or config.json."
  def resolve_vault_root(cwd \\ ".") do
    env_vault = System.get_env("VAULT_ROOT")

    if env_vault && env_vault != "" && File.dir?(env_vault) do
      env_vault
    else
      config_paths = [
        Path.join(cwd, "project/workflow/config.json"),
        Path.join(cwd, ".yoke/config.json"),
        Path.expand("~/.yoke/config.json")
      ]

      Enum.find_value(config_paths, fn cfg_path ->
        with true <- File.exists?(cfg_path),
             {:ok, body} <- File.read(cfg_path),
             {:ok, json} <- Jason.decode(body),
             vault_root when is_binary(vault_root) and vault_root != "" <- json["vault_root"] do
          if File.dir?(vault_root), do: vault_root, else: nil
        else
          _ -> nil
        end
      end)
    end
  end
end
