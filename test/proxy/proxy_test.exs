defmodule ZenMonitor.Proxy.Test do
  @moduledoc """
  Tests for the ZenMonitor.Proxy module
  """
  use ExUnit.Case

  alias ZenMonitor.Proxy
  alias ZenMonitor.Proxy.{Batcher, Tables}
  alias ZenMonitor.Test.Support.Subscriber

  # Batchers stop when their subscriber goes DOWN, this tag tells ExUnit to suppress stops reports
  @moduletag :capture_log

  setup do
    # Speed up the Batcher so its interval is much faster than the default timeout for
    # assert_receive / refute_receive
    Application.ensure_all_started(:instruments)
    original_sweep_interval = Batcher.sweep_interval()
    Batcher.sweep_interval(10)
    start_supervised(ZenMonitor.Supervisor)

    on_exit(fn ->
      # Restore original setting
      Batcher.sweep_interval(original_sweep_interval)
    end)

    {:ok, proxy: Process.whereis(ZenMonitor.Proxy)}
  end

  def pids(count) do
    Enum.map(1..count, fn _ -> spawn(fn -> Process.sleep(:infinity) end) end)
  end

  def row_count(table) do
    :ets.tab2list(table) |> length()
  end

  def monitor_count(pid) do
    Process.info(pid, :monitors) |> elem(1) |> length
  end

  describe "Ping" do
    test "returns :pong" do
      assert :pong = Proxy.ping()
    end
  end

  describe "Process" do
    test "no monitors before subscription", ctx do
      assert {:monitors, []} = Process.info(ctx.proxy, :monitors)
    end

    test "subscriptions add entries to the subscribers table", ctx do
      subscriber = self()
      targets = pids(3)
      instructions = Enum.map(targets, &{:subscribe, &1})

      # Send the subscribe instructions
      GenServer.cast(ctx.proxy, {:process, subscriber, instructions})

      # Assert that three entries get written
      assert Helper.wait_until(fn ->
               row_count(Tables.subscribers()) == 3
             end)

      # Assert each entry individually
      [t1, t2, t3] = targets
      assert :ets.member(Tables.subscribers(), {t1, subscriber})
      assert :ets.member(Tables.subscribers(), {t2, subscriber})
      assert :ets.member(Tables.subscribers(), {t3, subscriber})
    end

    test "multiple subscriptions to the same pid do not get additional subscriber rows", ctx do
      subscriber = self()
      [target] = pids(1)
      instructions = [{:subscribe, target}]

      # Create the initial subscription
      GenServer.cast(ctx.proxy, {:process, subscriber, instructions})

      # Assert that the entry gets written to the subscriber table
      assert Helper.wait_until(fn ->
               row_count(Tables.subscribers()) == 1
             end)

      # Assert that it's the row we expect
      assert :ets.member(Tables.subscribers(), {target, subscriber})

      # Perform a duplicate subscription
      GenServer.cast(ctx.proxy, {:process, subscriber, instructions})

      # Assert that no new entry gets written
      assert Helper.wait_until(fn ->
               row_count(Tables.subscribers()) != 2
             end)
    end

    test "subscriptions result in processes being monitored", ctx do
      subscriber = self()
      targets = pids(3)
      instructions = Enum.map(targets, &{:subscribe, &1})

      # Create the Subscriptions
      GenServer.cast(ctx.proxy, {:process, subscriber, instructions})

      # Wait for three monitors to show up
      assert Helper.wait_until(fn ->
               monitor_count(ctx.proxy) == 3
             end)

      {:monitors, monitors} = Process.info(ctx.proxy, :monitors)
      pids = Keyword.get_values(monitors, :process) |> Enum.sort()
      targets = Enum.sort(targets)

      assert pids == targets
    end

    test "duplicate subscriptions do not result in multiple monitors", ctx do
      subscriber = self()
      [target] = pids(1)
      instructions = [{:subscribe, target}]

      # Create an initial subscription
      GenServer.cast(ctx.proxy, {:process, subscriber, instructions})

      # Wait for the monitor to be established
      assert Helper.wait_until(fn ->
               monitor_count(ctx.proxy) == 1
             end)

      # Create a duplicate subscription
      GenServer.cast(ctx.proxy, {:process, subscriber, instructions})

      # Assert that no new monitors are created
      assert Helper.wait_until(fn ->
               monitor_count(ctx.proxy) != 2
             end)
    end

    test "unsubscribe removes the subscriber", ctx do
      subscriber = self()
      [target] = pids(1)
      subscribe_instructions = [{:subscribe, target}]
      unsubscribe_instructions = [{:unsubscribe, target}]

      # Create an initial subscription
      GenServer.cast(ctx.proxy, {:process, subscriber, subscribe_instructions})

      # Wait for the subscriber row to be written
      assert Helper.wait_until(fn ->
               row_count(Tables.subscribers()) == 1
             end)

      # Unsubscribe
      GenServer.cast(ctx.proxy, {:process, subscriber, unsubscribe_instructions})

      # Make sure the subscriber is removed
      assert Helper.wait_until(fn ->
               row_count(Tables.subscribers()) == 0
             end)
    end

    test "instruction order is respected (terminal subscribed)", ctx do
      subscriber = self()
      [target] = pids(1)
      instructions = [{:unsubscribe, target}, {:subscribe, target}]

      # Process the instructions
      GenServer.cast(ctx.proxy, {:process, subscriber, instructions})

      # Confirm that the subscriber exists
      assert Helper.wait_until(fn ->
               row_count(Tables.subscribers()) == 1
             end)

      assert :ets.member(Tables.subscribers(), {target, subscriber})
    end

    test "instruction order is respected (terminal unsubscribed)", ctx do
      subscriber = self()
      [target] = pids(1)
      instructions = [{:subscribe, target}, {:unsubscribe, target}]

      # Process the instructions
      GenServer.cast(ctx.proxy, {:process, subscriber, instructions})

      # Confirm that no subscription exists
      assert Helper.wait_until(fn ->
               row_count(Tables.subscribers()) == 0
             end)
    end

    test "unsubscribe is isolated to the unsubscriber", ctx do
      subscriber = Subscriber.start(self())
      [target] = pids(1)
      subscribe_instructions = [{:subscribe, target}]
      unsubscribe_instructions = [{:unsubscribe, target}]

      # Subscribe both parties to the target
      GenServer.cast(ctx.proxy, {:process, self(), subscribe_instructions})
      GenServer.cast(ctx.proxy, {:process, subscriber, subscribe_instructions})

      # Assert that the subscribers get written to the table
      assert Helper.wait_until(fn ->
               row_count(Tables.subscribers()) == 2
             end)

      assert :ets.member(Tables.subscribers(), {target, subscriber})
      assert :ets.member(Tables.subscribers(), {target, self()})

      # Unsubscribe on of the parties
      GenServer.cast(ctx.proxy, {:process, self(), unsubscribe_instructions})

      # Assert that the correct row was removed
      assert Helper.wait_until(fn ->
               row_count(Tables.subscribers()) == 1
             end)

      assert :ets.member(Tables.subscribers(), {target, subscriber})
      refute :ets.member(Tables.subscribers(), {target, self()})
    end

    test "unsubscribe is isolated to the target", ctx do
      subscriber = self()
      [target, other] = pids(2)

      instructions = [
        {:subscribe, target},
        {:unsubscribe, target},
        {:subscribe, other}
      ]

      # Process the instructions
      GenServer.cast(ctx.proxy, {:process, subscriber, instructions})

      # Assert that only the other target exists in the table
      assert Helper.wait_until(fn ->
               row_count(Tables.subscribers()) == 1
             end)

      assert :ets.member(Tables.subscribers(), {other, subscriber})
      refute :ets.member(Tables.subscribers(), {target, subscriber})
    end

    test "ERTS monitors persist after unsubscribe", ctx do
      subscriber = self()
      [target] = pids(1)
      subscribe_instructions = [{:subscribe, target}]
      unsubscribe_instructions = [{:unsubscribe, target}]

      # Create the initial subscription
      GenServer.cast(ctx.proxy, {:process, subscriber, subscribe_instructions})

      # Assert that the subscriber row is written
      assert Helper.wait_until(fn ->
               row_count(Tables.subscribers()) == 1
             end)

      # Assert that the monitor is established
      assert Helper.wait_until(fn ->
               monitor_count(ctx.proxy) == 1
             end)

      # Unsubscribe
      GenServer.cast(ctx.proxy, {:process, subscriber, unsubscribe_instructions})

      # Assert that the subscriber row was cleaned up
      assert Helper.wait_until(fn ->
               row_count(Tables.subscribers()) == 0
             end)

      # Assert that the monitor persists
      assert Helper.wait_until(fn ->
               monitor_count(ctx.proxy) == 1
             end)
    end
  end

  describe "DOWN handling" do
    test "removes subscribers for the down pid", ctx do
      subscriber = Subscriber.start(self())
      [target, other] = pids(2)
      instructions = [{:subscribe, target}, {:subscribe, other}]

      # Subscribe both parties to the same target and another process that will be kept alive
      GenServer.cast(ctx.proxy, {:process, self(), instructions})
      GenServer.cast(ctx.proxy, {:process, subscriber, instructions})

      # Assert that the subscribers get written to the table
      assert Helper.wait_until(fn ->
               row_count(Tables.subscribers()) == 4
             end)

      # Kill the target
      Process.exit(target, :kill)

      # Assert delivery of messages
      assert_receive {:dead, _, [{^target, _}]}
      assert_receive {:forward, {:dead, _, [{^target, _}]}}

      # Make sure the subscriber rows were cleared out
      assert row_count(Tables.subscribers()) == 2
      subscribers = :ets.match(Tables.subscribers(), {{other, :"$1"}})
      assert [self()] in subscribers
      assert [subscriber] in subscribers
    end

    test "truncates reasons", ctx do
      subscriber = Subscriber.start(self())
      [target, other] = pids(2)
      instructions = [{:subscribe, target}, {:subscribe, other}]

      # Subscribe both parties to the same target and another process that will be kept alive
      GenServer.cast(ctx.proxy, {:process, self(), instructions})
      GenServer.cast(ctx.proxy, {:process, subscriber, instructions})

      # Assert that the subscribers get written to the table
      assert Helper.wait_until(fn ->
               row_count(Tables.subscribers()) == 4
             end)

      reason = {:this, :is, :an, {:especially, {:deeply, {:nested, {:tuple}}}}}
      # Kill the target
      Process.exit(target, reason)

      # Assert delivery of messages
      assert_receive {:dead, _, [{^target, reason}]}
      assert_receive {:forward, {:dead, _, [{^target, _}]}}

      assert {:this, :is, :an, {:especially, {:truncated, :truncated}}} == reason
    end

    test "truncates state", ctx do
      defmodule Crasher do
        use GenServer

        def start do
          state = for i <- 1..10000, into: %{}, do: {i, i * 2}
          GenServer.start(__MODULE__, state)
        end

        def init(args) do
          {:ok, args}
        end

        def crash(pid), do: GenServer.call(pid, :crash)

        def handle_call(nil, _from, state), do: {:reply, :ok, state}
      end

      {:ok, crasher} = Crasher.start()
      instructions = [{:subscribe, crasher}]

      GenServer.cast(ctx.proxy, {:process, self(), instructions})
      # Assert that the subscribers get written to the table
      assert Helper.wait_until(fn ->
               row_count(Tables.subscribers()) == 1
             end)

      spawn(Crasher, :crash, [crasher])

      assert_receive {:dead, _, [{^crasher, reason}]}, 500
      assert {:function_clause, frames} = reason

      for frame <- frames do
        # this generates a big stack, everything should be truncated.
        assert [:truncated] = frame |> Tuple.to_list() |> Enum.uniq()
      end
    end
  end
end
