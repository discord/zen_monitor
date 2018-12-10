defmodule ZenMonitor.Local.Test do
  @moduledoc """
  Tests the ZenMonitor.Local module.

  Since the bulk of monitor/1 and compatibility/1 are delegated to ZenMonitor.Local.Connector, see
  the ZenMonitor.Local.Connector.Test module for tests concerning that functionality.

  Most of the other functionality of this module is internal and handled by the
  ZenMonitor.BlackBox.Test
  """
  use ExUnit.Case

  alias ZenMonitor.Local
  alias ZenMonitor.Local.Tables

  setup do
    start_supervised(ZenMonitor.Supervisor)
    :ok
  end

  def pids(count) do
    Enum.map(1..count, fn _ -> spawn(fn -> Process.sleep(:infinity) end) end)
  end

  describe "Demonitoring a reference" do
    test "demonitored references are consumed from the references table" do
      [pid] = pids(1)
      ref = Local.monitor(pid)

      assert :ets.member(Tables.references(), {self(), ref})

      assert true = Local.demonitor(ref)

      refute :ets.member(Tables.references(), {self(), ref})
    end

    test "demonitor without flush does not clear already delivered :DOWN message" do
      ref = make_ref()

      # Simulate receiving a :DOWN message about the reference
      send(self(), {:DOWN, ref, :process, :pid, :reason})

      assert true = Local.demonitor(ref)

      assert_received {:DOWN, ^ref, _, _, _}
    end

    test "demonitor with flush will clear already delivered :DOWN message" do
      ref = make_ref()

      # Simulate receiving a :DOWN message about the reference
      send(self(), {:DOWN, ref, :process, :pid, :reason})

      assert true = Local.demonitor(ref, [:flush])

      refute_received {:DOWN, ^ref, _, _, _}
    end
  end

  describe "Handles subscriber down" do
    test "cleans up references" do
      me = self()

      # Spawn a new subscriber process, have it send us some information and sleep
      subscriber =
        spawn(fn ->
          [pid] = pids(1)
          ref = Local.monitor(pid)

          send(me, {:monitor, ref})

          Process.sleep(:infinity)
        end)

      assert_receive {:monitor, ref}

      # Assert that the reference was recorded
      assert :ets.member(Tables.references(), {subscriber, ref})

      # Kill the subscriber
      Process.exit(subscriber, :kill)

      # Assert that the reference was cleaned up
      assert Helper.wait_until(fn ->
               not :ets.member(Tables.references(), {subscriber, ref})
             end)
    end
  end
end
