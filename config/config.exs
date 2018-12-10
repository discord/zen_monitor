use Mix.Config

config :zen_monitor,
  gen_module: GenServer,
  connector_sweep_interval: 100,
  batcher_sweep_interval: 100,
  demand_interval: 100,
  demand_amount: 1000,
  max_binary_size: 1024,
  truncation_depth: 3

import_config "#{Mix.env()}.exs"
