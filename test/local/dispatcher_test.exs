defmodule ZenMonitor.Local.Dispatcher.Test do
  use ExUnit.Case

  alias ZenMonitor.Local.{Connector, Dispatcher}
  alias ZenMonitor.Proxy.Batcher

  setup do
    {:ok, remote, nil} = ChildNode.start_link(:zen_monitor, :Remote)

    start_supervised(ZenMonitor.Supervisor)
    {:ok, _} = Application.ensure_all_started(:instruments)

    on_exit(fn ->
      Node.monitor(remote, true)

      receive do
        {:nodedown, ^remote} -> :ok
      end
    end)

    {:ok, remote: remote}
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

    # Tune the remote batcher
    original_batcher_interval = :rpc.call(ctx.remote, Batcher, :sweep_interval, [])
    :ok = :rpc.call(ctx.remote, Batcher, :sweep_interval, [10])

    on_exit(fn ->
      # Restore the local settings
      Dispatcher.demand_interval(original_demand_interval)
      Connector.sweep_interval(original_connector_interval)

      # Restore the remote settings
      :rpc.call(ctx.remote, Batcher, :sweep_interval, [original_batcher_interval])
    end)

    :ok
  end

  def start_remote_process(ctx) do
    remote_pid = Node.spawn(ctx.remote, Process, :sleep, [:infinity])
    alternate_remote_pid = Node.spawn(ctx.remote, Process, :sleep, [:infinity])

    {:ok, remote_pid: remote_pid, alternate_remote_pid: alternate_remote_pid}
  end

  describe "Event Dispatch" do
    setup [:fast_zen_monitor, :start_remote_process]

    test "no messages are sent when there is nothing monitored" do
      # Assert that we receive no messages
      refute_receive _
    end

    test "no messages are sent when the monitored process is still running", ctx do
      # Monitor the remote process
      ZenMonitor.monitor(ctx.remote_pid)

      # Assert that we receive no messages
      refute_receive _
    end

    test "a message is dispatched when the monitored process dies", ctx do
      target = ctx.remote_pid()

      # Monitor the remote process
      ref = ZenMonitor.monitor(target)

      # Kill the remote process
      Process.exit(target, :kill)

      # Assert delivery of a :DOWN for the killed process
      assert_receive {:DOWN, ^ref, :process, ^target, {:zen_monitor, _}}, 1000
    end

    test "only the dead process gets a message dispatched", ctx do
      target = ctx.remote_pid()
      alternate = ctx.alternate_remote_pid()

      # Monitor both remote processes
      ref = ZenMonitor.monitor(target)
      ZenMonitor.monitor(alternate)

      # Kill the target remote process
      Process.exit(target, :kill)

      # Assert delivery of a :DOWN for the killed process and nothing else
      assert_receive {:DOWN, ^ref, :process, ^target, {:zen_monitor, _}}, 1000
      refute_receive _
    end

    test "monitoring a dead process should dispatch a :DOWN with :noproc", ctx do
      target = ctx.remote_pid()

      # Kill the remote process
      Process.exit(target, :kill)

      # Monitor the now dead remote process
      ref = ZenMonitor.monitor(target)

      # Assert delivery of a :DOWN :noproc
      assert_receive {:DOWN, ^ref, :process, ^target, {:zen_monitor, :noproc}}, 1000
    end

    test "monitoring a process after down and dispatched message dispatches another message",
         ctx do
      target = ctx.remote_pid()

      # Monitor the remote process
      ref = ZenMonitor.monitor(target)

      # Kill the target remote process
      Process.exit(target, :kill)

      # Assert initial delivery
      assert_receive {:DOWN, ^ref, :process, ^target, {:zen_monitor, _}}, 1000

      # Re-monitor the remote process
      another_ref = ZenMonitor.monitor(target)

      # Assert delivery of a :DOWN :noproc
      assert_receive {:DOWN, ^another_ref, :process, ^target, {:zen_monitor, :noproc}}, 1000
    end

    test "all monitored processes get delivered at nodedown", ctx do
      target = ctx.remote_pid()
      alternate = ctx.alternate_remote_pid()

      # Monitor both remote processes
      target_ref = ZenMonitor.monitor(target)
      alternate_ref = ZenMonitor.monitor(alternate)

      # Wait for the monitors to get dispatched to the remote
      Process.sleep(50)

      # Kill the remote node
      :slave.stop(ctx.remote)

      # Assert delivery of both :DOWN :nodedown messages
      assert_receive {:DOWN, ^target_ref, :process, ^target, {:zen_monitor, :nodedown}}, 1000

      assert_receive {:DOWN, ^alternate_ref, :process, ^alternate, {:zen_monitor, :nodedown}},
                     1000
    end
  end
end
