defmodule ZenMonitor.BlackBox.Test do
  @moduledoc """
  This test suite treats the ZenMonitor system as a black box and simply asserts that the client
  facing behavior is correct.
  """
  use ExUnit.Case

  alias ZenMonitor.Local.{Connector, Dispatcher}
  alias ZenMonitor.Proxy.Batcher

  setup do
    start_supervised(ZenMonitor.Supervisor)
    {:ok, down: :down@down, remotes: []}
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
      Enum.map([node() | ctx.remotes], fn remote ->
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

  def start_compatible_remote(ctx) do
    {:ok, compatible, nil} = ChildNode.start_link(:zen_monitor, :Compatible)

    # Perform an initial connect like discovery would
    Node.connect(compatible)

    on_exit(fn ->
      Node.monitor(compatible, true)

      receive do
        {:nodedown, ^compatible} -> :ok
      end
    end)

    {:ok, compatible: compatible, remotes: [compatible | ctx.remotes()]}
  end

  def start_incompatible_remote(_) do
    {:ok, incompatible, nil} = ChildNode.start_link(:elixir, :Incompatible)

    # Perform an initial connect like discovery would
    Node.connect(incompatible)

    on_exit(fn ->
      Node.monitor(incompatible, true)

      receive do
        {:nodedown, ^incompatible} -> :ok
      end
    end)

    {:ok, incompatible: incompatible}
  end

  def start_compatible_processes(ctx) do
    compatible_pid = Node.spawn(ctx.compatible, Process, :sleep, [:infinity])
    compatible_pid_b = Node.spawn(ctx.compatible, Process, :sleep, [:infinity])

    {:ok, compatible_pid: compatible_pid, compatible_pid_b: compatible_pid_b}
  end

  def start_incompatible_processes(ctx) do
    incompatible_pid = Node.spawn(ctx.incompatible, Process, :sleep, [:infinity])
    incompatible_pid_b = Node.spawn(ctx.incompatible, Process, :sleep, [:infinity])

    {:ok, incompatible_pid: incompatible_pid, incompatible_pid_b: incompatible_pid_b}
  end

  def start_local_processes(_) do
    local_pid = spawn(fn -> Process.sleep(:infinity) end)
    local_pid_b = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, local_pid: local_pid, local_pid_b: local_pid_b}
  end

  describe "Monitoring a local process" do
    setup [:fast_zen_monitor, :start_local_processes]

    test "monitoring a local process returns a reference", ctx do
      ref = ZenMonitor.monitor(ctx.local_pid)
      assert is_reference(ref)
    end

    test "local process returns a :DOWN message if it goes down", ctx do
      target = ctx.local_pid()

      # Monitor the local process
      ref = ZenMonitor.monitor(target)
      Helper.await_monitor_established(ref, target)

      # Kill the local process
      Process.exit(target, :kill)
      Helper.await_monitor_cleared(ref, target)

      # Assert that we receive the down messages
      assert_receive {:DOWN, ^ref, :process, ^target, {:zen_monitor, :killed}}

      # Make sure that we don't receive any additional messages
      refute_receive {:DOWN, _, _, _, _}
    end

    test "multiple monitors all get fired", ctx do
      target = ctx.local_pid()

      # Monitor the local process multiple times
      ref_a = ZenMonitor.monitor(target)
      ref_b = ZenMonitor.monitor(target)
      ref_c = ZenMonitor.monitor(target)
      Helper.await_monitors_established([ref_a, ref_b, ref_c], target)

      # Kill the local process
      Process.exit(target, :kill)
      Helper.await_monitors_cleared([ref_a, ref_b, ref_c], target)

      # Assert that we receive down message for each monitor
      assert_receive {:DOWN, ^ref_a, :process, ^target, {:zen_monitor, :killed}}
      assert_receive {:DOWN, ^ref_b, :process, ^target, {:zen_monitor, :killed}}
      assert_receive {:DOWN, ^ref_c, :process, ^target, {:zen_monitor, :killed}}

      # Make sure that we don't receive any additional messages
      refute_receive {:DOWN, _, _, _, _}
    end

    test "an already down local process returns a :DOWN message", ctx do
      target = ctx.local_pid()

      # Kill the local process, before the monitors
      Process.exit(target, :kill)

      # Monitor the local process
      ref = ZenMonitor.monitor(target)
      Helper.await_monitor_cleared(ref, target)

      # Assert that we receive the correct reason
      assert_receive {:DOWN, ^ref, :process, ^target, {:zen_monitor, :noproc}}

      # Make sure that we don't receive any additional messages
      refute_receive {:DOWN, _, _, _, _}
    end

    test "multiple monitors for already down local process returns :DOWN messages", ctx do
      target = ctx.local_pid()

      # Kill the local process, before the monitors
      Process.exit(target, :kill)

      # Monitor the local process multiple times
      ref_a = ZenMonitor.monitor(target)
      ref_b = ZenMonitor.monitor(target)
      ref_c = ZenMonitor.monitor(target)

      Helper.await_monitors_cleared([ref_a, ref_b, ref_c], target)

      # Assert that we receive multiple :DOWN messages with the correct reason
      assert_receive {:DOWN, ^ref_a, :process, ^target, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^ref_b, :process, ^target, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^ref_c, :process, ^target, {:zen_monitor, :noproc}}

      # Make sure that we don't receive any additional messages
      refute_receive {:DOWN, _, _, _, _}
    end

    test "mixed monitors established before and after process down", ctx do
      target = ctx.local_pid()

      # Establish some monitors before the pid is killed
      ref_alive_a = ZenMonitor.monitor(target)
      ref_alive_b = ZenMonitor.monitor(target)
      Helper.await_monitors_established([ref_alive_a, ref_alive_b], target)

      # Kill the local process
      Process.exit(target, :kill)
      Helper.await_monitors_cleared([ref_alive_a, ref_alive_b], target)

      # Assert that the initial monitors fire
      assert_receive {:DOWN, ^ref_alive_a, :process, ^target, {:zen_monitor, :killed}}
      assert_receive {:DOWN, ^ref_alive_b, :process, ^target, {:zen_monitor, :killed}}

      # Establish some monitors after the pid is killed
      ref_dead_a = ZenMonitor.monitor(target)
      ref_dead_b = ZenMonitor.monitor(target)

      Helper.await_monitors_cleared([ref_dead_a, ref_dead_b], target)

      # Assert that the new monitors got the expected :DOWN messages with the correct reason
      assert_receive {:DOWN, ^ref_dead_a, :process, ^target, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^ref_dead_b, :process, ^target, {:zen_monitor, :noproc}}

      # Make sure that we don't receive any additional messages
      refute_receive {:DOWN, _, _, _, _}
    end

    test "multiple down processes all report back as :DOWN", ctx do
      target = ctx.local_pid()
      other = ctx.local_pid_b()

      # Establish multiple monitors for each process
      target_ref_a = ZenMonitor.monitor(target)
      target_ref_b = ZenMonitor.monitor(target)
      other_ref_a = ZenMonitor.monitor(other)
      other_ref_b = ZenMonitor.monitor(other)

      Helper.await_monitors_established([target_ref_a, target_ref_b], target)
      Helper.await_monitors_established([other_ref_a, other_ref_b], other)

      # Kill both local processes
      Process.exit(target, :kill)
      Process.exit(other, :kill)

      Helper.await_monitors_cleared([target_ref_a, target_ref_b], target)
      Helper.await_monitors_cleared([other_ref_a, other_ref_b], other)

      # Assert that we receive all the expected :DOWN messages
      assert_receive {:DOWN, ^target_ref_a, :process, ^target, {:zen_monitor, :killed}}
      assert_receive {:DOWN, ^target_ref_b, :process, ^target, {:zen_monitor, :killed}}
      assert_receive {:DOWN, ^other_ref_a, :process, ^other, {:zen_monitor, :killed}}
      assert_receive {:DOWN, ^other_ref_b, :process, ^other, {:zen_monitor, :killed}}
    end

    test "multiple already down process all report back as :DOWN", ctx do
      target = ctx.local_pid()
      other = ctx.local_pid_b()

      # Kill both local processes
      Process.exit(target, :kill)
      Process.exit(other, :kill)

      # Establish multiple monitors for each process
      target_ref_a = ZenMonitor.monitor(target)
      target_ref_b = ZenMonitor.monitor(target)
      other_ref_a = ZenMonitor.monitor(other)
      other_ref_b = ZenMonitor.monitor(other)

      Helper.await_monitors_cleared([target_ref_a, target_ref_b], target)
      Helper.await_monitors_cleared([other_ref_a, other_ref_b], other)

      # Assert that we receive all the expected :DOWN messages
      assert_receive {:DOWN, ^target_ref_a, :process, ^target, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^target_ref_b, :process, ^target, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^other_ref_a, :process, ^other, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^other_ref_b, :process, ^other, {:zen_monitor, :noproc}}
    end

    test "mixed down processes all report back as :DOWN", ctx do
      target = ctx.local_pid()
      other = ctx.local_pid_b()

      # Kill target before establishing any monitors
      Process.exit(target, :kill)

      # Establish multiple monitors for each process
      target_ref_a = ZenMonitor.monitor(target)
      target_ref_b = ZenMonitor.monitor(target)
      other_ref_a = ZenMonitor.monitor(other)
      other_ref_b = ZenMonitor.monitor(other)
      Helper.await_monitors_established([other_ref_a, other_ref_b], other)

      # Kill other after establishing the monitors
      Process.exit(other, :kill)
      Helper.await_monitors_cleared([target_ref_a, target_ref_b], target)
      Helper.await_monitors_cleared([other_ref_a, other_ref_b], other)

      # Assert that we receive all the expected :DOWN messages
      assert_receive {:DOWN, ^target_ref_a, :process, ^target, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^target_ref_b, :process, ^target, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^other_ref_a, :process, ^other, {:zen_monitor, :killed}}
      assert_receive {:DOWN, ^other_ref_b, :process, ^other, {:zen_monitor, :killed}}
    end
  end

  describe "Monitoring a remote process on a compatible node" do
    setup [:start_compatible_remote, :start_compatible_processes, :fast_zen_monitor]

    test "monitoring a remote process returns a reference", ctx do
      ref = ZenMonitor.monitor(ctx.compatible_pid)
      assert is_reference(ref)
    end

    test "remote process returns a :DOWN message if it goes down", ctx do
      target = ctx.compatible_pid()

      # Monitor the remote process
      ref = ZenMonitor.monitor(target)
      Helper.await_monitor_established(ref, target)

      # Kill the remote process
      Process.exit(target, :kill)
      Helper.await_monitor_cleared(ref, target)

      # Assert that we receive the down messages
      assert_receive {:DOWN, ^ref, :process, ^target, {:zen_monitor, :killed}}

      # Make sure that we don't receive any additional messages
      refute_receive {:DOWN, _, _, _, _}
    end

    test "multiple monitors all get fired", ctx do
      target = ctx.compatible_pid()

      # Monitor the remote process multiple times
      ref_a = ZenMonitor.monitor(target)
      ref_b = ZenMonitor.monitor(target)
      ref_c = ZenMonitor.monitor(target)
      Helper.await_monitors_established([ref_a, ref_b, ref_c], target)

      # Kill the remote process
      Process.exit(target, :kill)
      Helper.await_monitors_cleared([ref_a, ref_b, ref_c], target)

      # Assert that we receive down message for each monitor
      assert_receive {:DOWN, ^ref_a, :process, ^target, {:zen_monitor, :killed}}
      assert_receive {:DOWN, ^ref_b, :process, ^target, {:zen_monitor, :killed}}
      assert_receive {:DOWN, ^ref_c, :process, ^target, {:zen_monitor, :killed}}

      # Make sure that we don't receive any additional messages
      refute_receive {:DOWN, _, _, _, _}
    end

    test "an already down remote process returns a :DOWN message", ctx do
      target = ctx.compatible_pid()

      # Kill the remote process, before the monitors
      Process.exit(target, :kill)

      # Monitor the remote process
      ref = ZenMonitor.monitor(target)
      Helper.await_monitor_cleared(ref, target)
      # Assert that we receive the correct reason
      assert_receive {:DOWN, ^ref, :process, ^target, {:zen_monitor, :noproc}}

      # Make sure that we don't receive any additional messages
      refute_receive {:DOWN, _, _, _, _}
    end

    test "multiple monitors for alread down remote process returns :DOWN messages", ctx do
      target = ctx.compatible_pid()

      # Kill the remote process, before the monitors
      Process.exit(target, :kill)

      # Monitor the remote process multiple times
      ref_a = ZenMonitor.monitor(target)
      ref_b = ZenMonitor.monitor(target)
      ref_c = ZenMonitor.monitor(target)

      Helper.await_monitors_cleared([ref_a, ref_b, ref_c], target)

      # Assert that we receive multiple :DOWN messages with the correct reason
      assert_receive {:DOWN, ^ref_a, :process, ^target, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^ref_b, :process, ^target, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^ref_c, :process, ^target, {:zen_monitor, :noproc}}

      # Make sure that we don't receive any additional messages
      refute_receive {:DOWN, _, _, _, _}
    end

    test "mixed monitors established before and after process down", ctx do
      target = ctx.compatible_pid()

      # Establish some monitors before the pid is killed
      ref_alive_a = ZenMonitor.monitor(target)
      ref_alive_b = ZenMonitor.monitor(target)
      Helper.await_monitors_established([ref_alive_a, ref_alive_b], target)

      # Kill the remote process
      Process.exit(target, :kill)
      Helper.await_monitors_cleared([ref_alive_a, ref_alive_b], target)

      # Assert that the initial monitors fire
      assert_receive {:DOWN, ^ref_alive_a, :process, ^target, {:zen_monitor, :killed}}
      assert_receive {:DOWN, ^ref_alive_b, :process, ^target, {:zen_monitor, :killed}}

      # Establish some monitors after the pid is killed
      ref_dead_a = ZenMonitor.monitor(target)
      ref_dead_b = ZenMonitor.monitor(target)
      Helper.await_monitors_cleared([ref_dead_a, ref_dead_b], target)

      # Assert that the new monitors got the expected :DOWN messages with the correct reason
      assert_receive {:DOWN, ^ref_dead_a, :process, ^target, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^ref_dead_b, :process, ^target, {:zen_monitor, :noproc}}

      # Make sure that we don't receive any additional messages
      refute_receive {:DOWN, _, _, _, _}
    end

    test "multiple down processes all report back as :DOWN", ctx do
      target = ctx.compatible_pid()
      other = ctx.compatible_pid_b()

      # Establish multiple monitors for each process
      target_ref_a = ZenMonitor.monitor(target)
      target_ref_b = ZenMonitor.monitor(target)
      other_ref_a = ZenMonitor.monitor(other)
      other_ref_b = ZenMonitor.monitor(other)
      Helper.await_monitors_established([target_ref_a, target_ref_b], target)
      Helper.await_monitors_established([other_ref_a, other_ref_b], other)

      # Kill both remote processes
      Process.exit(target, :kill)
      Process.exit(other, :kill)
      Helper.await_monitors_cleared([target_ref_a, target_ref_b], target)
      Helper.await_monitors_cleared([other_ref_a, other_ref_b], other)

      # Assert that we receive all the expected :DOWN messages
      assert_receive {:DOWN, ^target_ref_a, :process, ^target, {:zen_monitor, :killed}}
      assert_receive {:DOWN, ^target_ref_b, :process, ^target, {:zen_monitor, :killed}}
      assert_receive {:DOWN, ^other_ref_a, :process, ^other, {:zen_monitor, :killed}}
      assert_receive {:DOWN, ^other_ref_b, :process, ^other, {:zen_monitor, :killed}}
    end

    test "multiple already down process all report back as :DOWN", ctx do
      target = ctx.compatible_pid()
      other = ctx.compatible_pid_b()

      # Kill both remote processes
      Process.exit(target, :kill)
      Process.exit(other, :kill)

      # Establish multiple monitors for each process
      target_ref_a = ZenMonitor.monitor(target)
      target_ref_b = ZenMonitor.monitor(target)
      other_ref_a = ZenMonitor.monitor(other)
      other_ref_b = ZenMonitor.monitor(other)

      Helper.await_monitors_cleared([target_ref_a, target_ref_b], target)
      Helper.await_monitors_cleared([other_ref_a, other_ref_b], other)

      # Assert that we receive all the expected :DOWN messages
      assert_receive {:DOWN, ^target_ref_a, :process, ^target, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^target_ref_b, :process, ^target, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^other_ref_a, :process, ^other, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^other_ref_b, :process, ^other, {:zen_monitor, :noproc}}
    end

    test "mixed down processes all report back as :DOWN", ctx do
      target = ctx.compatible_pid()
      other = ctx.compatible_pid_b()

      # Kill target before establishing any monitors
      Process.exit(target, :kill)

      # Establish multiple monitors for each process
      target_ref_a = ZenMonitor.monitor(target)
      target_ref_b = ZenMonitor.monitor(target)
      other_ref_a = ZenMonitor.monitor(other)
      other_ref_b = ZenMonitor.monitor(other)
      Helper.await_monitors_established([other_ref_a, other_ref_b], other)

      # Kill other after establishing the monitors
      Process.exit(other, :kill)
      Helper.await_monitors_cleared([other_ref_a, other_ref_b], other)

      # Assert that we receive all the expected :DOWN messages
      assert_receive {:DOWN, ^target_ref_a, :process, ^target, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^target_ref_b, :process, ^target, {:zen_monitor, :noproc}}
      assert_receive {:DOWN, ^other_ref_a, :process, ^other, {:zen_monitor, :killed}}
      assert_receive {:DOWN, ^other_ref_b, :process, ^other, {:zen_monitor, :killed}}
    end

    test "all monitored processes report back as :DOWN if the node dies", ctx do
      remote = ctx.compatible()
      target = ctx.compatible_pid()
      other = ctx.compatible_pid_b()

      # Monitor both remote processes
      target_ref = ZenMonitor.monitor(target)
      other_ref = ZenMonitor.monitor(other)
      Helper.await_monitor_established(target_ref, target)
      Helper.await_monitor_established(other_ref, other)

      # Stop the remote node
      assert :ok = :slave.stop(remote)
      Helper.await_monitor_cleared(target_ref, target)
      Helper.await_monitor_cleared(other_ref, other)

      # Assert that the :DOWN messages were dispatched with :nodedown
      assert_receive {:DOWN, ^target_ref, :process, ^target, {:zen_monitor, :nodedown}}
      assert_receive {:DOWN, ^other_ref, :process, ^other, {:zen_monitor, :nodedown}}
    end
  end

  describe "Monitoring a remote process on an incompatible node" do
    setup [:start_incompatible_remote, :start_incompatible_processes, :fast_zen_monitor]

    test "monitoring a remote process returns a reference", ctx do
      ref = ZenMonitor.monitor(ctx.incompatible_pid)
      assert is_reference(ref)
    end

    test "monitoring returns down with :nodedown", ctx do
      target = ctx.incompatible_pid()

      # Attempt to monitor incompatible node
      ref = ZenMonitor.monitor(target)

      # Assert that the :DOWN message with :incompatible are delivered
      assert_receive {:DOWN, ^ref, :process, ^target, {:zen_monitor, :nodedown}}
    end

    test "monitoring multiple returns multiple downs with :nodedown", ctx do
      target = ctx.incompatible_pid()
      other = ctx.incompatible_pid_b()

      # Attempt to monitor all the incompatible processes
      target_ref = ZenMonitor.monitor(target)
      other_ref = ZenMonitor.monitor(other)

      # Assert that the :DOWN messages with :incompatible are delivered
      assert_receive {:DOWN, ^target_ref, :process, ^target, {:zen_monitor, :nodedown}}
      assert_receive {:DOWN, ^other_ref, :process, ^other, {:zen_monitor, :nodedown}}
    end
  end

  describe "Monitoring a remote process on a compatible node that becomes incompatible" do
    setup [:start_compatible_remote, :start_compatible_processes, :fast_zen_monitor]

    test "monitoring a remote process returns a reference", ctx do
      ref = ZenMonitor.monitor(ctx.compatible_pid())
      assert is_reference(ref)
    end

    test "subscribing to a previously compatible host will cause :nodedown", ctx do
      remote = ctx.compatible()
      target = ctx.compatible_pid()
      other = ctx.compatible_pid_b()

      # Perform an initial monitor
      target_ref = ZenMonitor.monitor(target)
      Helper.await_monitor_established(target_ref, target)

      # Check that the remote is considered compatible
      assert :compatible = ZenMonitor.compatibility_for_node(remote)

      # Make the remote incompatible by killing the ZenMonitor running on it
      assert :ok = :rpc.call(remote, Application, :stop, [:zen_monitor])

      # Perform an additional monitor
      other_ref = ZenMonitor.monitor(other)

      Helper.await_monitor_cleared(target_ref, target)

      # Assert that we get notified for both monitored processes
      assert_receive {:DOWN, ^target_ref, :process, ^target, {:zen_monitor, :nodedown}}
      assert_receive {:DOWN, ^other_ref, :process, ^other, {:zen_monitor, :nodedown}}

      # Check that the remote is no longer considered compatible
      assert :incompatible = ZenMonitor.compatibility_for_node(remote)
    end
  end

  describe "Monitoring has process-level multi-tenancy" do
    setup [:start_compatible_remote, :start_compatible_processes, :fast_zen_monitor]

    test "only the down process sends a :DOWN message", ctx do
      target = ctx.compatible_pid()
      other = ctx.compatible_pid_b()

      # Monitor both remote processes
      target_ref = ZenMonitor.monitor(target)
      other_ref = ZenMonitor.monitor(other)
      Helper.await_monitor_established(target_ref, target)
      Helper.await_monitor_established(other_ref, other)

      # Kill the target process
      Process.exit(target, :kill)
      Helper.await_monitor_cleared(target_ref, target)

      # Assert that we receive a :DOWN for the target
      assert_receive {:DOWN, ^target_ref, :process, ^target, {:zen_monitor, _}}

      # Assert that we do not receive a :DOWN for the other process
      refute_receive {:DOWN, ^other_ref, :process, ^other, {:zen_monitor, _}}
    end

    test "only the already down process sends a :DOWN message", ctx do
      target = ctx.compatible_pid()
      other = ctx.compatible_pid_b()

      # Kill the target process
      Process.exit(target, :kill)

      # Monitor both remote processes
      target_ref = ZenMonitor.monitor(target)
      other_ref = ZenMonitor.monitor(other)

      # Assert that we receive a :DOWN for the target
      assert_receive {:DOWN, ^target_ref, :process, ^target, {:zen_monitor, _}}

      # Assert that we do not receive a :DOWN for the other process
      refute_receive {:DOWN, ^other_ref, :process, ^other, {:zen_monitor, _}}
    end
  end

  describe "Demonitor" do
    setup [:start_compatible_remote, :start_compatible_processes, :fast_zen_monitor]

    test "prevents :DOWN from being delivered", ctx do
      target = ctx.compatible_pid()

      # Monitor the remote process
      ref = ZenMonitor.monitor(target)

      # Demonitor the reference
      ZenMonitor.demonitor(ref)

      # Kill the process
      Process.exit(target, :kill)

      # Assert that nothing was delivered
      refute_receive {:DOWN, ^ref, :process, ^target, _}
    end

    test ":DOWN sent before demonitor still exists", ctx do
      target = ctx.compatible_pid()

      # Monitor the remote process
      ref = ZenMonitor.monitor(target)
      Helper.await_monitor_established(ref, target)

      # Kill the remote process
      Process.exit(target, :kill)
      Helper.await_monitor_cleared(ref, target)

      # Demonitor the reference
      ZenMonitor.demonitor(ref)

      # Assert that a down message had already been received
      assert_received {:DOWN, ^ref, :process, ^target, {:zen_monitor, _}}
    end

    test "only effects the demonitored reference", ctx do
      target = ctx.compatible_pid()

      # Monitor the remote process twice
      ref_to_demonitor = ZenMonitor.monitor(target)
      ref_to_keep = ZenMonitor.monitor(target)
      Helper.await_monitors_established([ref_to_demonitor, ref_to_keep], target)

      # Demonitor one of the references
      ZenMonitor.demonitor(ref_to_demonitor)

      # Kill the remote process
      Process.exit(target, :kill)
      Helper.await_monitor_cleared(ref_to_keep, target)

      # Assert that the monitor that was not demonitored fired
      assert_receive {:DOWN, ^ref_to_keep, :process, ^target, {:zen_monitor, _}}

      # Assert that the demonitored monitor did not fire
      refute_receive {:DOWN, ^ref_to_demonitor, :process, ^target, _}
    end
  end

  describe "Demonitor Flush" do
    setup [:start_compatible_remote, :start_compatible_processes, :fast_zen_monitor]

    test "prevents :DOWN from being delivered", ctx do
      target = ctx.compatible_pid()

      # Monitor the remote process
      ref = ZenMonitor.monitor(target)
      Helper.await_monitor_established(ref, target)

      # Demonitor the reference
      ZenMonitor.demonitor(ref, [:flush])

      # Kill the process
      Process.exit(target, :kill)
      Helper.await_monitor_cleared(ref, target)

      # Assert that nothing was delivered
      refute_receive {:DOWN, ^ref, :process, ^target, _}
    end

    test ":DOWN sent before demonitor will be consumed by the flush", ctx do
      target = ctx.compatible_pid()

      # Monitor the remote process
      ref = ZenMonitor.monitor(target)
      Helper.await_monitor_established(ref, target)

      # Kill the remote process
      Process.exit(target, :kill)
      Helper.await_monitor_cleared(ref, target)

      # Demonitor the reference
      ZenMonitor.demonitor(ref, [:flush])

      # Assert that no down message has been received
      refute_receive {:DOWN, ^ref, :process, ^target, {:zen_monitor, _}}
    end

    test ":flush only removes the flushed reference", ctx do
      target = ctx.compatible_pid()

      # Monitor the remote process twice
      ref_to_flush = ZenMonitor.monitor(target)
      ref_to_demonitor = ZenMonitor.monitor(target)
      ref_to_keep = ZenMonitor.monitor(target)
      Helper.await_monitors_established([ref_to_flush, ref_to_demonitor, ref_to_keep], target)

      # Kill the remote process
      Process.exit(target, :kill)
      Helper.await_monitors_cleared([ref_to_flush, ref_to_demonitor, ref_to_keep], target)

      # Flush one of the references
      ZenMonitor.demonitor(ref_to_flush, [:flush])

      # Demonitor one of the references
      ZenMonitor.demonitor(ref_to_demonitor)

      # Assert that the monitor that was not demonitored fired
      assert_receive {:DOWN, ^ref_to_keep, :process, ^target, {:zen_monitor, _}}

      # Assert that the demonitored non-flush monitor fired
      assert_receive {:DOWN, ^ref_to_demonitor, :process, ^target, {:zen_monitor, _}}

      # Assert that the demonitored and flushed monitor did not fire
      refute_receive {:DOWN, ^ref_to_flush, :process, ^target, _}
    end
  end

  describe "Compatibility For Node" do
    setup [:start_compatible_remote, :start_incompatible_remote]

    test "when remote is compatible", ctx do
      assert :compatible = ZenMonitor.connect(ctx.compatible)
      assert :compatible = ZenMonitor.compatibility_for_node(ctx.compatible)
    end

    test "when remote is incompatible", ctx do
      assert :incompatible = ZenMonitor.connect(ctx.incompatible)
      assert :incompatible = ZenMonitor.compatibility_for_node(ctx.incompatible)
    end

    test "when remote is down", ctx do
      assert :incompatible = ZenMonitor.connect(ctx.down)
      assert :incompatible = ZenMonitor.compatibility_for_node(ctx.down)
    end
  end
end
