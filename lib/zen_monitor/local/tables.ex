defmodule ZenMonitor.Local.Tables do
  @moduledoc """
  `ZenMonitor.Local.Tables` owns tables that are shared between multiple `ZenMonitor.Local`
  components.

  See `nodes/0` and `references/0` for more information.
  """
  use GenServer

  @node_table Module.concat(__MODULE__, "Nodes")
  @reference_table Module.concat(__MODULE__, "References")

  ## Client

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Nodes holds cached information about remote node compatibility

  This information is stored in one of the following structures:

  For compatible nodes
  { remote_node, :compatible }
    ^---key---^  ^--value--^

  For incompatible nodes
  { remote_node, {:incompatible, enforce_until, attempts} }
    ^---key---^  ^---------------value-----------------^

  `enforce_until` is the time (as reported by System.monotonic_time(:milliseconds)) after which
  this cache entry should no longer be enforced.

  `attempts` is the number of consecutive connect attempts that have failed, this value is useful
  for calculating geometric backoff values
  """
  @spec nodes() :: :ets.tid()
  def nodes do
    @node_table
  end

  @doc """
  References holds the set of authoritative monitor references

  These references are stored in this structure:

  { {subscriber_pid, monitor_reference}, {remote_node, remote_pid} }
    ^-------------key-----------------^  ^----------value--------^

  There is a compound key of {subscriber_pid, monitor_reference} this allows for lookup of a given
  reference (if the subscriber is known, by convention it will be the calling process, self()) or
  the retrieval of all active monitors for a subscriber.
  """
  @spec references() :: :ets.tid()
  def references do
    @reference_table
  end

  ## Server

  def init(_opts) do
    @node_table = :ets.new(@node_table, [:public, :named_table, :set, write_concurrency: true])

    @reference_table =
      :ets.new(@reference_table, [:public, :named_table, :ordered_set, write_concurrency: true])

    {:ok, nil}
  end
end
