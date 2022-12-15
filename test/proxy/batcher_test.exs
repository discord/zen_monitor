defmodule ZenMonitor.Proxy.Batcher.Test do
  @moduledoc """
  Tests for the ZenMonitor.Proxy.Batcher module

  ZenMonitor is a distributed system, in this suite the ZenMonitor.Proxy.Batcher that we will be
  exercising is running on the local node.  Since the ZenMonitor.Proxy system works off of
  subscriber pids we will make the test process the subscriber and forgo the need for ChildNodes.
  """
  use ExUnit.Case

  alias ZenMonitor.Proxy.{Batcher, Tables}

  # Batchers stop when their subscriber goes DOWN, this tag tells ExUnit to suppress stops reports
  @moduletag :capture_log

  setup do
    start_supervised(ZenMonitor.Supervisor)
    :ok
  end

  def disable_sweep(_) do
    # Set sweep interval to 1 minute (effectively disable for this describe block)
    original_sweep_interval = Batcher.sweep_interval()
    Batcher.sweep_interval(60_000)

    on_exit(fn ->
      Batcher.sweep_interval(original_sweep_interval)
    end)

    :ok
  end

  def reduce_chunk_size(_) do
    # Set chunk size to 2 for testing convenience
    original_chunk_size = Batcher.chunk_size()
    Batcher.chunk_size(2)

    on_exit(fn ->
      Batcher.chunk_size(original_chunk_size)
    end)

    :ok
  end

  describe "Getting a Batcher" do
    test "batcher for pid" do
      batcher = Batcher.get(self())
      assert Process.alive?(batcher)
    end

    test "multiple gets for the same pid should return the same batcher" do
      batcher_a = Batcher.get(self())
      batcher_b = Batcher.get(self())

      assert batcher_a == batcher_b
    end

    test "batcher is replaced if it dies" do
      original = Batcher.get(self())
      assert Process.alive?(original)

      Process.exit(original, :kill)
      refute Process.alive?(original)

      replacement = Batcher.get(self())

      # Give a chance for the GenRegistry to react to the above
      # death.
      replacement = if replacement != original do
        Process.sleep(50)
        Batcher.get(self())
      else
        replacement
      end

      assert Process.alive?(replacement)

      assert original != replacement
    end

    test "each pid gets its own batcher" do
      batcher_a = Batcher.get(self())
      batcher_b = Batcher.get(:other)

      assert batcher_a != batcher_b
    end
  end

  describe "Enqueuing Certificates" do
    setup [:disable_sweep]

    test "certificate gets added to the current batch" do
      batcher = Batcher.get(self())

      initial_state = :sys.get_state(batcher)
      assert initial_state.length == 0
      assert :queue.len(initial_state.batch) == 0

      Batcher.enqueue(batcher, :test_pid, :test_reason)

      updated_state = :sys.get_state(batcher)
      assert updated_state.length == 1
      assert :queue.len(updated_state.batch) == 1
      assert {:value, {:test_pid, :test_reason}} = :queue.peek(updated_state.batch)
    end
  end

  describe "Periodic Sweeps" do
    setup [:disable_sweep, :reduce_chunk_size]

    test "sweep should do nothing if the batch is empty" do
      batcher = Batcher.get(self())

      # Force a sweep
      send(batcher, :sweep)

      refute_receive _
    end

    test "sweep should deliver a summary to the subscriber" do
      batcher = Batcher.get(self())
      Batcher.enqueue(batcher, :test_pid, :test_reason)

      # Force a sweep
      send(batcher, :sweep)

      # Assert that we received the expected summary
      assert_receive {:dead, _, [{:test_pid, :test_reason}]}
    end

    test "sweep should deliver the summary in the same order it received them" do
      batcher = Batcher.get(self())

      # Enqueue a full chunk of unique certificates
      Batcher.enqueue(batcher, :test_pid_1, :test_reason_1)
      Batcher.enqueue(batcher, :test_pid_2, :test_reason_2)

      # Force a sweep
      send(batcher, :sweep)

      # Assert that we received the expected summary in the right order (1, 2)
      assert_receive {:dead, _, [{:test_pid_1, :test_reason_1}, {:test_pid_2, :test_reason_2}]}
    end

    test "sweep will only deliver the requested chunk size" do
      batcher = Batcher.get(self())

      # Enqueue two chunks worth of certificates
      Batcher.enqueue(batcher, :test_pid_1, :test_reason_1)
      Batcher.enqueue(batcher, :test_pid_2, :test_reason_2)
      Batcher.enqueue(batcher, :test_pid_3, :test_reason_3)
      Batcher.enqueue(batcher, :test_pid_4, :test_reason_4)

      # Force a sweep
      send(batcher, :sweep)

      # Assert that we received the first chunk in order (1, 2)
      assert_receive {:dead, _, [{:test_pid_1, :test_reason_1}, {:test_pid_2, :test_reason_2}]}

      # Force an additional sweep
      send(batcher, :sweep)

      # Assert that we received the second chunk in order (3, 4)
      assert_receive {:dead, _, [{:test_pid_3, :test_reason_3}, {:test_pid_4, :test_reason_4}]}
    end
  end

  describe "Handling Subscriber Down" do
    test "batcher cleans up subscriptions" do
      # Spawn a subscriber that we can kill later
      subscriber = spawn(fn -> Process.sleep(:infinity) end)

      # Start a batcher for the subscribers
      Batcher.get(subscriber)

      # Insert some subscriptions into the subscriber table
      :ets.insert(Tables.subscribers(), [
        {{:test_pid_a, subscriber}},
        {{:test_pid_b, subscriber}},
        {{:test_pid_a, :other_subscriber}},
        {{:test_pid_c, :other_subscriber}}
      ])

      # Kill the subscriber
      Process.exit(subscriber, :kill)

      # Assert that the subscribers table gets cleaned up
      assert Helper.wait_until(fn ->
               Tables.subscribers()
               |> :ets.tab2list()
               |> length() == 2
             end)

      # Assert that the rows that remain are the expected ones
      assert :ets.member(Tables.subscribers(), {:test_pid_a, :other_subscriber})
      assert :ets.member(Tables.subscribers(), {:test_pid_c, :other_subscriber})
    end
  end
end
