defmodule ZenMonitor.Test.Support.Subscriber do
  def start(spy) do
    spawn(__MODULE__, :forward, [spy])
  end

  def forward(spy) do
    receive do
      message -> send(spy, {:forward, message})
    end

    forward(spy)
  end
end
