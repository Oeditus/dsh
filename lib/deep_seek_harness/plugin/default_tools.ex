defmodule DeepSeekHarness.Plugin.DefaultTools do
  @behaviour DeepSeekHarness.Plugin.Behaviour

  @impl true
  def name, do: "DefaultTools"

  @impl true
  def description, do: "Provides default workspace tools: read_file, write_file, replace_file, list_dir, bash, and elixir_eval."

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
            path: %{type: "string", description: "Directory path (defaults to current directory '.')."}
          },
          required: []
        },
        execute: &list_dir/1
      },
      %{
        name: "bash",
        description: "Execute a shell bash command and return standard output / error.",
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
        description: "Evaluates Elixir code string directly in the runtime and returns the result.",
        parameters: %{
          type: "object",
          properties: %{
            code: %{type: "string", description: "Elixir code snippet to evaluate."}
          },
          required: ["code"]
        },
        execute: &evaluate_elixir/1
      }
    ]
  end

  def read_file(%{"path" => path}) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Failed to read file '#{path}': #{inspect(reason)}"}
    end
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
        detailed =
          files
          |> Enum.map(fn f ->
            full = Path.join(dir, f)
            type = if File.dir?(full), do: "[DIR]", else: "[FILE]"
            "#{type} #{f}"
          end)
          |> Enum.join("\n")

        {:ok, "Contents of #{dir}:\n" <> detailed}

      {:error, reason} ->
        {:error, "Failed to list directory '#{dir}': #{inspect(reason)}"}
    end
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
end
