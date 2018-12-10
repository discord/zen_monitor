use Mix.Config

config :zen_monitor,
  connector_sweep_interval: 10,
  batcher_sweep_interval: 10,
  demand_interval: 10,
  demand_amount: 1000

config :logger, :console,
  format: "$time [$level] $levelpad | $metadata |    $message\n",
  metadata: [:module, :function, :line]
