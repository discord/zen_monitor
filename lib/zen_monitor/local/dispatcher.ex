defmodule ZenMonitor.Local.Dispatcher do
  @moduledoc """
  `ZenMonitor.Local.Dispatcher` is a GenStage Consumer responsible for throttled delivery of down
  messages.

  `ZenMonitor.Local` acts as a GenStage Producer, it stores all of the down messages that need to
  be dispatched based off of what has been enqueued by the `ZenMonitor.Local.Connector`.

  The Dispatcher will deliver these messages throttled by a maximum rate which is controlled by
  the {:zen_monitor, :demand_interval} and {:zen_monitor, :demand_amount} settings.

  To calculate the maximum number of messages processed per second you can use the following
  formula:

  maximum_mps = (demand_amount) * (1000 / demand_interval)

  For example, if the demand_amount is 1000, and demand_interval is 100 (milliseconds) the maximum
  messages per second are:

  maximum_mps = (1000) * (1000 / 100)
             -> (1000) * 10
             -> 10_000

  For convenience a `ZenMonitor.Local.Dispatcher.maximum_mps/0` is provided that will perform this
  calculation.
  """
  use GenStage
  use Instruments.CustomFunctions, prefix: "zen_monitor.local.dispatcher"

  alias ZenMonitor.Local.Tables

  @demand_interval 100
  @demand_amount 1000

  ## Client

  def start_link(_opts \\ []) do
    GenStage.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Gets the demand interval from the Application Environment

  The demand interval is the number of milliseconds to wait between demanding more events from the
  GenStage Producer (`ZenMonitor.Local`)

  This can be controlled at boot and runtime with the {:zen_monitor, :demand_interval} setting,
  see `ZenMonitor.Local.Dispatcher.demand_interval/1` for runtime convenience functionality.
  """
  @spec demand_interval() :: integer
  def demand_interval do
    Application.get_env(:zen_monitor, :demand_interval, @demand_interval)
  end

  @doc """
  Puts the demand interval into the Application Environment

  This is a simple convenience function for overwrite the {:zen_monitor, :demand_interval} setting
  at runtime
  """
  @spec demand_interval(value :: integer) :: :ok
  def demand_interval(value) do
    Application.put_env(:zen_monitor, :demand_interval, value)
  end

  @doc """
  Gets the demand amount from the Application Environment

  The demand amount is the number of events tor request from the GenStage Producer
  (`ZenMonitor.Local`) every demand interval

  This can be controlled at boot and runtime with the {:zen_monitor, :demand_amount} setting, see
  `ZenMonitor.Local.Dispatcher.demand_amount/1` for runtime convenience functionality.
  """
  @spec demand_amount() :: integer
  def demand_amount do
    Application.get_env(:zen_monitor, :demand_amount, @demand_amount)
  end

  @doc """
  Puts the demand amount into the Application Environment

  This is a simple convenience function for overwriting the {:zen_monitor, :demand_amount} setting
  at runtime.
  """
  @spec demand_amount(value :: integer) :: :ok
  def demand_amount(value) do
    Application.put_env(:zen_monitor, :demand_amount, value)
  end

  @doc """
  Calculate the current maximum messages per second

  This is a convenience function to help operators understand the current throughput of the
  Dispatcher.
  """
  @spec maximum_mps() :: float
  def maximum_mps do
    demand_amount() * (1000 / demand_interval())
  end

  ## Server

  def init(_opts) do
    {:consumer, nil, subscribe_to: [{ZenMonitor.Local, min_demand: 1}]}
  end

  @doc """
  Handles the events for dispatch

  Dispatch is a simple two step procedure followed for each message to be dispatched.

  1.  Check if the message is still valid.  Messages can become invalid if the monitor was
      demonitored after the message was enqueued.

  2a.  If valid:  forward the message to the subscriber
  2b.  If invalid: skip message

  Event dispatch will calculate an "unfulfilled" demand based off the number of messages skipped
  and demand that the producer provide additional events so that MPS is maintained and prevent the
  Dispatcher from being starved because of invalid messages.
  """
  def handle_events(events, _from, producer) do
    delivered = length(events)
    increment("events.delivered", delivered)

    messages =
      for {subscriber, {:DOWN, ref, :process, _, _} = message} <- events,
          still_monitored?(subscriber, ref) do
        send(subscriber, message)
      end

    # Ensure that filtering does not starve out the Dispatcher

    # Calculate the effective demand by taking the smaller of the current demand_amount and the
    # length of events delivered.
    effective_demand = min(delivered, demand_amount())
    processed = length(messages)
    increment("events.processed", processed)

    # The unfulfilled demand is the difference between the effective demand and the actual events
    unfulfilled = effective_demand - processed

    # Ask the producer to fulfill the unfulfilled demand (if this number is 0 or negative, the
    # ask helper will handle that for us and not ask for anything)
    ask(producer, unfulfilled)

    {:noreply, [], producer}
  end

  @doc """
  Handles the callback for the subscription being established with the producer.

  This is the start of the demand loop, once the producer confirms subscription, the initial call
  to schedule_demand/0 happens.
  """
  def handle_subscribe(:producer, _, from, _state) do
    schedule_demand()
    {:manual, from}
  end

  @doc """
  Handles the periodic generate_demand message

  Asks the producer for demand_amount of events then schedules the next demand generation.
  """
  def handle_info(:generate_demand, producer) do
    ask(producer, demand_amount())
    schedule_demand()

    {:noreply, [], producer}
  end

  ## Private

  @spec ask(producer :: pid, amount :: integer) :: :ok
  defp ask(_producer, amount) when amount <= 0, do: :ok

  defp ask(producer, amount) do
    GenStage.ask(producer, amount)
  end

  @spec still_monitored?(subscriber :: pid, ref :: reference) :: boolean
  defp still_monitored?(subscriber, ref) do
    :ets.take(Tables.references(), {subscriber, ref}) != []
  end

  @spec schedule_demand() :: reference
  defp schedule_demand do
    Process.send_after(self(), :generate_demand, demand_interval())
  end
end
