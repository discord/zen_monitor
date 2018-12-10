defmodule ZenMonitor.Test.Support.ObservableGen do
  @moduledoc """
  ObservableGen is a test spy that can observe all calls to call/3 and cast/2 and forward them to
  a spy process with an {:observe, :call | :cast, *args}

  It is used in ZenMonitor tests to verify that the proper communication is happening between
  various components.
  """
  use Agent

  def start_link(spy) do
    Agent.start_link(fn -> spy end, name: __MODULE__)
  end

  def call(destination, message, timeout \\ 5000) do
    Agent.get(__MODULE__, fn spy ->
      send(spy, {:observe, :call, destination, message, timeout})
    end)

    GenServer.call(destination, message, timeout)
  end

  def cast(destination, message) do
    Agent.get(__MODULE__, fn spy ->
      send(spy, {:observe, :cast, destination, message})
    end)

    GenServer.cast(destination, message)
  end
end
