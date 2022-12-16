defmodule ZenMonitor do
  @moduledoc """
  ZenMonitor provides efficient monitoring of remote processes and controlled dissemination of
  any resulting `:DOWN` messages.

  This module provides a convenient client interface which aims to be a drop in replacement for
  `Process.monitor/1` and `Process.demonitor/2`

  # Known differences between ZenMonitor and Process

    - `ZenMonitor.demonitor/2` has the same signature as Process.demonitor/2 but does not respect
      the `:info` option.

    - ZenMonitor aims to be efficient over distribution, one of the main strategies for achieving
      this is relying mainly on local monitors and then batching up all changes over a time period
      to be sent as a single message.  This design means that additional latency is added to the
      delivery of down messages in pursuit of the goal.  Where `Process.monitor/1` on a remote
      process will provide a :DOWN message as soon as possible, `ZenMonitor.monitor/1` on a remote
      process will actually have a number of batching periods to go through before the message
      arrives at the monitoring process, here are all the points that add latency.

      1.  When the monitor is enqueued it has to wait until the next sweep happens in the
          `ZenMonitor.Local.Connector` until it will be delivered to the `ZenMonitor.Proxy`.
      1.  The monitor arrives at the `ZenMonitor.Proxy`, the process crashes and the ERTS `:DOWN`
          message is delivered. This will be translated into a death_certificate and sent to a
          `ZenMonitor.Proxy.Batcher` for delivery.  It will have to wait until the next sweep
          happens for it to be sent back to the `ZenMonitor.Local.Connector` for fan-out.
      1.  The dead summary including the death_certificate arrives at the
          `ZenMonitor.Local.Connector` and a down_dispatch is created for it and enqueued with the
          `ZenMonitor.Local`.
      1.  The down_dispatch waits in a queue until the `ZenMonitor.Local.Dispatcher` generates
          more demand.
      1.  Once demand is generated, `ZenMonitor.Local` will hand off the down_dispatch for actual
          delivery by `ZenMonitor.Local.Dispatcher`.

      * Steps 1 and 3 employ a strategy of batch sizing to prevent the message from growing too
        large.  The batch size is controlled by application configuration and is alterable at boot
        and runtime.  This means though that Steps 1 and 3 can be delayed by N intervals
        where `N = ceil(items_ahead_of_event / chunk_size)`
      * Step 4 employs a similar batching strategy, a down_dispatch will wait in queue for up to N
        intervals where `N = ceil(items_ahead_of_dispatch / chunk_size)`

    - `ZenMonitor` decorates the reason of the `:DOWN` message.  If a remote process goes down
      because of `original_reason`, this will get decorated as `{:zen_monitor, original_reason}`
      when delivered by ZenMonitor.  This allows the receiver to differentiate `:DOWN` messages
      originating from `ZenMonitor.monitor/1` and those originating from `Process.monitor/1`.
      This is necessary when operating in mixed mode.  It is the responsibility of the receiver to
      unwrap this reason if it requires the `original_reason` for some additional handling of the
      `:DOWN` message.
  """

  @gen_module GenServer

  @typedoc """
  `ZenMonitor.destination` are all the types that can be monitored.

    - `pid()` either local or remote
    - `{name, node}` represents a named process on the given node
    - `name :: atom()` is a named process on the local node
  """
  @type destination :: pid() | ({name :: atom, node :: node()}) | (name :: atom())

  ## Delegates

  @doc """
  Delegate to `ZenMonitor.Local.compatibility/1`
  """
  defdelegate compatibility(target), to: ZenMonitor.Local

  @doc """
  Delegate to `ZenMonitor.Local.compatibility_for_node/1`
  """
  defdelegate compatibility_for_node(remote), to: ZenMonitor.Local

  @doc """
  Delegate to `ZenMonitor.Local.Connector.connect/1`
  """
  defdelegate connect(remote), to: ZenMonitor.Local.Connector

  @doc """
  Delegate to `ZenMonitor.Local.demonitor/2`
  """
  defdelegate demonitor(ref, options \\ []), to: ZenMonitor.Local

  @doc """
  Delegate to `ZenMonitor.Local.monitor/1`
  """
  defdelegate monitor(target), to: ZenMonitor.Local

  ## Client

  @doc """
  Get the module to use for gen calls from the Application Environment

  This module only needs to support `GenServer.call/3` and `GenServer.cast/3` functionality, see
  ZenMonitor's `@gen_module` for the default value

  This can be controlled at boot and runtime with the `{:zen_monitor, :gen_module}` setting, see
  `ZenMonitor.gen_module/1` for runtime convenience functionality.
  """
  @spec gen_module() :: atom
  def gen_module do
    Application.get_env(:zen_monitor, :gen_module, @gen_module)
  end

  @doc """
  Put the module to use for gen calls into the Application Environment

  This is a simple convenience function for overwriting the `{:zen_monitor, :gen_module}` setting
  at runtime.
  """
  @spec gen_module(value :: atom) :: :ok
  def gen_module(value) do
    Application.put_env(:zen_monitor, :gen_module, value)
  end

  @doc """
  Get the current monotonic time in milliseconds

  This is a helper because `System.monotonic_time(:milliseconds)` is long and error-prone to
  type in multiple call sites.

  See `System.monotonic_time/1` for more information.
  """
  @spec now() :: integer
  def now do
    System.monotonic_time(:milliseconds)
  end

  @doc """
  Find the node for a destination.
  """
  @spec find_node(target :: destination) :: node()
  def find_node(pid) when is_pid(pid), do: node(pid)
  def find_node({_, node}), do: node
  def find_node(_), do: Node.self()
end
