defmodule ZenMonitor.Metrics do
  @moduledoc """
  Metrics helper for monitoring the ZenMonitor system.
  """
  alias Instruments.Probe

  @doc """
  Registers various probes for the ZenMonitor System.

    - ERTS message_queue_len for the `ZenMonitor.Local` and `ZenMonitor.Proxy` processes.
    - Internal Batch Queue length for `ZenMonitor.Local` (dispatches to be delivered)
    - ETS table size for References (number of monitors)
    - ETS table size for Subscribers (number of monitored local processes * interested remotes)

  """
  @spec register() :: :ok
  def register do
    Probe.define!(
      "zen_monitor.local.message_queue_len",
      :gauge,
      mfa: {__MODULE__, :message_queue_len, [ZenMonitor.Local]}
    )

    Probe.define!(
      "zen_monitor.proxy.message_queue_len",
      :gauge,
      mfa: {__MODULE__, :message_queue_len, [ZenMonitor.Proxy]}
    )

    Probe.define!(
      "zen_monitor.local.batch_length",
      :gauge,
      mfa: {ZenMonitor.Local, :batch_length, []}
    )

    Probe.define!(
      "zen_monitor.local.ets.references.size",
      :gauge,
      mfa: {__MODULE__, :table_size, [ZenMonitor.Local.Tables.references()]}
    )

    Probe.define!(
      "zen_monitor.proxy.ets.subscribers.size",
      :gauge,
      mfa: {__MODULE__, :table_size, [ZenMonitor.Proxy.Tables.subscribers()]}
    )

    :ok
  end

  @doc """
  Given a pid or a registered name, this will return the message_queue_len as reported by
  `Process.info/2`
  """
  @spec message_queue_len(target :: nil | pid() | atom()) :: nil | integer()
  def message_queue_len(nil), do: nil

  def message_queue_len(target) when is_pid(target) do
    case Process.info(target, :message_queue_len) do
      {:message_queue_len, len} -> len
      _ -> nil
    end
  end

  def message_queue_len(target) when is_atom(target) do
    target
    |> Process.whereis()
    |> message_queue_len()
  end

  @doc """
  Given a table identifier, returns the size as reported by `:ets.info/2`
  """
  @spec table_size(:ets.tid()) :: nil | integer()
  def table_size(tid) do
    case :ets.info(tid, :size) do
      :undefined -> nil
      size -> size
    end
  end
end
