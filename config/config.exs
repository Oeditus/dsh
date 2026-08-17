import Config

# Configure dllb client application
config :dllb,
  enabled: true,
  host: System.get_env("DLLB_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("DLLB_PORT", "3009")),
  pool_size: String.to_integer(System.get_env("DLLB_POOL_SIZE", "30")),
  timeout: :infinity

# Configure ragex knowledge graph store backend to use global dllb server
# Disable stdio server when embedded in dsh to prevent raw JSON-RPC dumps
config :ragex,
  store_backend: :dllb,
  dllb_mode: :global,
  start_stdio_server: false

if config_env() == :test do
  config :deep_seek_harness, auto_start_ragex: false
  config :dllb, enabled: false
end
