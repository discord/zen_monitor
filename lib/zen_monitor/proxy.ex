defmodule ZenMonitor.Proxy do
  @moduledoc """
  ZenMonitor.Proxy monitors local processes and proxies their down messages to interested
  ZenMonitor.Locals on remote nodes for fanout.
  """
  use GenServer

  alias ZenMonitor.Truncator
  alias ZenMonitor.Proxy.{Batcher, Tables}

  @typedoc """
  Defines the valid operations that can be processed
  """
  @type operation :: :subscribe | :unsubscribe

  @typedoc """
  An instruction is a valid operation upon a given destination
  """
  @type instruction :: {operation, ZenMonitor.destination()}

  @typedoc """
  A string of instructions with the same operation can be collapsed into a partition for more
  efficient processing.
  """
  @type partition :: {operation, [ZenMonitor.destination()]}

  defmodule State do
    @moduledoc """
    Maintains the internal state for ZenMonitor.Proxy

    `monitors` is an ETS table with all the pids that the Proxy is currently monitoring
    """
    @type t :: %__MODULE__{
            monitors: :ets.tid()
          }
    defstruct [
      :monitors
    ]
  end

  ## Client

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @doc """
  Ping is a diagnostic function to check that the proxy is running.

  It is mainly used by ZenMonitor.Local.Connectors to check if ZenMonitor.Proxy is available
  and running on a remote node
  """
  @spec ping() :: :pong
  def ping() do
    GenServer.call(__MODULE__, :ping)
  end

  ## Server

  def init(_args) do
    {:ok, %State{monitors: :ets.new(:monitors, [:private, :set])}}
  end

  def handle_call(:ping, _from, %State{} = state) do
    {:reply, :pong, state}
  end

  def handle_cast({:subscribe, subscriber, targets}, %State{} = state) do
    process_operation(:subscribe, subscriber, targets, state)
    {:noreply, state}
  end

  def handle_cast({:process, subscriber, instructions}, %State{} = state) do
    # Create the most efficient instruction partitions
    for {operation, targets} <- partition_instructions(instructions) do
      process_operation(operation, subscriber, targets, state)
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, _, :process, pid, reason}, %State{monitors: monitors} = state) do
    # Reasons can include stack traces and other dangerous items, truncate them.
    truncated_reason = Truncator.truncate(reason)

    # Enqueue the death certificates with the interested subscriber's batchers
    for [subscriber] <- :ets.match(Tables.subscribers(), {{pid, :"$1"}}) do
      # Delete the subscription
      :ets.delete(Tables.subscribers(), {pid, subscriber})

      # Enqueue the death certificate with the Batcher
      subscriber
      |> Batcher.get()
      |> Batcher.enqueue(pid, truncated_reason)
    end

    # Clear the monitor
    :ets.delete(monitors, pid)

    {:noreply, state}
  end

  ## Private

  @spec process_operation(
          operation,
          subscriber :: pid(),
          targets :: [ZenMonitor.destination()],
          State.t()
        ) :: :ok
  defp process_operation(:subscribe, subscriber, targets, %State{monitors: monitors}) do
    # Record that the subscriber is interested in the targets
    :ets.insert(Tables.subscribers(), Enum.map(targets, &{{&1, subscriber}}))

    # Record and monitor each of the pids, filtering out already monitored pids
    for target <- targets,
        :ets.insert_new(monitors, {target}) do
      Process.monitor(target)
    end

    :ok
  end

  defp process_operation(:unsubscribe, subscriber, targets, _state) do
    # Remove the subscriptions from the subscribers table
    for target <- targets do
      :ets.delete(Tables.subscribers(), {target, subscriber})
    end

    :ok
  end

  @spec partition_instructions([instruction]) :: [partition]
  defp partition_instructions(instructions) do
    do_partition_instructions(instructions, [])
  end

  @spec do_partition_instructions([instruction], [partition]) :: [partition]
  defp do_partition_instructions([], acc) do
    # There are no more instructions to process, the accumulator now has all the partitions, but
    # in reverse order, reverse and return it
    Enum.reverse(acc)
  end

  defp do_partition_instructions([{op, target} | rest], acc) do
    # Inspect the first instruction in the instruction list, collect all the targets with that
    # operation into a new partition.
    {partition, remaining} = do_collect_targets(op, rest, [target])

    # Recursively process any remaining instructions after prepending in the new partition into
    # the accumulator
    do_partition_instructions(remaining, [{op, partition} | acc])
  end

  @spec do_collect_targets(operation, [instruction], [ZenMonitor.destination()]) ::
          {[ZenMonitor.destination()], [instruction]}
  defp do_collect_targets(_op, [], acc) do
    # There are no more instructions to process, return the accumulator.  Note that since
    # instructions of the same operation are commutative there is no need to reverse the
    # accumulator even though the targets are in reverse order
    {acc, []}
  end

  defp do_collect_targets(op, [{op, target} | rest], acc) do
    # The next instruction matches the current operation, prepend the target into the accumulator
    # and recursively process the rest of the instructions
    do_collect_targets(op, rest, [target | acc])
  end

  defp do_collect_targets(_op, [{_other, _} | _rest] = remainder, acc) do
    # The next instruction does not match the current operations.  Similar to when there are no
    # more instructions to process, the accumulator is returned as-is.  The remaining instructions
    # (including the current instruction that didn't match) are returned for further processing.
    {acc, remainder}
  end
end
