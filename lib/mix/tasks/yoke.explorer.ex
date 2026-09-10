defmodule Mix.Tasks.Yoke.Explorer do
  @moduledoc """
  Launches the interactive `.yoke` Config Directory Explorer TUI.

  Usage:
      mix yoke.explorer
  """
  use Mix.Task

  @shortdoc "Launches the .yoke Config Directory Explorer TUI"

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:yoke)
    Yoke.CLI.ConfigExplorer.run()
  end
end
