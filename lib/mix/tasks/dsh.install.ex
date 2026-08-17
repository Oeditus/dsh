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

    release_bin =
      Path.join([
        repo_dir,
        "_build",
        "prod",
        "rel",
        "dsh",
        "bin",
        "dsh"
      ])

    script_content = """
    #!/usr/bin/env bash
    set -e
    export DSH_WORKSPACE="$PWD"
    export DSH_REPO_DIR="#{repo_dir}"
    cd "$PWD"
    exec "#{release_bin}" eval "DeepSeekHarness.CLI.Main.main(System.argv())" "$@"
    """

    File.write!(target_wrapper, script_content)
    File.chmod!(target_wrapper, 0o755)

    Mix.shell().info("""
    ✅ DeepSeek Harness installed globally to: #{target_wrapper}

    Ensure '#{bin_dir}' is in your $PATH:
      export PATH="$HOME/.local/bin:$PATH"

    You can now run 'dsh' from ANY project directory!
    """)
  end
end
