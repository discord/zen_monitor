defmodule ZenMonitor.Local.Connector.Test do
  use ExUnit.Case

  alias ZenMonitor.Local.{Connector, Dispatcher}
  alias ZenMonitor.Proxy.Batcher
  alias ZenMonitor.Test.Support.ObservableGen

  setup do
    {:ok, compatible, nil} = ChildNode.start_link(:zen_monitor, :Compatible)
    {:ok, incompatible, nil} = ChildNode.start_link(:elixir, :Incompatible)

    start_supervised(ZenMonitor.Supervisor)

    on_exit(fn ->
      Node.monitor(compatible, true)
      Node.monitor(incompatible, true)

      receive do
        {:nodedown, ^compatible} -> :ok
      end

      receive do
        {:nodedown, ^incompatible} -> :ok
      end
    end)

    {:ok, compatible: compatible, incompatible: incompatible, down: :down@down}
  end

  def disable_sweep(_) do
    # Set sweep interval to 1 minute (effectively disable for this describe block)
    original_sweep_interval = Connector.sweep_interval()
    Connector.sweep_interval(60_000)

    on_exit(fn ->
      Connector.sweep_interval(original_sweep_interval)
    end)

    :ok
  end

  def reduce_chunk_size(_) do
    # Set chunk size to 2 for testing convenience
    original_chunk_size = Connector.chunk_size()
    Connector.chunk_size(2)

    on_exit(fn ->
      Connector.chunk_size(original_chunk_size)
    end)

    :ok
  end

  def start_remote_process(ctx) do
    compatible_pid = Node.spawn(ctx.compatible, Process, :sleep, [:infinity])
    compatible_pid_b = Node.spawn(ctx.compatible, Process, :sleep, [:infinity])
    compatible_pid_c = Node.spawn(ctx.compatible, Process, :sleep, [:infinity])

    incompatible_pid = Node.spawn(ctx.incompatible, Process, :sleep, [:infinity])
    incompatible_pid_b = Node.spawn(ctx.incompatible, Process, :sleep, [:infinity])
    incompatible_pid_c = Node.spawn(ctx.incompatible, Process, :sleep, [:infinity])

    {
      :ok,
      compatible_pid: compatible_pid,
      compatible_pid_b: compatible_pid_b,
      compatible_pid_c: compatible_pid_c,
      incompatible_pid: incompatible_pid,
      incompatible_pid_b: incompatible_pid_b,
      incompatible_pid_c: incompatible_pid_c
    }
  end

  def observe_gen(_) do
    # Start up an observer
    {:ok, observer} = ObservableGen.start_link(self())

    # Replace the original rpc_module with the ObservableRPC
    original_gen_module = ZenMonitor.gen_module()
    ZenMonitor.gen_module(ObservableGen)

    on_exit(fn ->
      ZenMonitor.gen_module(original_gen_module)
    end)

    {:ok, observer: observer}
  end

  def observe_zen_monitor(_) do
    Process.unregister(ZenMonitor.Local)
    Process.register(self(), ZenMonitor.Local)
    :ok
  end

  @doc """
  Reduces the intervals for all the batching parts of ZenMonitor so that the default
  assert_receive / refute_receive timeouts are an order of magnitude larger.
  """
  def fast_zen_monitor(ctx) do
    # Tune the local dispatcher
    original_demand_interval = Dispatcher.demand_interval()
    Dispatcher.demand_interval(10)

    # Tune the local connector
    original_connector_interval = Connector.sweep_interval()
    Connector.sweep_interval(10)

    # Tune the remote batchers
    original_batch_intervals =
      Enum.map([node(), ctx.compatible], fn remote ->
        original = :rpc.call(remote, Batcher, :sweep_interval, [])
        :rpc.call(remote, Batcher, :sweep_interval, [10])
        {remote, original}
      end)

    on_exit(fn ->
      # Restore the local settings
      Dispatcher.demand_interval(original_demand_interval)
      Connector.sweep_interval(original_connector_interval)

      # Restore the remote settings
      Enum.each(original_batch_intervals, fn {remote, original} ->
        :rpc.call(remote, Batcher, :sweep_interval, [original])
      end)
    end)

    :ok
  end

  describe "Getting a connector" do
    test "get connector for compatible remote node", ctx do
      connector = Connector.get_for_node(ctx.compatible)
      assert Process.alive?(connector)
    end

    test "get connector for incompatible remote node", ctx do
      connector = Connector.get_for_node(ctx.incompatible)
      assert Process.alive?(connector)
    end

    test "multiple gets return the same connector", ctx do
      connector_a = Connector.get_for_node(ctx.compatible)
      connector_b = Connector.get_for_node(ctx.compatible)

      assert connector_a == connector_b
    end

    test "new connector after connector is killed", ctx do
      original = Connector.get_for_node(ctx.compatible)
      assert Process.alive?(original)

      Process.exit(original, :kill)
      refute Process.alive?(original)

      replacement = Connector.get_for_node(ctx.compatible)
      assert Process.alive?(replacement)

      assert original != replacement
    end

    test "each remote has its own connector", ctx do
      connector_a = Connector.get_for_node(ctx.compatible)
      connector_b = Connector.get_for_node(ctx.incompatible)

      assert connector_a != connector_b
    end
  end

  describe "Performing a connect" do
    setup [:observe_gen]

    test "connecting to a compatible remote node", ctx do
      compatible = ctx.compatible()

      assert :compatible = Connector.connect(compatible)
      assert_receive {:observe, :call, {ZenMonitor.Proxy, ^compatible}, :ping, _}
    end

    test "connecting to an incompatible remote node", ctx do
      incompatible = ctx.incompatible

      assert :incompatible = Connector.connect(incompatible)
      assert_receive {:observe, :call, {ZenMonitor.Proxy, ^incompatible}, :ping, _}
    end

    test "connecting to a down remote node", ctx do
      down = ctx.down()

      assert :incompatible = Connector.connect(down)
      refute_receive {:observe, :call, _, _, _}
    end
  end

  describe "Connect status caching" do
    setup [:disable_sweep]

    test "miss when never connected", ctx do
      assert :miss = Connector.cached_compatibility(ctx.compatible)
    end

    test "compatible hit after successful connection", ctx do
      assert :miss = Connector.cached_compatibility(ctx.compatible)
      assert :compatible = Connector.connect(ctx.compatible)
      assert :compatible = Connector.cached_compatibility(ctx.compatible)
    end

    test "incompatible hit after unsuccessful connection", ctx do
      assert :miss = Connector.cached_compatibility(ctx.incompatible)
      assert :incompatible = Connector.connect(ctx.incompatible)
      assert :incompatible = Connector.cached_compatibility(ctx.incompatible)
    end

    test "incompatible cache entries expire", ctx do
      assert :miss = Connector.cached_compatibility(ctx.incompatible)
      assert :incompatible = Connector.connect(ctx.incompatible)
      assert :incompatible = Connector.cached_compatibility(ctx.incompatible)

      assert Helper.wait_until(fn ->
               {:expired, _} = Connector.cached_compatibility(ctx.incompatible)
               true
             end)
    end

    test "remote node crash causes an unavailable cache", ctx do
      assert :miss = Connector.cached_compatibility(ctx.compatible)
      assert :compatible = Connector.connect(ctx.compatible)
      assert :ok = :slave.stop(ctx.compatible)

      assert Helper.wait_until(fn ->
               Connector.cached_compatibility(ctx.compatible) == :unavailable
             end)
    end
  end

  describe "Compatibility checking" do
    test "all nodes start off incompatible", ctx do
      assert :incompatible = Connector.compatibility(ctx.compatible)
      assert :incompatible = Connector.compatibility(ctx.incompatible)
      assert :incompatible = Connector.compatibility(ctx.down)
    end

    test "after connecting to a compatible node it becomes compatible", ctx do
      remote = ctx.compatible()

      assert :incompatible = Connector.compatibility(remote)
      assert :compatible = Connector.connect(remote)
      assert :compatible = Connector.compatibility(remote)
    end

    test "after connecting to an incompatible node it remains incompatible", ctx do
      remote = ctx.incompatible()

      assert :incompatible = Connector.compatibility(remote)
      assert :incompatible = Connector.connect(remote)
      assert :incompatible = Connector.compatibility(remote)
    end

    test "after connecting to a down node it remains incompatible", ctx do
      remote = ctx.down()

      assert :incompatible = Connector.compatibility(remote)
      assert :incompatible = Connector.connect(remote)
      assert :incompatible = Connector.compatibility(remote)
    end
  end

  describe "Monitoring a remote process (local bookkeeping)" do
    setup [:disable_sweep, :start_remote_process]

    test "unmonitored pid is added to queue", ctx do
      ref = make_ref()

      connector = Connector.get_for_node(ctx.compatible)
      initial_state = :sys.get_state(connector)

      assert initial_state.length == 0
      assert :queue.len(initial_state.batch) == 0

      Connector.monitor(ctx.compatible_pid, ref, self())

      # This assertion isn't actually needed, but since monitor is async, this is an easy way to
      # check if the operation has completed
      assert :compatible = Connector.connect(ctx.compatible)

      updated_state = :sys.get_state(connector)

      expected_pid = ctx.compatible_pid
      assert updated_state.length == 1
      assert :queue.len(updated_state.batch) == 1
      assert {:value, {:subscribe, ^expected_pid}} = :queue.peek(updated_state.batch)
    end

    test "already monitored pid is not added to the queue", ctx do
      ref_1 = make_ref()
      ref_2 = make_ref()

      connector = Connector.get_for_node(ctx.compatible)
      initial_state = :sys.get_state(connector)

      assert initial_state.length == 0
      assert :queue.len(initial_state.batch) == 0

      # Monitor the same pid twice
      Connector.monitor(ctx.compatible_pid, ref_1, self())
      Connector.monitor(ctx.compatible_pid, ref_2, self())

      # This assertion isn't actually needed, but since monitor is async, this is an easy way to
      # check if the operation has completed
      assert :compatible = Connector.connect(ctx.compatible)

      updated_state = :sys.get_state(connector)

      expected_pid = ctx.compatible_pid
      assert updated_state.length == 1
      assert :queue.len(updated_state.batch) == 1
      assert {:value, {:subscribe, ^expected_pid}} = :queue.peek(updated_state.batch)
    end
  end

  describe "Demonitoring a process" do
    setup [:observe_zen_monitor, :disable_sweep, :start_remote_process, :fast_zen_monitor]

    test "works on unknown process / ref", ctx do
      assert :ok = Connector.demonitor(ctx.compatible_pid, make_ref())
    end

    test "doesn't send down", ctx do
      reference = make_ref()
      target = ctx.compatible_pid()
      connector = Connector.get_for_node(ctx.compatible)

      # Monitor the target
      Connector.monitor(target, reference, self())

      # Force a sweep
      send(connector, :sweep)

      # Demonitor the target
      Connector.demonitor(target, reference)

      # Kill the target
      Process.exit(target, :kill)

      # Assert that no dispatches are sent for the target
      refute_receive _
    end

    test "is isolated to the demonitored process only", ctx do
      subscriber = self()
      target_reference = make_ref()
      other_reference = make_ref()
      target = ctx.compatible_pid()
      other = ctx.compatible_pid_b()
      connector = Connector.get_for_node(ctx.compatible)

      # Monitor both processes
      Connector.monitor(target, target_reference, subscriber)
      Connector.monitor(other, other_reference, subscriber)

      # Force a sweep
      send(connector, :sweep)

      # Demonitor the target
      Connector.demonitor(target, target_reference)

      # Kill both processes
      Process.exit(target, :kill)
      Process.exit(other, :kill)

      # Assert that a dispatch is enqueued for other only
      assert_receive {:"$gen_cast",
                      {:enqueue,
                       [
                         {^subscriber,
                          {:DOWN, ^other_reference, :process, ^other, {:zen_monitor, _}}}
                       ]}}
    end

    test "incorrect reference does nothing", ctx do
      subscriber = self()
      right_reference = make_ref()
      wrong_reference = make_ref()
      target = ctx.compatible_pid()
      connector = Connector.get_for_node(ctx.compatible)

      # Monitor the target
      Connector.monitor(target, right_reference, subscriber)

      # Force a sweep
      send(connector, :sweep)

      # Demonitor but with the right target / wrong reference
      Connector.demonitor(target, wrong_reference)

      # Kill the target
      Process.exit(target, :kill)

      # Assert that a dispatch is still enqueued
      assert_receive {:"$gen_cast",
                      {:enqueue,
                       [
                         {^subscriber,
                          {:DOWN, ^right_reference, :process, ^target, {:zen_monitor, _}}}
                       ]}}
    end

    test "incorrect pid does nothing", ctx do
      subscriber = self()
      reference = make_ref()
      right_target = ctx.compatible_pid()
      wrong_target = ctx.compatible_pid_b()
      connector = Connector.get_for_node(ctx.compatible)

      # Monitor the target
      Connector.monitor(right_target, reference, subscriber)

      # Force a sweep
      send(connector, :sweep)

      # Demonitor but with the wrong target / right reference
      Connector.demonitor(wrong_target, reference)

      # Kill the target
      Process.exit(right_target, :kill)

      # Assert that a dispatch is still enqueued
      assert_receive {:"$gen_cast",
                      {:enqueue,
                       [
                         {^subscriber,
                          {:DOWN, ^reference, :process, ^right_target, {:zen_monitor, _}}}
                       ]}}
    end

    test "demonitoring the only monitor adds an unsubscribe to the queue", ctx do
      subscriber = self()
      reference = make_ref()
      target = ctx.compatible_pid()
      connector = Connector.get_for_node(ctx.compatible)

      # Monitor the target
      Connector.monitor(target, reference, subscriber)

      # Check the monitor state
      monitor_state = :sys.get_state(connector)
      assert monitor_state.length == 1
      assert :queue.len(monitor_state.batch) == 1
      assert {:value, {:subscribe, ^target}} = :queue.peek(monitor_state.batch)

      # Force a sweep
      send(connector, :sweep)

      # Demonitor the target
      Connector.demonitor(target, reference)

      # Check the demonitor state
      demonitor_state = :sys.get_state(connector)
      assert demonitor_state.length == 1
      assert :queue.len(demonitor_state.batch) == 1
      assert {:value, {:unsubscribe, ^target}} = :queue.peek(demonitor_state.batch)
    end

    test "demonitoring one of many monitors does not add an unsubscribe to the queue", ctx do
      subscriber = self()
      reference = make_ref()
      other_reference = make_ref()
      target = ctx.compatible_pid()
      connector = Connector.get_for_node(ctx.compatible)

      # Monitor the target multiple times
      Connector.monitor(target, reference, subscriber)
      Connector.monitor(target, other_reference, subscriber)

      # Check the monitor state
      monitor_state = :sys.get_state(connector)
      assert monitor_state.length == 1
      assert :queue.len(monitor_state.batch) == 1
      assert {:value, {:subscribe, ^target}} = :queue.peek(monitor_state.batch)

      # Force a sweep
      send(connector, :sweep)

      # Demonitor one of the references
      Connector.demonitor(target, reference)

      # Check the demonitor state
      demonitor_state = :sys.get_state(connector)
      assert demonitor_state.length == 0
      assert :queue.len(demonitor_state.batch) == 0
    end

    test "demonitoring the last of many monitors adds an unsubscribe to the queue", ctx do
      subscriber = self()
      reference = make_ref()
      other_reference = make_ref()
      target = ctx.compatible_pid()
      connector = Connector.get_for_node(ctx.compatible)

      # Monitor the target multiple times
      Connector.monitor(target, reference, subscriber)
      Connector.monitor(target, other_reference, subscriber)

      # Check the monitor state
      monitor_state = :sys.get_state(connector)
      assert monitor_state.length == 1
      assert :queue.len(monitor_state.batch) == 1
      assert {:value, {:subscribe, ^target}} = :queue.peek(monitor_state.batch)

      # Force a sweep
      send(connector, :sweep)

      # Demonitor all of the references
      Connector.demonitor(target, reference)
      Connector.demonitor(target, other_reference)

      # Check the demonitor state
      demonitor_state = :sys.get_state(connector)
      assert demonitor_state.length == 1
      assert :queue.len(demonitor_state.batch) == 1
      assert {:value, {:unsubscribe, ^target}} = :queue.peek(demonitor_state.batch)
    end
  end

  describe "Handles nodedown" do
    setup [:fast_zen_monitor, :observe_zen_monitor, :disable_sweep, :start_remote_process]

    test "marks the node as unavailable", ctx do
      assert :compatible = Connector.connect(ctx.compatible)

      # Stop the node
      :slave.stop(ctx.compatible)

      # Assert that it becomes incompatible
      assert Helper.wait_until(fn ->
               Connector.cached_compatibility(ctx.compatible) == :unavailable
             end)
    end

    test "fires all monitors", ctx do
      subscriber = self()
      target_ref_a_1 = make_ref()
      target_ref_a_2 = make_ref()
      target_ref_b_1 = make_ref()
      target_ref_b_2 = make_ref()
      target_ref_c_1 = make_ref()
      target_ref_c_2 = make_ref()
      target_a = ctx.compatible_pid()
      target_b = ctx.compatible_pid_b()
      target_c = ctx.compatible_pid_c()
      connector = Connector.get_for_node(ctx.compatible)

      # Make some monitors
      Connector.monitor(target_a, target_ref_a_1, subscriber)
      Connector.monitor(target_a, target_ref_a_2, subscriber)
      Connector.monitor(target_b, target_ref_b_1, subscriber)
      Connector.monitor(target_b, target_ref_b_2, subscriber)
      Connector.monitor(target_c, target_ref_c_1, subscriber)
      Connector.monitor(target_c, target_ref_c_2, subscriber)

      # Force a sweep
      send(connector, :sweep)

      # Wait for the monitors to establish
      Process.sleep(50)

      # Stop the node
      :slave.stop(ctx.compatible)

      # Assert that all the expected messages get enqueued
      assert_receive {:"$gen_cast",
                      {:enqueue,
                       [
                         {^subscriber,
                          {:DOWN, ^target_ref_a_1, :process, ^target_a, {:zen_monitor, :nodedown}}},
                         {^subscriber,
                          {:DOWN, ^target_ref_a_2, :process, ^target_a, {:zen_monitor, :nodedown}}},
                         {^subscriber,
                          {:DOWN, ^target_ref_b_1, :process, ^target_b, {:zen_monitor, :nodedown}}},
                         {^subscriber,
                          {:DOWN, ^target_ref_b_2, :process, ^target_b, {:zen_monitor, :nodedown}}},
                         {^subscriber,
                          {:DOWN, ^target_ref_c_1, :process, ^target_c, {:zen_monitor, :nodedown}}},
                         {^subscriber,
                          {:DOWN, ^target_ref_c_2, :process, ^target_c, {:zen_monitor, :nodedown}}}
                       ]}}
    end
  end

  describe "Handles summaries" do
    setup [:fast_zen_monitor, :observe_zen_monitor, :disable_sweep, :start_remote_process]

    test "empty summary does nothing", ctx do
      connector = Connector.get_for_node(ctx.compatible)

      # Send the connector an empty list of death certificates
      send(connector, {:dead, ctx.compatible, []})

      # Assert that ZenMonitor.Local doesn't receive an enqueue
      refute_receive _
    end

    test "unmonitored pids does nothing", ctx do
      connector = Connector.get_for_node(ctx.compatible)

      # Send some unmonitored pids
      send(
        connector,
        {:dead, ctx.compatible,
         [
           {ctx.compatible_pid, :test_a},
           {ctx.compatible_pid_b, :test_b},
           {ctx.compatible_pid_c, :test_c}
         ]}
      )

      # Assert that ZenMonitor.Local doesn't receive an enqueue
      refute_receive _
    end

    test "monitored pids get enqueued", ctx do
      subscriber = self()
      reference_a = make_ref()
      reference_b = make_ref()
      reference_c = make_ref()
      target_a = ctx.compatible_pid()
      target_b = ctx.compatible_pid_b()
      target_c = ctx.compatible_pid_c()
      connector = Connector.get_for_node(ctx.compatible)

      # Monitor some pids
      Connector.monitor(target_a, reference_a, subscriber)
      Connector.monitor(target_b, reference_b, subscriber)
      Connector.monitor(target_c, reference_c, subscriber)

      # Send the monitored pids in the summary
      send(
        connector,
        {:dead, ctx.compatible, [{target_a, :test_a}, {target_b, :test_b}, {target_c, :test_c}]}
      )

      # Assert that ZenMonitor.Local receives an enqueue
      assert_receive {:"$gen_cast",
                      {:enqueue,
                       [
                         {^subscriber,
                          {:DOWN, ^reference_a, :process, ^target_a, {:zen_monitor, :test_a}}},
                         {^subscriber,
                          {:DOWN, ^reference_b, :process, ^target_b, {:zen_monitor, :test_b}}},
                         {^subscriber,
                          {:DOWN, ^reference_c, :process, ^target_c, {:zen_monitor, :test_c}}}
                       ]}}
    end

    test "mixed pids, monitored enqueue, unmonitored ignored", ctx do
      subscriber = self()
      reference_a = make_ref()
      reference_c = make_ref()
      target_a = ctx.compatible_pid()
      target_b = ctx.compatible_pid_b()
      target_c = ctx.compatible_pid_c()
      connector = Connector.get_for_node(ctx.compatible)

      # Monitor some pids (intentionally skip target_b)
      Connector.monitor(target_a, reference_a, subscriber)
      Connector.monitor(target_c, reference_c, subscriber)

      # Send the mixed pids in the summary
      send(
        connector,
        {:dead, ctx.compatible, [{target_a, :test_a}, {target_b, :test_b}, {target_c, :test_c}]}
      )

      # Assert that ZenMonitor.Local receives an enqueue
      assert_receive {:"$gen_cast",
                      {:enqueue,
                       [
                         {^subscriber,
                          {:DOWN, ^reference_a, :process, ^target_a, {:zen_monitor, :test_a}}},
                         {^subscriber,
                          {:DOWN, ^reference_c, :process, ^target_c, {:zen_monitor, :test_c}}}
                       ]}}

      # Assert that no other messages arrive
      refute_receive _
    end
  end

  describe "Periodic Sweep to compatible remote" do
    setup [:observe_gen, :disable_sweep, :reduce_chunk_size, :start_remote_process]

    test "sweep does not send a subscription if there are no newly monitored pids", ctx do
      connector = Connector.get_for_node(ctx.compatible)

      # Force the connector to sweep nothing
      send(connector, :sweep)

      # Assert that no subscription is sent because nothing is pending
      refute_receive {:observe, :cast, _, _}
    end

    test "sweep sends the monitored pids since the last sweep", ctx do
      target = ctx.compatible_pid()
      remote = ctx.compatible()
      connector = Connector.get_for_node(remote)

      # Monitor the target pid
      Connector.monitor(target, make_ref(), self())

      # Force a sweep
      send(connector, :sweep)

      assert_receive {
        :observe,
        :cast,
        {ZenMonitor.Proxy, ^remote},
        {:process, ^connector, [{:subscribe, ^target}]}
      }
    end

    test "sweep ignores already monitored pids on subsequenet sweeps", ctx do
      target = ctx.compatible_pid()
      remote = ctx.compatible()
      connector = Connector.get_for_node(remote)

      # Monitor the target pid
      Connector.monitor(target, make_ref(), self())

      # Force a sweep
      send(connector, :sweep)

      # Flush out the initial message
      assert_receive {
        :observe,
        :cast,
        {ZenMonitor.Proxy, ^remote},
        {:process, ^connector, [{:subscribe, ^target}]}
      }

      # Monitor the target pid again
      Connector.monitor(target, make_ref(), self())

      # Force another sweep
      send(connector, :sweep)

      # Assert that no additional subscriptions are sent
      refute_receive {:observe, :cast, _, _}
    end

    test "sweep transmits pids in the order received", ctx do
      first = ctx.compatible_pid()
      second = ctx.compatible_pid_b()
      remote = ctx.compatible
      connector = Connector.get_for_node(remote)

      # Monitor the targets
      Connector.monitor(first, make_ref(), self())
      Connector.monitor(second, make_ref(), self())

      # Force a sweep
      send(connector, :sweep)

      # Assert that we got a subscription in the correct order (first, second)
      assert_receive {
        :observe,
        :cast,
        {ZenMonitor.Proxy, ^remote},
        {:process, ^connector, [{:subscribe, ^first}, {:subscribe, ^second}]}
      }
    end

    test "sweep will only transmit the requested chunk size", ctx do
      target_a = ctx.compatible_pid()
      target_b = ctx.compatible_pid_b()
      target_c = ctx.compatible_pid_c()
      remote = ctx.compatible()
      connector = Connector.get_for_node(remote)

      # Monitor all targets
      Connector.monitor(target_a, make_ref(), self())
      Connector.monitor(target_b, make_ref(), self())
      Connector.monitor(target_c, make_ref(), self())

      # Force a sweep
      send(connector, :sweep)

      # Assert that we got a subscription for the first chunk (target_a, target_b)
      assert_receive {
        :observe,
        :cast,
        {ZenMonitor.Proxy, ^remote},
        {:process, ^connector, [{:subscribe, ^target_a}, {:subscribe, ^target_b}]}
      }

      # Force another sweep
      send(connector, :sweep)

      # Assert that we got a subscription for the second chunk (target_b)
      assert_receive {
        :observe,
        :cast,
        {ZenMonitor.Proxy, ^remote},
        {:process, ^connector, [{:subscribe, ^target_c}]}
      }
    end
  end

  describe "Periodic Sweep to incompatible remote" do
    setup [:observe_zen_monitor, :disable_sweep, :reduce_chunk_size, :start_remote_process]

    test "sweep does not send a message if there are no newly monitored pids", ctx do
      connector = Connector.get_for_node(ctx.incompatible)

      # Force the connector to sweep nothing
      send(connector, :sweep)

      # Assert that no dead message is sent
      refute_receive {:"$gen_cast", {:enqueue, _}}
    end

    test "sweep sends nodedown for incompatible remote", ctx do
      subscriber = self()
      reference = make_ref()
      target = ctx.incompatible_pid()
      remote = ctx.incompatible()
      connector = Connector.get_for_node(remote)

      # Monitor the target pid
      Connector.monitor(target, reference, subscriber)

      # Force a sweep
      send(connector, :sweep)

      # Assert that the message is enqueued with ZenMonitor.Local (via GenServer.cast)
      assert_receive {
        :"$gen_cast",
        {
          :enqueue,
          [{^subscriber, {:DOWN, ^reference, :process, ^target, {:zen_monitor, :nodedown}}}]
        }
      }
    end
  end
end
