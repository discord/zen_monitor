defmodule ZenMonitor.Truncator do
  @moduledoc """
  ZenMonitor.Truncator is used to truncate error messages to prevent error expansion issues.

  ## Error Expansion

  At the core of ZenMonitor is a system that collects local `:DOWN` messages, batches them up and
  relays them in bulk.  This opens up a failure mode where each `:DOWN` message individually is
  deliverable, but the bulk summary grows to an unsupportable size due to the aggregation of large
  reason payloads.

  If no truncation is performed then the payload can cause instability on the sender or the
  receiver side.

  ## Truncation Behavior

  ZenMonitor will truncate error reasons if they exceed a certain size to prevent Error Expansion
  from breaking either the sender or the receiver.

  Truncation is performed recursively on the term up to a maximum depth which can be provided to
  the `ZenMonitor.Truncator.truncate/2` function.

  See below for an explanation of how the Truncator treats different values

  ### Pass-Through Values

  There are a number of types that the Truncator will pass through unmodified.

  - Atoms
  - Pids
  - Numbers
  - References
  - Ports
  - Binaries less than `@max_binary_size` (see the Binary section below for more information)

  ### Binaries

  There is a configurable value `@max_binary_size` any binary encountered over this size will be
  truncated to `@max_binary_size - 3` and a trailing '...' will be appended to indicate the value
  has been truncated.  This guarantees that no binary will appear in the term with size greater
  than `@max_binary_size`

  ### Tuples

  0-tuples through 4-tuples will be passed through with their interior terms recursively
  truncated.  If a tuple has more than 4 elements, it will be replaced with the `:truncated` atom.

  ### Lists

  Lists with 0 to 4 elements will be passed through with each element recursively truncated.  If a
  list has more than 4 elements, it will be replaced with the `:truncated` atom.

  ### Maps

  Maps with a `map_size/1` less than 5 will be passed through with each value recursively
  truncated.  If a map has a size of 5 or greater then it will be replaced with the `:truncated`
  atom.

  ### Structs

  Structs are converted into maps and then the map rules are applied, they are then converted back
  into structs.  The effect is that a Struct with 4 fields or fewer will be retained (with all
  values recursively truncated) while Structs with 5 or more fields will be replaced with the
  `:truncated` atom.

  ### Recursion Limit

  The Truncator will only descend up to the `depth` argument passed into
  `ZenMonitor.Truncator.truncate/2`, regardless of the value, if the recursion descends deeper
  than this value then the `:truncated` atom will be used in place of the original value.

  ## Configuration

  `ZenMonitor.Truncator` exposes two different configuration options, and allows for one call-site
  override.  The configuration options are evaluated at compile time, changing these values at
  run-time (through a facility like `Application.put_env/3`) will have no effect.

  Both configuration options reside under the `:zen_monitor` app key.

  `:max_binary_size` is size in bytes over which the Truncator will truncate the binary.  The
  largest binary returned by the Truncator is defined to be the max_binary_size + 3, this is
  because when the truncator Truncator a binary it will append `...` to indicate that truncation
  has occurred.

  `:truncation_depth` is the default depth that the Truncator will recursively descend into the
  term to be truncated.  This is the value used for `ZenMonitor.Truncator.truncate/2` if no second
  argument is provided, providing a call-site second argument will override this configuration.
  """

  @max_binary_size Application.get_env(:zen_monitor, :max_binary_size, 1024)
  @truncation_binary_size @max_binary_size - 3
  @truncation_depth Application.get_env(:zen_monitor, :truncation_depth, 3)

  @doc """
  Truncates a term to a given depth

  See the module documentation for more information about how truncation works.
  """
  @spec truncate(term, depth :: pos_integer()) :: term
  def truncate(term, depth \\ @truncation_depth) do
    do_truncate(term, 0, depth)
  end

  ## Private

  defp do_truncate({:shutdown, _} = shutdown, 0, _) do
    shutdown
  end

  defp do_truncate(_, current, max_depth) when current >= max_depth do
    :truncated
  end

  defp do_truncate(atom, _, _) when is_atom(atom), do: atom

  defp do_truncate(pid, _, _) when is_pid(pid), do: pid

  defp do_truncate(number, _, _) when is_number(number), do: number

  defp do_truncate(bin, _, _) when is_binary(bin) and byte_size(bin) <= @max_binary_size, do: bin

  defp do_truncate(<<first_chunk::binary-size(@truncation_binary_size), _rest::bits>>, _, _) do
    first_chunk <> "..."
  end

  defp do_truncate(ref, _, _) when is_reference(ref), do: ref

  defp do_truncate(port, _, _) when is_port(port), do: port

  # Tuples
  defp do_truncate({a, b, c, d}, current, max_depth) do
    next = current + 1

    {do_truncate(a, next, max_depth), do_truncate(b, next, max_depth),
     do_truncate(c, next, max_depth), do_truncate(d, next, max_depth)}
  end

  defp do_truncate({a, b, c}, current, max_depth) do
    next = current + 1

    {do_truncate(a, next, max_depth), do_truncate(b, next, max_depth),
     do_truncate(c, next, max_depth)}
  end

  defp do_truncate({a, b}, current, max_depth) do
    next = current + 1
    {do_truncate(a, next, max_depth), do_truncate(b, next, max_depth)}
  end

  defp do_truncate({a}, current, max_depth) do
    next = current + 1
    {do_truncate(a, next, max_depth)}
  end

  defp do_truncate({} = tuple, _, _) do
    tuple
  end

  # Lists
  defp do_truncate([_, _, _, _] = l, current, max_depth) do
    do_truncate_list(l, current, max_depth)
  end

  defp do_truncate([_, _, _] = l, current, max_depth) do
    do_truncate_list(l, current, max_depth)
  end

  defp do_truncate([_, _] = l, current, max_depth) do
    do_truncate_list(l, current, max_depth)
  end

  defp do_truncate([_] = l, current, max_depth) do
    do_truncate_list(l, current, max_depth)
  end

  defp do_truncate([], _, _) do
    []
  end

  # Maps / Structs
  defp do_truncate(%struct_module{} = struct, current, max_depth) do
    truncated_value =
      struct
      |> Map.from_struct()
      |> do_truncate(current, max_depth)

    if is_map(truncated_value) and function_exported?(struct_module, :__struct__, 0) do
      struct(struct_module, truncated_value)
    else
      truncated_value
    end
  end

  defp do_truncate(%{} = m, current, max_depth) when map_size(m) < 5 do
    for {k, v} <- m, into: %{} do
      {k, do_truncate(v, current + 1, max_depth)}
    end
  end

  # Catch all
  defp do_truncate(_, _, _) do
    :truncated
  end

  defp do_truncate_list(l, current, max_depth) do
    Enum.map(l, &do_truncate(&1, current + 1, max_depth))
  end
end
