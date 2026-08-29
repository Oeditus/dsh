test_history_path =
  Path.join(System.tmp_dir!(), "dsh_test_history_#{System.unique_integer([:positive])}")

Application.put_env(:deep_seek_harness, :history_file, test_history_path)
Application.put_env(:deep_seek_harness, :auto_start_ragex, false)
Application.put_env(:deep_seek_harness, :system_halt_enabled, false)
Application.put_env(:nx, :default_backend, Nx.BinaryBackend)
Application.put_env(:exla, :start_log_sink, false)

if System.get_env("CI") || System.get_env("GITHUB_ACTIONS") do
  ExUnit.configure(exclude: [ragex: true])
end

ExUnit.start()
