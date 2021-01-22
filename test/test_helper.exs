defmodule Helper do
  alias ZenMonitor.{Local, Proxy}
  import ExUnit.Assertions

  def await_monitors_established(subscriber \\ nil, refs, target) do
    subscriber = subscriber || self()
    Enum.each(refs, &await_monitor_established(subscriber, &1, target))
  end

  def await_monitor_established(subscriber \\ nil, ref, target) do
    subscriber = subscriber || self()

    assert wait_until(fn ->
             local_monitor_established?(subscriber, ref, target)
           end),
           "Local Monitor #{inspect(ref)}: #{inspect(subscriber)} -> #{inspect(target)} did not get established"

    assert wait_until(fn ->
             proxy_monitor_established?(target)
           end),
           "Proxy Monitor #{inspect(ref)}: #{inspect(subscriber)} -> #{inspect(target)} did not get established"
  end

  def await_monitors_cleared(subscriber \\ nil, refs, target) do
    subscriber = subscriber || self()
    Enum.each(refs, &await_monitor_cleared(subscriber, &1, target))
  end

  def await_monitor_cleared(subscriber \\ nil, ref, target) do
    subscriber = subscriber || self()

    assert wait_until(fn ->
             !local_monitor_established?(subscriber, ref, target)
           end),
           "Local Monitor #{inspect(ref)}: #{inspect(subscriber)} -> #{inspect(target)} did not get cleared"
  end

  def local_monitor_established?(subscriber \\ nil, ref, target) do
    subscriber = subscriber || self()

    monitors = Local.Connector.monitors(target, subscriber)

    ref in monitors
  end

  def proxy_monitor_established?(target) do
    subscriber = Local.Connector.get(target)
    target_node = node(target)
    table = Proxy.Tables.subscribers()

    row =
      if target_node == Node.self() do
        :ets.lookup(table, {target, subscriber})
      else
        args = [table, {target, subscriber}]
        :rpc.call(target_node, :ets, :lookup, args)
      end

    !Enum.empty?(row)
  end

  @doc """
  Helper that executes a function until it returns true

  Useful for operations that will eventually complete, instead of sleeping to allow an async
  operation to complete, wait_until will call the function in a loop up to the specified number of
  attempts with the specified delay between attempts.
  """
  @spec wait_until(fun :: (() -> boolean), attempts :: non_neg_integer, delay :: pos_integer) ::
          boolean
  def wait_until(fun, attempts \\ 50, delay \\ 100)

  def wait_until(_, 0, _), do: false

  def wait_until(fun, attempts, delay) do
    try do
      case fun.() do
        true ->
          true

        _ ->
          Process.sleep(delay)
          wait_until(fun, attempts - 1, delay)
      end
    rescue
      MatchError ->
        Process.sleep(delay)
        wait_until(fun, attempts - 1, delay)
    end
  end
end

Application.ensure_all_started(:instruments)

ExUnit.start()
