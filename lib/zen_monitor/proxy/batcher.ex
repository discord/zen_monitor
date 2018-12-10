defmodule ZenMonitor.Proxy.Batcher do
  @moduledoc """
  `ZenMonitor.Proxy.Batcher` is responsible for collecting death_certificates from
  `ZenMonitor.Proxy` destined for the Batcher's subscriber (normally the subscriber is a
  `ZenMonitor.Local.Connector`)

  Periodically it will sweep and send all of the death_certificates it has collected since the
  last sweep to the subscriber for processing.
  """
  use GenServer
  use Instruments.CustomFunctions, prefix: "zen_monitor.proxy.batcher"

  alias ZenMonitor.Proxy.Tables

  @chunk_size 5000
  @sweep_interval 100

  defmodule State do
    @moduledoc """
    Maintains the internal state for the Batcher

    - `subscriber` is the process that death_certificates should be delivered to
    - `batch` is the queue of death_certificates pending until the next sweep.
    - `length` is the current length of the batch queue (calculating queue length is an O(n)
      operation, is is simple to track it as elements are added / removed)
    """

    @type t :: %__MODULE__{
            subscriber: pid,
            batch: :queue.queue(),
            length: integer
          }
    defstruct [
      :subscriber,
      batch: :queue.new(),
      length: 0
    ]
  end

  ## Client

  def start_link(subscriber) do
    GenServer.start_link(__MODULE__, subscriber)
  end

  @doc """
  Get a batcher for a given subscriber
  """
  @spec get(subscriber :: pid) :: pid
  def get(subscriber) do
    case GenRegistry.lookup(__MODULE__, subscriber) do
      {:ok, batcher} ->
        batcher

      {:error, :not_found} ->
        {:ok, batcher} = GenRegistry.lookup_or_start(__MODULE__, subscriber, [subscriber])
        batcher
    end
  end

  @doc """
  Enqueues a new death certificate into the batcher
  """
  @spec enqueue(batcher :: pid, pid, reason :: any) :: :ok
  def enqueue(batcher, pid, reason) do
    GenServer.cast(batcher, {:enqueue, pid, reason})
  end

  @doc """
  Gets the sweep interval from the Application Environment

  The sweep interval is the number of milliseconds to wait between sweeps, see
  ZenMonitor.Proxy.Batcher's @sweep_interval for the default value

  This can be controlled at boot and runtime with the {:zen_monitor, :batcher_sweep_interval}
  setting, see `ZenMonitor.Proxy.Batcher.sweep_interval/1` for runtime convenience functionality.
  """
  @spec sweep_interval() :: integer
  def sweep_interval do
    Application.get_env(:zen_monitor, :batcher_sweep_interval, @sweep_interval)
  end

  @doc """
  Puts the sweep interval into the Application Environment

  This is a simple convenience function for overwrite the {:zen_monitor, :batcher_sweep_interval}
  setting at runtime
  """
  @spec sweep_interval(value :: integer) :: :ok
  def sweep_interval(value) do
    Application.put_env(:zen_monitor, :batcher_sweep_interval, value)
  end

  @doc """
  Gets the chunk size from the Application Environment

  The chunk size is the maximum number of death certificates that will be sent during each sweep,
  see ZenMonitor.Proxy.Batcher's @chunk_size for the default value

  This can be controlled at boot and runtime with the {:zen_monitor, :batcher_chunk_size}
  setting, see ZenMonitor.Proxy.Batcher.chunk_size/1 for runtime convenience functionality.
  """
  @spec chunk_size() :: integer
  def chunk_size do
    Application.get_env(:zen_monitor, :batcher_chunk_size, @chunk_size)
  end

  @doc """
  Puts the chunk size into the Application Environment

  This is a simple convenience function for overwrite the {:zen_monitor, :batcher_chunk_size}
  setting at runtime.
  """
  @spec chunk_size(value :: integer) :: :ok
  def chunk_size(value) do
    Application.put_env(:zen_monitor, :batcher_chunk_size, value)
  end

  ## Server

  def init(subscriber) do
    Process.monitor(subscriber)
    schedule_sweep()
    {:ok, %State{subscriber: subscriber}}
  end

  @doc """
  Handle enqueuing a new death_certificate

  Simply puts it in the batch queue.
  """
  def handle_cast({:enqueue, pid, reason}, %State{batch: batch, length: length} = state) do
    increment("enqueue")
    {:noreply, %State{state | batch: :queue.in({pid, reason}, batch), length: length + 1}}
  end

  @doc """
  Handle the subscriber crashing

  When the subscriber crashes there is no point in continuing to run, so the Batcher stops.
  """
  def handle_info(
        {:DOWN, _, :process, subscriber, reason},
        %State{subscriber: subscriber} = state
      ) do
    # The subscriber process has crashed, clean up the subscribers table
    :ets.match_delete(Tables.subscribers(), {{:_, subscriber}})
    {:stop, {:shutdown, {:subscriber_down, reason}}, state}
  end

  @doc """
  Handle sweep

  Every sweep the batcher will send the death_certificates batched up since the last sweep to the
  subscriber.  After that it will schedule another sweep.
  """
  def handle_info(:sweep, %State{} = state) do
    new_state = do_sweep(state)
    schedule_sweep()
    {:noreply, new_state}
  end

  ## Private

  @spec do_sweep(state :: State.t()) :: State.t()
  defp do_sweep(%State{length: 0} = state), do: state

  defp do_sweep(%State{subscriber: subscriber, batch: batch, length: length} = state) do
    {summary, overflow, new_length} = chunk(batch, length)
    increment("sweep", length - new_length)
    Process.send(subscriber, {:dead, node(), :queue.to_list(summary)}, [:noconnect])
    %State{state | batch: overflow, length: new_length}
  end

  @spec chunk(batch :: :queue.queue(), length :: integer) ::
          {:queue.queue(), :queue.queue(), integer}
  defp chunk(batch, length) do
    size = chunk_size()

    if length <= size do
      {batch, :queue.new(), 0}
    else
      {summary, overflow} = :queue.split(size, batch)
      {summary, overflow, length - size}
    end
  end

  @spec schedule_sweep() :: reference
  defp schedule_sweep do
    Process.send_after(self(), :sweep, sweep_interval())
  end
end
