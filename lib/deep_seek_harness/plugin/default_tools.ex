defmodule DeepSeekHarness.Plugin.DefaultTools do
  @moduledoc false
  @behaviour DeepSeekHarness.Plugin.Behaviour

  @impl true
  def name, do: "DefaultTools"

  @impl true
  def description,
    do:
      "Provides default workspace tools: read_file, read_files, write_file, replace_file, list_dir, bash, elixir_eval, ask_question, and import_session."

  @impl true
  def tools do
    [
      %{
        name: "read_file",
        description: "Read the full text content of a file given its path.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Relative or absolute path to the file."}
          },
          required: ["path"]
        },
        execute: &read_file/1
      },
      %{
        name: "read_files",
        description:
          "Read several files in parallel in a single tool call. Prefer this over issuing multiple read_file calls when you need to inspect several files at once (e.g. a module and its tests, or a set of related source files). Returns each file's contents delimited by a clear header, so you can see exactly which content belongs to which path. If any file cannot be read, its error is reported inline without failing the others.",
        parameters: %{
          type: "object",
          properties: %{
            paths: %{
              type: "array",
              description: "List of relative or absolute file paths to read.",
              items: %{type: "string"}
            }
          },
          required: ["paths"]
        },
        execute: &read_files/1
      },
      %{
        name: "write_file",
        description: "Write or create a file with specified text content.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Target file path."},
            content: %{type: "string", description: "Content to write into the file."}
          },
          required: ["path", "content"]
        },
        execute: &write_file/1
      },
      %{
        name: "replace_file",
        description: "Replace exact target string with replacement string in a file.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "File path."},
            target: %{type: "string", description: "Exact target substring to find and replace."},
            replacement: %{type: "string", description: "Replacement text."}
          },
          required: ["path", "target", "replacement"]
        },
        execute: &replace_file/1
      },
      %{
        name: "list_dir",
        description: "List directory contents (files and subdirectories).",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Directory path (defaults to current directory '.')."
            }
          },
          required: []
        },
        execute: &list_dir/1
      },
      %{
        name: "bash",
        description:
          "Execute a shell bash command and return standard output / error. NOTE: Use dedicated tools or Ragex MCP tools (ragex_grep, ragex_symbol, ragex_view, read_file, etc.) for code searching, symbol finding, or file viewing instead of raw bash shell commands.",
        parameters: %{
          type: "object",
          properties: %{
            command: %{type: "string", description: "The bash command string to execute."}
          },
          required: ["command"]
        },
        execute: &execute_bash/1
      },
      %{
        name: "elixir_eval",
        description:
          "Evaluates Elixir code string directly in the runtime and returns the result.",
        parameters: %{
          type: "object",
          properties: %{
            code: %{type: "string", description: "Elixir code snippet to evaluate."}
          },
          required: ["code"]
        },
        execute: &evaluate_elixir/1
      },
      %{
        name: "ask_question",
        description:
          "Ask the user one or more multiple-choice questions or request user feedback/clarification via interactive CLI UI modal.",
        parameters: %{
          type: "object",
          properties: %{
            questions: %{
              type: "array",
              description: "The list of questions to ask the user.",
              items: %{
                type: "object",
                properties: %{
                  question: %{
                    type: "string",
                    description: "The question prompt to ask the user."
                  },
                  options: %{
                    type: "array",
                    items: %{type: "string"},
                    description: "List of selectable options for the user."
                  },
                  is_multi_select: %{
                    type: "boolean",
                    description: "Whether the user can select multiple options (default: false)."
                  }
                },
                required: ["question", "options"]
              }
            }
          },
          required: ["questions"]
        },
        execute: &ask_question/1
      },
      %{
        name: "import_session",
        description:
          "Imports an externally-produced session JSON file into DSH's own on-disk session store (.dsh/sessions/<id>.json), so it can be resumed via /resume or /session switch. Accepts a top-level {\"messages\": [...]} object, a bare JSON array of messages, or the native session/export schema. Replaces converting/importing sessions via an external script.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Path to the source session JSON file to import."
            },
            session_id: %{
              type: "string",
              description:
                "Target session ID to import as (defaults to the source file's own 'session_id', or a freshly generated ID)."
            },
            overwrite: %{
              type: "boolean",
              description:
                "Whether to overwrite an existing session with the same ID (default: false)."
            }
          },
          required: ["path"]
        },
        execute: &import_session/1
      },
      %{
        name: "run_workflow",
        description:
          "Runs a customizable, multi-step DSH workflow end-to-end (e.g. 'elixir': create a branch, summarize the task, propose a non-clashing parallel split, require tests + docs, lint, and commit). Use this ONLY when the user explicitly asks to run/kick off/start a named workflow for a task -- it can take a long time and may pause for interactive user confirmation (branch warnings, split-plan approval).",
        parameters: %{
          type: "object",
          properties: %{
            workflow: %{
              type: "string",
              description:
                "Name of the workflow to run (e.g. 'elixir'). See /workflow list for available names."
            },
            task_description: %{
              type: "string",
              description: "The task to accomplish, in the user's own words."
            }
          },
          required: ["workflow", "task_description"]
        },
        execute: &run_workflow/1
      },
      %{
        name: "glob_search",
        description: "Find files in the workspace matching a glob pattern (e.g. 'lib/**/*.ex').",
        parameters: %{
          type: "object",
          properties: %{
            pattern: %{type: "string", description: "Glob pattern to match files."}
          },
          required: ["pattern"]
        },
        execute: &glob_search/1
      },
      %{
        name: "run_linter",
        description:
          "Run native Elixir linters and tools (oeditus_credo, propwise, credo, dialyzer) against whole project, diff, or CR targets.",
        parameters: %{
          type: "object",
          properties: %{
            args: %{
              type: "string",
              description:
                "Linter command arguments (e.g. 'propwise cr main', 'oeditus_credo diff', 'propwise', 'all cr main')."
            }
          },
          required: ["args"]
        },
        execute: &linter_tool/1
      },
      %{
        name: "yaml_format",
        description: "Formats JSON or YAML text with pretty indentation.",
        parameters: %{
          type: "object",
          properties: %{
            text: %{type: "string", description: "JSON or YAML formatted text."}
          },
          required: ["text"]
        },
        execute: &yaml_format/1
      },
      %{
        name: "git_status",
        description: "Returns active repository git status (short format).",
        parameters: %{type: "object", properties: %{}},
        execute: &git_status_tool/1
      },
      %{
        name: "git_diff",
        description: "Returns workspace git diff.",
        parameters: %{type: "object", properties: %{}},
        execute: &git_diff_tool/1
      },
      %{
        name: "git_commit",
        description:
          "Stages workspace changes and creates a git commit with the specified message.",
        parameters: %{
          type: "object",
          properties: %{
            message: %{type: "string", description: "Commit message."}
          },
          required: ["message"]
        },
        execute: &git_commit_tool/1
      }
    ]
  end

  def read_file(%{"path" => path}) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Failed to read file '#{path}': #{inspect(reason)}"}
    end
  end

  @doc """
  Reads several files concurrently in a single tool call.

  Each file is read in its own `Task` (bounded concurrency) and the results
  are collated back into the original order, so a slow file never blocks the
  others. Every file's content is wrapped in a clear `=== File: <path> ===`
  header (or an inline error if it could not be read), letting the model
  attribute each block to the right path at a glance.
  """
  def read_files(%{"paths" => paths}) when is_list(paths) do
    paths
    |> Enum.with_index()
    |> Task.async_stream(
      fn {path, _idx} ->
        case File.read(path) do
          {:ok, content} -> {:ok, path, content}
          {:error, reason} -> {:error, path, reason}
        end
      end,
      max_concurrency: System.schedulers_online(),
      ordered: true,
      timeout: 30_000
    )
    |> Enum.map_join("\n", fn
      {:ok, {:ok, path, content}} ->
        "=== File: #{path} ===\n#{content}\n"

      {:ok, {:error, path, reason}} ->
        "=== File: #{path} ===\n[ERROR] Failed to read file: #{inspect(reason)}\n"

      {:exit, reason} ->
        "[ERROR] A file read crashed: #{inspect(reason)}\n"
    end)
    |> then(&{:ok, &1})
  end

  def read_files(%{"paths" => paths}) do
    {:error,
     "Invalid 'paths' argument for read_files. Expected a list of file paths, got: #{inspect(paths)}"}
  end

  def read_files(_args) do
    {:error,
     "Invalid arguments for read_files. Expected a 'paths' list of file paths to read, e.g. %{\"paths\" => [\"a.ex\", \"b.ex\"]}"}
  end

  def write_file(%{"path" => path, "content" => content}) do
    with :ok <- path |> Path.dirname() |> File.mkdir_p(),
         :ok <- File.write(path, content) do
      {:ok, "Successfully wrote #{byte_size(content)} bytes to #{path}"}
    else
      {:error, reason} -> {:error, "Failed to write file '#{path}': #{inspect(reason)}"}
    end
  end

  def replace_file(%{"path" => path, "target" => target, "replacement" => replacement}) do
    case File.read(path) do
      {:ok, content} ->
        if String.contains?(content, target) do
          updated = String.replace(content, target, replacement)

          case File.write(path, updated) do
            :ok -> {:ok, "Successfully replaced target text in #{path}"}
            {:error, reason} -> {:error, "Failed to write to file '#{path}': #{inspect(reason)}"}
          end
        else
          {:error, "Target text not found in #{path}"}
        end

      {:error, reason} ->
        {:error, "Failed to read file '#{path}': #{inspect(reason)}"}
    end
  end

  def list_dir(args) do
    dir = Map.get(args, "path", ".")

    case File.ls(dir) do
      {:ok, files} ->
        detailed = Enum.map_join(files, "\n", &format_file_entry(dir, &1))
        {:ok, "Contents of #{dir}:\n" <> detailed}

      {:error, reason} ->
        {:error, "Failed to list directory '#{dir}': #{inspect(reason)}"}
    end
  end

  defp format_file_entry(dir, f) do
    type = if File.dir?(Path.join(dir, f)), do: "[DIR]", else: "[FILE]"
    "#{type} #{f}"
  end

  def execute_bash(%{"command" => cmd}) do
    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:ok, "Command exited with status #{code}:\n#{output}"}
    end
  rescue
    e -> {:error, "Execution exception: #{inspect(e)}"}
  end

  def evaluate_elixir(%{"code" => code}) do
    {result, _bindings} = Code.eval_string(code)
    {:ok, inspect(result, pretty: true)}
  rescue
    e -> {:error, "Evaluation exception: #{Exception.format(:error, e, __STACKTRACE__)}"}
  end

  def ask_question(args) do
    questions =
      cond do
        is_list(args["questions"]) -> args["questions"]
        is_binary(args["question"]) and is_list(args["options"]) -> [args]
        true -> []
      end

    if questions == [] do
      {:error,
       "Invalid arguments for ask_question. Expected 'questions' list containing 'question' and 'options'."}
    else
      # Pause the spinner while the question modal is displayed so its
      # periodic terminal redraws don't interleave with the modal's output.
      result =
        DeepSeekHarness.CLI.Spinner.with_paused(fn ->
          DeepSeekHarness.CLI.QuestionPrompt.ask(questions)
        end)

      {:ok, result}
    end
  end

  def import_session(%{"path" => path} = args) do
    opts = [
      session_id: Map.get(args, "session_id"),
      overwrite: Map.get(args, "overwrite", false)
    ]

    case DeepSeekHarness.Brain.SessionStore.import_session(path, opts) do
      {:ok, session_id, file_path} ->
        {:ok, "Imported session '#{session_id}' -> #{file_path}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def import_session(_args) do
    {:error, "Invalid arguments for import_session. Expected 'path' to a session JSON file."}
  end

  def run_workflow(%{"workflow" => name, "task_description" => description})
      when is_binary(name) and is_binary(description) do
    case DeepSeekHarness.Workflow.Engine.run(name, seed_prompt: description) do
      {:ok, context} ->
        {:ok, "Workflow '#{name}' completed successfully (run '#{context.run_id}')."}

      {:halt, reason} ->
        {:ok, "Workflow '#{name}' halted before completion: #{reason}"}

      {:error, reason} ->
        {:error, "Workflow '#{name}' failed: #{inspect(reason)}"}
    end
  end

  def run_workflow(_args) do
    {:error,
     "Invalid arguments for run_workflow. Expected 'workflow' (name) and 'task_description' strings."}
  end

  def glob_search(%{"pattern" => pattern}) do
    matches = Path.wildcard(pattern)

    if Enum.empty?(matches) do
      {:ok, "No files matched pattern: '#{pattern}'"}
    else
      {:ok, "Matched #{length(matches)} files:\n" <> Enum.join(matches, "\n")}
    end
  end

  def yaml_format(%{"text" => text}) do
    case Jason.decode(text) do
      {:ok, data} -> {:ok, Jason.encode!(data, pretty: true)}
      {:error, _} -> {:ok, String.trim(text)}
    end
  end

  def git_status_tool(_args) do
    case DeepSeekHarness.Git.status() do
      {:ok, out} -> {:ok, out}
      {:error, err} -> {:error, err}
    end
  end

  def git_diff_tool(_args) do
    case DeepSeekHarness.Git.diff() do
      {:ok, out} -> {:ok, out}
      {:error, err} -> {:error, err}
    end
  end

  def git_commit_tool(%{"message" => message}) do
    case DeepSeekHarness.Git.commit(message) do
      {:ok, out} -> {:ok, out}
      {:error, err} -> {:error, err}
    end
  end

  def linter_tool(%{"args" => args}) do
    case DeepSeekHarness.Linter.run(args) do
      {:ok, out} -> {:ok, out}
      {:error, err} -> {:error, err}
    end
  end
end
