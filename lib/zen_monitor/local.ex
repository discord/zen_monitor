defmodule ZenMonitor.Local do
  @moduledoc """
  ZenMonitor.Local

  Most of the actual logic of monitoring and fan-out is handled by `ZenMonitor.Local.Connector`,
  see that module for more information.

  `ZenMonitor.Local` is responsible for monitoring the subscribing local processes and cleaning up
  monitors if they crash.
  """
  use GenStage
  use Instruments.CustomFunctions, prefix: "zen_monitor.local"
  alias ZenMonitor.Local.{Connector, Tables}

  @typedoc """
  Effective compatibility of a remote node
  """
  @type compatibility :: :compatible | :incompatible

  @typedoc """
  Represents a future down dispatch for a given pid to be delivered by
  `ZenMonitor.Local.Dispatcher`
  """
  @type down_dispatch :: {pid, {:DOWN, reference, :process, pid, {:zen_monitor, any}}}

  @subscribers_table Module.concat(__MODULE__, "Subscribers")
  @hibernation_threshold 1_000

  defmodule State do
    @moduledoc """
    Maintains the internal state for ZenMonitor.Local

     - `subscribers` is an ETS table that tracks local subscribers to prevent multiple monitors
     - `batch` is the queue of messages awaiting delivery to ZenMonitor.Local.Dispatcher
     - `length` is the current length of the batch queue (calculating queue length is an O(n)
        operation, it is simple to track it as elements are added / removed)
     - `queue_emptied` is the number of times the queue has been emptied.  Once this number
        exceeds the hibernation_threshold (see `hibernation_threshold/0`) the process will
        hibernate
    """

    @type t :: %__MODULE__{
            subscribers: :ets.tid(),
            length: integer,
            queue_emptied: integer,
            batch: :queue.queue()
          }
    defstruct [
      :subscribers,
      length: 0,
      queue_emptied: 0,
      batch: :queue.new()
    ]
  end

  ## Delegates

  defdelegate compatibility_for_node(remote), to: ZenMonitor.Local.Connector, as: :compatibility

  ## Client

  def start_link(_opts \\ []) do
    GenStage.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Begin monitoring the given process

  Has the same semantics as `Process.monitor/1`, DOWN messages will be delivered
  at a pace controlled by the :zen_monitor, :demand_interval and
  :zen_monitor, :demand_amount environment variables
  """
  @spec monitor(target :: ZenMonitor.destination()) :: reference
  def monitor(target) do
    increment("monitor")
    ref = make_ref()
    me = self()

    # Write the reference out
    :ets.insert(Tables.references(), {{me, ref}, target})

    # Enqueue the monitor into the Connector for async monitor
    Connector.monitor(target, ref, me)

    # Perform reciprocal monitoring (if needed)
    unless :ets.member(@subscribers_table, me) do
      GenStage.cast(__MODULE__, {:monitor_subscriber, me})
    end

    # Return the reference to the caller
    ref
  end

  @doc """
  Stop monitoring a process by monitor reference

  Has the same semantics as `Process.demonitor/2` (although you can pass the `:info` option, it
  has no effect and is not honored, `:flush` is honored)
  To demonitor a process you should pass in the reference returned from
  `ZenMonitor.Local.monitor/1` for the given process
  """
  @spec demonitor(ref :: reference, options :: [:flush]) :: true
  def demonitor(ref, options \\ []) when is_reference(ref) do
    increment("demonitor")
    me = self()

    # First consume the reference
    case :ets.take(Tables.references(), {me, ref}) do
      [] ->
        # Unknown reference, maybe it's been dispatched, consume any :DOWN messages in the inbox
        # if :flush is provided.  Dispatch atomically consumes the reference, which is why we only
        # need to scan the inbox if we don't find a reference.
        if :flush in options do
          receive do
            {:DOWN, ^ref, _, _, _} -> nil
          after
            0 ->
              nil
          end
        end

        :ok

      [{{^me, ^ref}, pid}] ->
        # Instruct the Connector to demonitor the monitor
        Connector.demonitor(pid, ref)
    end

    true
  end

  @doc """
  Check the compatiblity of the remote node that owns the provided destination

  This is a simple convenience function that looksup the node for the destination and then calls
  `ZenMonitor.Local.compatiblity_for_node/1`
  """
  @spec compatibility(target :: ZenMonitor.destination()) :: compatibility
  def compatibility(target) do
    target
    |> ZenMonitor.find_node()
    |> compatibility_for_node()
  end

  @doc """
  Asynchronously enqueue a list of down dispatches for delivery by the Dispatcher

  If called with the empty list, cast will be suppressed.
  """
  @spec enqueue(messages :: [down_dispatch]) :: :ok
  def enqueue([]), do: :ok

  def enqueue(messages) do
    GenStage.cast(__MODULE__, {:enqueue, messages})
  end

  @doc """
  Synchronously checks the length of the ZenMonitor.Local's internal batch
  """
  @spec batch_length() :: integer()
  def batch_length do
    GenStage.call(__MODULE__, :batch_length)
  end

  @doc """
  Gets the hibernation threshold from the Application Environment

  Every time the demand empties the queue a counter is incremented.  When this counter exceeds the
  hibernation threshold the ZenMonitor.Local process will be sent into hibernation. See
  ZenMonitor.Local's @hibernation_threshold for the default value

  This can be controlled at boot and runtime with the {:zen_monitor, :hibernation_threshold}
  setting, see ZenMonitor.Local.hibernation_threshold/1 for runtime convenience functionality.
  """
  @spec hibernation_threshold() :: integer
  def hibernation_threshold do
    Application.get_env(:zen_monitor, :hibernation_threshold, @hibernation_threshold)
  end

  @doc """
  Puts the hibernation threshold into the Application Environment

  This is a simple convenience function for overwriting the
  {:zen_monitor, :hibernation_threshold} setting at runtime.
  """
  @spec hibernation_threshold(value :: integer) :: :ok
  def hibernation_threshold(value) do
    Application.put_env(:zen_monitor, :hibernation_threshold, value)
  end

  ## Server

  def init(_opts) do
    Process.flag(:message_queue_data, :off_heap)

    subscribers =
      :ets.new(@subscribers_table, [:protected, :named_table, :set, read_concurrency: true])

    {:producer, %State{subscribers: subscribers}}
  end

  @doc """
  Handles demand from `ZenMonitor.Local.Dispatcher`

  ZenMonitor.Local maintains a queue of pending messages to be sent to local processes, the actual
  dispatch of which are throttled by ZenMonitor.Local.Dispatcher.  When
  ZenMonitor.Local.Dispatcher requests more messages to dispatch, this handler will collect up to
  the requested amount from the batch queue to satisfy the demand.
  """
  def handle_demand(demand, %State{length: length} = state) do
    if length <= demand do
      empty_queue(state)
    else
      chunk_queue(demand, state)
    end
  end

  @doc """
  Handle a local subscriber going down

  When a process establishes a remote monitor, ZenMonitor.Local establishes a reciprocal monitor,
  see monitor/1 and handle_cast({:monitor_subscriber, ...}) for more information.

  If the subscriber crashes, all of the ETS records maintained by ZenMonitor.Local and the various
  ZenMonitor.Local.Connectors is no longer needed and will be cleaned up by this handler.
  """
  def handle_info(
        {:DOWN, _ref, :process, subscriber, _reason},
        %State{subscribers: subscribers} = state
      ) do
    for [ref, remote_pid] <- :ets.match(Tables.references(), {{subscriber, :"$1"}, :"$2"}) do
      # Remove the reference
      :ets.delete(Tables.references(), {subscriber, ref})

      # Instruct the Connector to demonitor
      Connector.demonitor(remote_pid, ref)
    end

    # Remove the subscriber from the subscribers table
    :ets.delete(subscribers, subscriber)

    {:noreply, [], state}
  end

  @doc """
  Handles recipricol subscriber monitoring

  When a process establishes a remote monitor, ZenMonitor.Local will establish a reciprocal
  monitor on the subscriber.  This is done so that appropriate cleanup can happen if the
  subscriber goes down.

  This handler guarantees that a local subscriber will only ever have one active reciprocal
  monitor at a time by tracking the subscribers in an ETS table.
  """
  def handle_cast({:monitor_subscriber, subscriber}, %State{subscribers: subscribers} = state) do
    if :ets.insert_new(subscribers, {subscriber}) do
      Process.monitor(subscriber)
    end

    {:noreply, [], state}
  end

  @doc """
  Handles enqueuing messages for eventual dispatch

  ZenMonitor.Local.Connector is responsible for generating down dispatches and enqueuing them with
  ZenMonitor.Local.  ZenMonitor.Local takes these messages and places them into the
  batch queue to be delivered to ZenMonitor.Local.Dispatcher as demanded.
  """
  def handle_cast({:enqueue, messages}, %State{batch: batch, length: length} = state) do
    {batch, new_length} =
      messages
      |> Enum.reduce({batch, length}, fn item, {acc, len} ->
        {:queue.in(item, acc), len + 1}
      end)

    increment("enqueue", new_length - length)

    {:noreply, [], %State{state | batch: batch, length: new_length}}
  end

  @doc """
  Handles batch length checks

  Returns the current length of the batch
  """
  def handle_call(:batch_length, _from, %State{length: length} = state) do
    {:reply, length, [], state}
  end

  ## Private

  @spec empty_queue(state :: State.t()) ::
          {:noreply, [down_dispatch], State.t()}
          | {:noreply, [down_dispatch], State.t(), :hibernate}
  defp empty_queue(%State{queue_emptied: queue_emptied, batch: batch} = state) do
    new_queue_emptied = queue_emptied + 1
    response = :queue.to_list(batch)

    if new_queue_emptied >= hibernation_threshold() do
      {:noreply, response, %State{state | batch: :queue.new(), length: 0, queue_emptied: 0},
       :hibernate}
    else
      {:noreply, response,
       %State{state | batch: :queue.new(), length: 0, queue_emptied: new_queue_emptied}}
    end
  end

  @spec chunk_queue(size :: integer(), state :: State.t()) ::
          {:noreply, [down_dispatch], State.t()}
  defp chunk_queue(size, %State{batch: batch, length: length} = state) do
    {messages, new_batch} = :queue.split(size, batch)
    {:noreply, :queue.to_list(messages), %State{state | batch: new_batch, length: length - size}}
  end
end
