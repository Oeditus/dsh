defmodule Mix.Tasks.Dsh.Install do
  @moduledoc """
  Installs DeepSeek Harness (`dsh`) globally to `~/.local/bin/dsh`.

  Usage:
      mix dsh.install
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("Building production OTP release for DeepSeek Harness…")

    repo_dir = File.cwd!()
    System.cmd("mix", ["deps.get"], cd: repo_dir, stderr_to_stdout: true)

    case System.cmd("mix", ["release", "--overwrite"],
           cd: repo_dir,
           env: [{"MIX_ENV", "prod"}],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        Mix.shell().info("Release build successful!")
        install_global_wrapper(repo_dir)

      {err, code} ->
        Mix.shell().error("Release build failed (code #{code}):\n#{err}")
    end
  end

  defp install_global_wrapper(repo_dir) do
    bin_dir = Path.expand("~/.local/bin")
    File.mkdir_p!(bin_dir)

    target_wrapper = Path.join(bin_dir, "dsh")
    dsh_launcher = Path.join(repo_dir, "dsh")

    script_content = """
    #!/usr/bin/env bash
    set -e
    export DSH_WORKSPACE="$PWD"
    export DSH_REPO_DIR="#{repo_dir}"
    export DLLB_DIR="${DLLB_DIR:-$(cd "#{repo_dir}/../dllb" 2>/dev/null && pwd || echo "#{repo_dir}/../dllb")}"
    if [ -z "${DLLB_SERVER_BIN:-}" ]; then
      if [ -f "$DLLB_DIR/target/release/dllb-server" ]; then
        export DLLB_SERVER_BIN="$DLLB_DIR/target/release/dllb-server"
      elif [ -f "$DLLB_DIR/target/debug/dllb-server" ]; then
        export DLLB_SERVER_BIN="$DLLB_DIR/target/debug/dllb-server"
      fi
    fi
    cd "$PWD"
    exec "#{dsh_launcher}" --prod "$@"
    """

    File.write!(target_wrapper, script_content)
    File.chmod!(target_wrapper, 0o755)

    Mix.shell().info("""
    󰄬 DeepSeek Harness installed globally to: #{target_wrapper}

    Ensure '#{bin_dir}' is in your $PATH:
      export PATH="$HOME/.local/bin:$PATH"

    You can now run 'dsh' from ANY project directory!
    """)
  end
end
