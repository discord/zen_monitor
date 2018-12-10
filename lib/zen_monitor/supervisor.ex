defmodule ZenMonitor.Supervisor do
  @moduledoc """
  ZenMonitor.Supervisor is a convenience Supervisor that starts the Local and Proxy Supervisors

  See ZenMonitor.Local.Supervisor and ZenMonitor.Proxy.Supervisor for more information.
  """
  use Supervisor

  def start_link(_opts \\ []) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_opts) do
    children = [
      ZenMonitor.Local.Supervisor,
      ZenMonitor.Proxy.Supervisor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
