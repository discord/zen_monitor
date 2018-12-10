defmodule ZenMonitor.Proxy.Supervisor do
  @moduledoc """
  Supervisor for the `ZenMonitor.Proxy` components.

  See `ZenMonitor.Proxy`, `ZenMonitor.Proxy.Tables`, and `ZenMonitor.Proxy.Batcher` for more
  information about the supervised processes.

  There are many `ZenMonitor.Proxy.Batcher` processes, which are managed by a `GenRegistry`.
  These are keyed by the pid of the `ZenMonitor.Local.Connector` the Batcher is responsible for.

  This supervisor uses the `:rest_for_one` strategy, so the order of the children is important and
  should not be altered.
  """
  use Supervisor

  def start_link(_opts \\ []) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_opts) do
    children = [
      ZenMonitor.Proxy.Tables,
      ZenMonitor.Proxy,
      GenRegistry.Spec.child_spec(ZenMonitor.Proxy.Batcher)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
