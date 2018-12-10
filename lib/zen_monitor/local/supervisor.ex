defmodule ZenMonitor.Local.Supervisor do
  @moduledoc """
  Supervisor for the `ZenMonitor.Local` components.

  See `ZenMonitor.Local`, `ZenMonitor.Local.Tables`, `ZenMonitor.Local.Connector`, and
  `ZenMonitor.Local.Dispatcher` for more information about the supervised processes.

  There are many `ZenMonitor.Local.Connector` processes, which are managed by a `GenRegistry`.
  These are keyed by the remote node the Connector is responsible for.

  This supervisor uses the `:rest_for_one` strategy, so the order of the children is important and
  should not be altered.
  """
  use Supervisor

  def start_link(_opts \\ []) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_opts) do
    children = [
      ZenMonitor.Local.Tables,
      ZenMonitor.Local,
      GenRegistry.Spec.child_spec(ZenMonitor.Local.Connector),
      ZenMonitor.Local.Dispatcher
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
