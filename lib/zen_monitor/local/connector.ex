defmodule ZenMonitor.Local.Connector do
  @moduledoc """
  `ZenMonitor.Local.Connector` performs a variety of duties.  For every remote that a the local
  is interested in monitoring processes on there will be a dedicated `ZenMonitor.Local.Connector`.
  This collection of Connectors are managed by a `GenRegistry` registered under the
  `ZenMonitor.Local.Connector` atom.

  # Connecting and Monitoring the remote `ZenMonitor.Proxy`

  Connectors, as their name suggests, connect to the `ZenMonitor.Proxy` on the remote node that they
  are responsible for.  They do this using standard ERTS Distribution, by invoking the remote
  Proxy's ping command.  A Remote is considered compatible if the ping command returns the :pong
  atom, otherwise it will be marked incompatible.

  Connectors manage their remote node's status in the global node status cache, and provide
  facilities for efficient querying of remote status, see `compatibility/1` and
  `cached_compatibility/1`

  # Batching and Updating the remote `ZenMonitor.Proxy`

  When a local process wishes to monitor a remote process, the Connector will be informed of this
  fact with a call to `monitor/3`.  The Connector is responsible for maintaining a local record of
  this monitor for future fan-out and for efficiently batching up these requests to be delivered
  to the remote ZenMonitor.Proxy.

  # Fan-out of Dead Summaries

  Periodically, the `ZenMonitor.Proxy` (technically the `ZenMonitor.Proxy.Batcher`) on the remote
  node will send a "Dead Summary".  This is a message from the remote that informs the Connector
  of all the processes the Connector has monitored that have gone down since the last summary.

  The Connector uses it's local records to generate a batch of _down dispatches_.  These are
  messages that look identical to the messages provided by `Process.monitor/1` when a process goes
  down.  It is sometimes necessary for the original monitoring process to be able to discern
  whether the `:DOWN` message originated from ERTS or from ZenMonitor, to aid this, ZenMonitor
  will wrap the original reason in a tuple of `{:zen_monitor, original_reason}`.

  The fan-out messages are sent to `ZenMonitor.Local` for eventual delivery via
  `ZenMonitor.Local.Dispatcher`, see those modules for more information.

  # Fan-out of nodedown / ZenMonitor.Proxy down

  The Connector is also responsible for monitoring the remote node and dealing with nodedown (or
  the node becoming incompatible, either due to the `ZenMonitor.Proxy` crashing or a code change).

  If the Connector detects that the remote it is responsible for is down or no longer compatible,
  it will fire every established monitor with `{:zen_monitor, :nodedown}`.  It uses the same
  mechanism as for Dead Summaries, see `ZenMonitor.Local` and `ZenMonitor.Local.Dispatcher` for
  more information.
  """
  use GenServer
  use Instruments.CustomFunctions, prefix: "zen_monitor.local.connector"

  alias ZenMonitor.Local
  alias ZenMonitor.Local.Tables

  @base_penalty 1_000
  @maximum_penalty 60_000
  @max_attempt :math.ceil(:math.log2(@maximum_penalty))
  @chunk_size 5000
  @sweep_interval 100

  @type t :: __MODULE__
  @type compatibility :: :compatible | :incompatible
  @type cached_compatibility :: compatibility | :miss | {:expired, integer} | :unavailable
  @type death_certificate :: {pid, reason :: any}
  @type down_dispatch :: {pid, {:DOWN, reference, :process, pid, {:zen_monitor, any}}}

  defmodule State do
    @moduledoc """
    Maintains the internal state for the Connector

      - `monitors` is an ETS table for keeping track of monitors for the purpose of fan-out.
      - `remote_node_monitored` is a flag used to track whether or not the remote node has been
        monitored
      - `remote_proxy_ref` is the monitoring reference of the remote node's ZenMonitor.Proxy
      - `remote` is the remote node for which the Connector is responsible.
      - `batch` is the queue of instructions pending until the next sweep.
      - `length` is the current length of the batch queue (calculating queue length is an O(n)
        operation, it is simple to track it as elements are added / removed)
    """
    @type t :: %__MODULE__{
            monitors: :ets.tid(),
            remote_node_monitored: boolean(),
            remote_proxy_ref: reference(),
            remote: node(),
            length: integer(),
            batch: :queue.queue()
          }

    defstruct [
      :monitors,
      :remote,
      :remote_proxy_ref,
      remote_node_monitored: false,
      length: 0,
      batch: :queue.new()
    ]
  end

  ## Client

  def start_link(remote) do
    GenServer.start_link(__MODULE__, remote)
  end

  @doc """
  Get a connector from the registry by destination
  """
  @spec get(target :: ZenMonitor.destination()) :: pid()
  def get(target) do
    target
    |> ZenMonitor.find_node()
    |> get_for_node()
  end

  @doc """
  Get a connector from the registry by remote node
  """
  @spec get_for_node(remote :: node()) :: pid()
  def get_for_node(remote) when is_atom(remote) do
    case GenRegistry.lookup(__MODULE__, remote) do
      {:ok, connector} ->
        connector

      {:error, :not_found} ->
        {:ok, connector} = GenRegistry.lookup_or_start(__MODULE__, remote, [remote])
        connector
    end
  end

  @doc """
  Asynchronously monitors a pid.
  """
  @spec monitor(target :: ZenMonitor.destination(), ref :: reference(), subscriber :: pid()) ::
          :ok
  def monitor(target, ref, subscriber) do
    target
    |> get()
    |> GenServer.cast({:monitor, target, ref, subscriber})
  end

  @doc """
  Asynchronously demonitors a pid.
  """
  @spec demonitor(target :: ZenMonitor.destination(), ref :: reference()) :: :ok
  def demonitor(target, ref) do
    target
    |> get()
    |> GenServer.cast({:demonitor, target, ref})
  end

  @doc """
  Determine the effective compatibility of a remote node

  This will attempt a fast client-side lookup in the ETS table.  Only a positive `:compatible`
  record will result in `:compatible`, otherwise the effective compatibility is `:incompatible`
  """
  @spec compatibility(remote :: node()) :: compatibility
  def compatibility(remote) do
    case cached_compatibility(remote) do
      :compatible ->
        :compatible

      _ ->
        :incompatible
    end
  end

  @doc """
  Check the cached compatibility status for a remote node

  This will only perform a fast client-side lookup in the ETS table.  If an authoritative entry is
  found it will be returned (either `:compatible`, `:incompatible`, or `:unavailable`).  If no
  entry is found then `:miss` is returned.  If an expired entry is found then
  `{:expired, attempts}` is returned.
  """
  @spec cached_compatibility(remote :: node()) :: cached_compatibility
  def cached_compatibility(remote) do
    case :ets.lookup(Tables.nodes(), remote) do
      [] ->
        :miss

      [{^remote, :compatible}] ->
        :compatible

      [{^remote, {:incompatible, enforce_until, attempt}}] ->
        if enforce_until < ZenMonitor.now() do
          {:expired, attempt}
        else
          :incompatible
        end

      [{^remote, :unavailable}] ->
        :unavailable
    end
  end

  @doc """
  Connect to the provided remote

  This function will not consult the cache before calling into the GenServer, the GenServer will
  consult with the cache before attempting to connect, this allows for many callers to connect
  with the server guaranteeing that only one attempt will actually perform network work.

  If the compatibility of a remote host is needed instead, callers should use the
  `compatibility/1` or `cached_compatibility/1` functions.  `compatibility/1` will provide the
  effective compatibility, `cached_compatibility/1` is mainly used internally but can provide more
  detailed information about the cache status of the remote.  Neither of these methods,
  `compatibility/1` nor `cached_compatibility/1`, will perform network work or call into the
  GenServer.
  """
  @spec connect(remote :: node()) :: compatibility
  def connect(remote) do
    remote
    |> get_for_node()
    |> GenServer.call(:connect)
  end

  @doc """
  Gets the sweep interval from the Application Environment

  The sweep interval is the number of milliseconds to wait between sweeps, see
  ZenMonitor.Local.Connector's @sweep_interval for the default value

  This can be controlled at boot and runtime with the {:zen_monitor, :connector_sweep_interval}
  setting, see `ZenMonitor.Local.Connector.sweep_interval/1` for runtime convenience
  functionality.
  """
  @spec sweep_interval() :: integer
  def sweep_interval do
    Application.get_env(:zen_monitor, :connector_sweep_interval, @sweep_interval)
  end

  @doc """
  Puts the sweep interval into the Application Environment

  This is a simple convenience function for overwriting the
  {:zen_monitor, :connector_sweep_interval} setting at runtime.
  """
  @spec sweep_interval(value :: integer) :: :ok
  def sweep_interval(value) do
    Application.put_env(:zen_monitor, :connector_sweep_interval, value)
  end

  @doc """
  Gets the chunk size from the Application Environment

  The chunk size is the maximum number of subscriptions that will be sent during each sweep, see
  ZenMonitor.Local.Connector's @chunk_size for the default value

  This can be controlled at boot and runtime with the {:zen_monitor, :connector_chunk_size}
  setting, see `ZenMonitor.Local.Connector.chunk_size/1` for runtime convenience functionality.
  """
  @spec chunk_size() :: integer
  def chunk_size do
    Application.get_env(:zen_monitor, :connector_chunk_size, @chunk_size)
  end

  @doc """
  Puts the chunk size into the Application Environment

  This is a simple convenience function for overwriting the {:zen_monitor, :connector_chunk_size}
  setting at runtime.
  """
  @spec chunk_size(value :: integer) :: :ok
  def chunk_size(value) do
    Application.put_env(:zen_monitor, :connector_chunk_size, value)
  end

  ## Server

  def init(remote) do
    schedule_sweep()
    monitors = :ets.new(:monitors, [:private, :ordered_set])
    {:ok, %State{remote: remote, monitors: monitors}}
  end

  @doc """
  Synchronous connect handler

  Attempts to connect to the remote, this handler does check the cache before connecting to avoid
  a thundering herd.
  """
  def handle_call(:connect, _from, %State{} = state) do
    {result, state} = do_compatibility(state)
    {:reply, result, state}
  end

  @doc """
  Handles establishing a new monitor

  1.  Records the monitor into the internal ETS table
  2.  If this is the first monitor for the pid, adds it to the queue for subsequent dispatch to
      the ZenMonitor.Proxy during the next sweep.
  """
  def handle_cast(
        {:monitor, target, ref, subscriber},
        %State{batch: batch, length: length, monitors: monitors} = state
      ) do
    # Check if we should subscribe to this target (this check has to happen before we insert the
    # new monitor otherwise the new monitor will always be found and we will never enqueue
    # anything)
    should_subscribe? = unknown_target?(monitors, target)

    # Always add it to the monitor table
    :ets.insert(monitors, {{target, ref}, subscriber})

    # Enqueue the subscribe instruction if it isn't already monitored
    new_state =
      if should_subscribe? do
        increment("enqueue", 1, tags: ["op:subscribe"])
        %State{state | batch: :queue.in({:subscribe, target}, batch), length: length + 1}
      else
        state
      end

    {:noreply, new_state}
  end

  @doc """
  Handles demonitoring a reference for a given pid

  Cleans up the internal ETS record if it exists
  """
  def handle_cast(
        {:demonitor, target, ref},
        %State{batch: batch, length: length, monitors: monitors} = state
      ) do
    # Remove it from the monitors table
    :ets.delete(monitors, {target, ref})

    # If that was the last monitor for the target, we should unsubscribe.  Unlike monitor we have
    # to perform this check after the delete or else the row we are deleting will always make the
    # target known.
    should_unsubscribe? = unknown_target?(monitors, target)

    # Enqueue the unsubscribe instruction if the target no longer exists
    state =
      if should_unsubscribe? do
        increment("enqueue", 1, tags: ["op:unsubscribe"])
        %State{state | batch: :queue.in({:unsubscribe, target}, batch), length: length + 1}
      else
        state
      end

    {:noreply, state}
  end

  @doc """
  Handles nodedown for the Connector's remote

  When the remote node goes down, every monitor maintained by the Connector should fire
  """
  def handle_info({:nodedown, remote}, %State{remote: remote} = state) do
    # Mark this node as unavailable
    {:incompatible, state} = do_mark_unavailable(state)

    # Mark the remote node as unmonitored (any monitors that existed were just consumed)
    state = %State{state | remote_node_monitored: false}

    # Dispatch down to everyone
    {:noreply, do_down(state)}
  end

  @doc """
  Handles when the proxy crashes because of noconnection

  This reason indicates that we have lost connection with the remote node, mark it as unavailable.
  """
  def handle_info({:DOWN, ref, :process, _, :noconnection}, %State{remote_proxy_ref: ref} = state) do
    # Mark this node as unavailable
    {:incompatible, state} = do_mark_unavailable(state)

    # Clear the remote_proxy_ref
    state = %State{state | remote_proxy_ref: nil}

    # Dispatch down to everyone
    {:noreply, do_down(state)}
  end

  @doc """
  Handles when the proxy crashes for any other reason

  Penalize the remote as incompatible and let the normal remote recovery take care of it.
  """
  def handle_info({:DOWN, ref, :process, _, _}, %State{remote_proxy_ref: ref} = state) do
    # Mark this node as incompatible
    {:incompatible, state} = do_mark_incompatible(state, 1)

    # Clear the remote_proxy_ref
    state = %State{state | remote_proxy_ref: nil}

    # Dispatch down to everyone
    {:noreply, do_down(state)}
  end

  @doc """
  Handle the dead summary from the remote

  Periodically the remote node will send us a summary of everything that has died that we have
  monitored.

  Connector will find and consume all the matching monitors and enqueue the appropriate messages
  for each monitor with ZenMonitor.Local
  """
  def handle_info(
        {:dead, remote, death_certificates},
        %State{remote: remote, monitors: monitors} = state
      ) do
    death_certificates
    |> messages_for_death_certificates(monitors)
    |> Local.enqueue()

    {:noreply, state}
  end

  @doc """
  Handle the periodic sweep

  If the remote is compatible this will create a subscription summary up to chunk_size of all the
  pids that need monitoring since the last sweep.  This will be sent to the remote for monitoring.

  If the remote is incompatible, all pids since the last sweep will have their monitors fire with
  `{:zen_monitor, :nodedown}`
  """
  def handle_info(:sweep, %State{} = state) do
    new_state =
      case do_compatibility(state) do
        {:compatible, state} ->
          do_sweep(state)

        {:incompatible, state} ->
          do_down(state)
      end

    schedule_sweep()
    {:noreply, new_state}
  end

  @doc """
  Handle other info

  If a call times out, the remote end might still reply and that would result in a handle_info
  """
  def handle_info(_, %State{} = state) do
    increment("unhandled_info")
    {:noreply, state}
  end

  ## Private

  @spec do_compatibility(state :: State.t()) :: {compatibility, State.t()}
  defp do_compatibility(%State{remote: remote} = state) do
    case cached_compatibility(remote) do
      :miss ->
        do_connect(state, 1)

      {:expired, attempt} ->
        do_connect(state, attempt + 1)

      :unavailable ->
        do_connect(state, 1)

      hit ->
        {hit, state}
    end
  end

  @spec do_connect(State.t(), attempt :: integer) :: {compatibility, State.t()}
  defp do_connect(%State{remote: remote} = state, attempt) do
    try do
      with {:known_node, true} <- {:known_node, known_node?(remote)},
           {:ping, :pong} <-
             {:ping, ZenMonitor.gen_module().call({ZenMonitor.Proxy, remote}, :ping)} do
        do_mark_compatible(state)
      else
        {:known_node, false} ->
          do_mark_unavailable(state)

        {:ping, _} ->
          do_mark_incompatible(state, attempt)
      end
    catch
      :exit, {{:nodedown, _node}, _} ->
        do_mark_unavailable(state)

      :exit, _ ->
        do_mark_incompatible(state, attempt)
    end
  end

  @spec do_sweep(state :: State.t()) :: State.t()
  defp do_sweep(%State{batch: batch, length: length} = state) do
    {summary, overflow, new_length} = chunk(batch, length)
    increment("sweep", length - new_length)
    do_subscribe(state, summary)
    %State{state | batch: overflow, length: new_length}
  end

  @spec chunk(batch :: :queue.queue(), length :: integer) :: {[pid], :queue.queue(), integer}
  defp chunk(batch, length) do
    size = chunk_size()

    if length <= size do
      {:queue.to_list(batch), :queue.new(), 0}
    else
      {summary, overflow} = :queue.split(size, batch)
      {:queue.to_list(summary), overflow, length - size}
    end
  end

  @spec do_subscribe(state :: State.t(), summary :: []) :: :ok
  defp do_subscribe(%State{}, []), do: :ok

  defp do_subscribe(%State{remote: remote}, summary) do
    ZenMonitor.gen_module().cast({ZenMonitor.Proxy, remote}, {:process, self(), summary})
  end

  @spec do_down(state :: State.t()) :: State.t()
  defp do_down(%State{monitors: monitors} = state) do
    # Generate messages for every monitor
    messages =
      for [{{pid, ref}, subscriber}] <- :ets.match(monitors, :"$1") do
        {subscriber, {:DOWN, ref, :process, pid, {:zen_monitor, :nodedown}}}
      end

    # Clear the monitors table
    :ets.delete_all_objects(monitors)

    # Enqueue the messages with ZenMonitor.Local
    Local.enqueue(messages)

    # Return a new empty state
    %State{state | batch: :queue.new(), length: 0}
  end

  @spec do_mark_compatible(State.t()) :: {:compatible, State.t()}
  defp do_mark_compatible(%State{remote: remote} = state) do
    state =
      state
      |> monitor_remote_node()
      |> monitor_remote_proxy()

    :ets.insert(Tables.nodes(), {remote, :compatible})
    {:compatible, state}
  end

  @spec do_mark_incompatible(State.t(), attempt :: integer) :: {:incompatible, State.t()}
  defp do_mark_incompatible(%State{remote: remote} = state, attempt) do
    state = monitor_remote_node(state)

    :ets.insert(
      Tables.nodes(),
      {remote, {:incompatible, ZenMonitor.now() + penalty(attempt), attempt}}
    )

    {:incompatible, state}
  end

  @spec do_mark_unavailable(State.t()) :: {:incompatible, State.t()}
  defp do_mark_unavailable(%State{remote: remote} = state) do
    :ets.insert(Tables.nodes(), {remote, :unavailable})
    {:incompatible, state}
  end

  @spec monitor_remote_node(State.t()) :: State.t()
  defp monitor_remote_node(%State{remote_node_monitored: true} = state), do: state

  defp monitor_remote_node(%State{remote_node_monitored: false, remote: remote} = state) do
    Node.monitor(remote, true)
    %State{state | remote_node_monitored: true}
  end

  @spec monitor_remote_proxy(State.t()) :: State.t()
  defp monitor_remote_proxy(%State{remote_proxy_ref: nil, remote: remote} = state) do
    %State{state | remote_proxy_ref: Process.monitor({ZenMonitor.Proxy, remote})}
  end

  defp monitor_remote_proxy(%State{} = state), do: state

  @spec messages_for_death_certificates(
          death_certificates :: [death_certificate],
          monitors :: :ets.tid()
        ) :: [down_dispatch]
  defp messages_for_death_certificates(death_certificates, monitors) do
    do_messages_for_death_certificates(death_certificates, monitors, [])
  end

  @spec do_messages_for_death_certificates(
          death_certificates :: [death_certificate],
          monitors :: :ets.tid(),
          acc :: [down_dispatch]
        ) :: down_dispatch
  defp do_messages_for_death_certificates([], _monitors, acc), do: Enum.reverse(acc)

  defp do_messages_for_death_certificates([{pid, reason} | rest], monitors, acc) do
    acc =
      monitors
      |> :ets.match({{pid, :"$1"}, :"$2"})
      |> Enum.reduce(acc, fn [ref, subscriber], acc ->
        # Consume the monitor
        :ets.delete(monitors, {pid, ref})

        # Add the new message into the accumulator
        [{subscriber, {:DOWN, ref, :process, pid, {:zen_monitor, reason}}} | acc]
      end)

    do_messages_for_death_certificates(rest, monitors, acc)
  end

  @spec known_node?(remote :: node()) :: boolean()
  defp known_node?(remote) do
    remote == Node.self() or remote in Node.list()
  end

  @spec penalty(attempt :: integer) :: integer
  defp penalty(attempt) do
    min(@maximum_penalty, @base_penalty * round(:math.pow(2, min(attempt, @max_attempt))))
  end

  @spec unknown_target?(monitors :: :ets.tid(), target :: pid) :: boolean
  defp unknown_target?(monitors, target) do
    # ETS does not make for the most readable code, here's what the following line does.
    # Perform a match on the internal monitors table looking for keys that start with
    # {target, ...}
    # Since we are just interested to see if there are any, but don't care about the content, we
    # set the other fields to :_ to ignore them.
    # The target is known if there are _any_ results, so we apply a limit to the match of just 1
    # result.
    # This means that we either get back a tuple of {[[]]], continuation} or :"$end_of_table"
    # :"$end_of_table" implies that the match for a single item found nothing, therefore the
    # target does not exist and is unknown
    :ets.match(monitors, {{target, :_}, :_}, 1) == :"$end_of_table"
  end

  @spec schedule_sweep() :: reference
  defp schedule_sweep do
    Process.send_after(self(), :sweep, sweep_interval())
  end
end
