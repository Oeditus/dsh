test_history_path =
  Path.join(System.tmp_dir!(), "dsh_test_history_#{System.unique_integer([:positive])}")

Application.put_env(:deep_seek_harness, :history_file, test_history_path)
Application.put_env(:deep_seek_harness, :auto_start_ragex, false)

ExUnit.start()
