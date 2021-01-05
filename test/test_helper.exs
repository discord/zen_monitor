defmodule Helper do
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
