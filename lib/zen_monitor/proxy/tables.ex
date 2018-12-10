defmodule ZenMonitor.Proxy.Tables do
  @moduledoc """
  `ZenMonitor.Proxy.Tables` owns the tables that are shared between multiple `ZenMonitor.Proxy`
  components.

  See `subscribers/0` for more information.
  """
  use GenServer

  @subscriber_table Module.concat(__MODULE__, "Subscribers")

  ## Client

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Subscribers holds information about who is subscribed to each pid.

  This information is stored in the following structure:

  { { monitored_pid, subscriber } }
    ^-----------key-------------^

  `monitored_pid` is the local process that is being monitored.

  `subscriber` is the remote `ZenMonitor.Local.Connector` that is interested in the `monitored_pid`
  """
  @spec subscribers() :: :ets.tid()
  def subscribers do
    @subscriber_table
  end

  ## Server

  def init(_opts) do
    @subscriber_table =
      :ets.new(@subscriber_table, [:public, :named_table, :ordered_set, write_concurrency: true])

    {:ok, nil}
  end
end
