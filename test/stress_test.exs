defmodule ZenMonitor.Stress.Test do
  use ExUnit.Case

  alias ZenMonitor.Local.Connector

  @fast_interval 10
  @slow_interval 100

  @small_chunk 10
  @big_chunk 100_000

  setup do
    # Make the Batcher and Dispatcher dispatch at a controlled rate
    tune(node(), :batcher, :slow)
    tune(node(), :dispatcher, :slow)

    # Make the Connector flush everything very quickly
    tune(node(), :connector, :fast)

    start_supervised(ZenMonitor.Supervisor)
    {:ok, compatible, nil} = ChildNode.start_link(:zen_monitor, :Compatible)

    # Make the remote batcher flush at a controlled rate
    tune(compatible, :batcher, :slow)

    {:ok, down: :down@down, compatible: compatible, remotes: [compatible]}
  end

  def tune(remote, :batcher, :fast) do
    :rpc.call(remote, Application, :put_env, [
      :zen_monitor,
      :batcher_sweep_interval,
      @fast_interval
    ])

    :rpc.call(remote, Application, :put_env, [:zen_monitor, :batcher_chunk_size, @big_chunk])
  end

  def tune(remote, :batcher, :slow) do
    :rpc.call(remote, Application, :put_env, [
      :zen_monitor,
      :batcher_sweep_interval,
      @slow_interval
    ])

    :rpc.call(remote, Application, :put_env, [:zen_monitor, :batcher_chunk_size, @small_chunk])
  end

  def tune(remote, :connector, :fast) do
    :rpc.call(remote, Application, :put_env, [
      :zen_monitor,
      :connector_sweep_interval,
      @fast_interval
    ])

    :rpc.call(remote, Application, :put_env, [:zen_monitor, :connector_chunk_size, @big_chunk])
  end

  def tune(remote, :connector, :slow) do
    :rpc.call(remote, Application, :put_env, [
      :zen_monitor,
      :connector_sweep_interval,
      @slow_interval
    ])

    :rpc.call(remote, Application, :put_env, [:zen_monitor, :connector_chunk_size, @small_chunk])
  end

  def tune(remote, :dispatcher, :fast) do
    :rpc.call(remote, Application, :put_env, [:zen_monitor, :demand_interavl, @fast_interval])
    :rpc.call(remote, Application, :put_env, [:zen_monitor, :demand_amount, @big_chunk])
  end

  def tune(remote, :dispatcher, :slow) do
    :rpc.call(remote, Application, :put_env, [:zen_monitor, :demand_interval, @slow_interval])
    :rpc.call(remote, Application, :put_env, [:zen_monitor, :demand_amount, @small_chunk])
  end

  def start_processes(remote, amount) do
    Enum.map(1..amount, fn _ ->
      Node.spawn(remote, Process, :sleep, [:infinity])
    end)
  end

  def stop_processes(targets) do
    spawn(fn ->
      Enum.each(targets, &Process.exit(&1, :kill))
    end)
  end

  def flush_messages() do
    send(self(), :flush)

    receive_until_flush([])
  end

  def receive_until_flush(acc) do
    receive do
      msg ->
        if match?(:flush, msg) do
          Enum.reverse(acc)
        else
          receive_until_flush([msg | acc])
        end
    after
      0 ->
        raise "Flush not found!"
    end
  end

  describe "Massive remote failure" do
    test "local environment configured correctly" do
      assert @slow_interval == Application.get_env(:zen_monitor, :batcher_sweep_interval)
      assert @small_chunk == Application.get_env(:zen_monitor, :batcher_chunk_size)

      assert @slow_interval == Application.get_env(:zen_monitor, :demand_interval)
      assert @small_chunk == Application.get_env(:zen_monitor, :demand_amount)

      assert @fast_interval == Application.get_env(:zen_monitor, :connector_sweep_interval)
      assert @big_chunk == Application.get_env(:zen_monitor, :connector_chunk_size)
    end

    test "remote environment configured correctly", ctx do
      assert @slow_interval ==
               :rpc.call(ctx.compatible, Application, :get_env, [
                 :zen_monitor,
                 :batcher_sweep_interval
               ])

      assert @small_chunk ==
               :rpc.call(ctx.compatible, Application, :get_env, [
                 :zen_monitor,
                 :batcher_chunk_size
               ])
    end

    test "down messages are throttled", ctx do
      # Start a lot of remote processes
      remote_pids = start_processes(ctx.compatible, 100_000)

      # Monitor everything
      assert :ok = Enum.each(remote_pids, &ZenMonitor.monitor/1)

      # Make sure the connector flushes the monitors over to the remote
      connector = Connector.get(ctx.compatible)

      assert Helper.wait_until(fn ->
               :sys.get_state(connector).length == 0
             end)

      # Assert that the message queue is empty
      assert {:message_queue_len, 0} = Process.info(self(), :message_queue_len)

      # Choose some processes to kill
      targets =
        remote_pids
        |> Enum.shuffle()
        |> Enum.slice(0, 10_000)

      # Start stopping all the targets
      stop_processes(targets)

      # Wait for 10 intervals
      Process.sleep(@slow_interval * 10)

      # Get the message queue
      messages = flush_messages()

      # Check that we got an appropriate amount of messages
      flush_length = length(messages)
      assert @small_chunk * 5 <= flush_length
      assert flush_length <= @small_chunk * 15

      # Check each message is a :DOWN for a stopped process
      for message <- messages do
        assert {:DOWN, _, :process, received_pid, {:zen_monitor, _}} = message
        assert received_pid in targets
      end
    end

    test "does not crash ZenMonitor", ctx do
      # Save the current ZenMonitor pids
      connector = Connector.get(ctx.compatible)
      local = Process.whereis(ZenMonitor.Local)
      proxy = :rpc.call(ctx.compatible, Process, :whereis, [ZenMonitor.Proxy])
      batcher = :rpc.call(ctx.compatible, ZenMonitor.Proxy.Batcher, :get, [connector])

      # Start a lot of remote processes
      remote_pids = start_processes(ctx.compatible, 100_000)

      # Monitor everything
      assert :ok = Enum.each(remote_pids, &ZenMonitor.monitor/1)

      # Make sure the connector flushes the monitors over to the remote
      assert Helper.wait_until(fn ->
               :sys.get_state(connector).length == 0
             end)

      # Kill all remote processes
      stopper = stop_processes(remote_pids)

      # Wait for the stopper to finish its job
      assert Helper.wait_until(fn ->
               not Process.alive?(stopper)
             end)

      # Make sure that nothing crashed
      assert Process.alive?(local)
      assert Process.alive?(connector)
      assert :rpc.call(ctx.compatible, Process, :alive, [proxy])
      assert :rpc.call(ctx.compatible, Process, :alive, [batcher])
    end
  end
end
