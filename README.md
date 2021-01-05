# ZenMonitor

[![CI](https://github.com/discord/zen_monitor/workflows/CI/badge.svg)](https://github.com/discord/zen_monitor/actions)
[![Hex.pm Version](http://img.shields.io/hexpm/v/zen_monitor.svg?style=flat)](https://hex.pm/packages/zen_monitor)
[![Hex.pm License](http://img.shields.io/hexpm/l/zen_monitor.svg?style=flat)](https://hex.pm/packages/zen_monitor)
[![HexDocs](https://img.shields.io/badge/HexDocs-Yes-blue)](https://hexdocs.pm/zen_monitor)

ZenMonitor allows for the efficient monitoring of remote processes with minimal use of ERTS
Distribution.

## Installation

Add `ZenMonitor` to your dependencies

```elixir
def deps do
  [
    {:zen_monitor, "~> 1.0.0"}
  ]
end
```

## Using ZenMonitor

ZenMonitor strives to be a drop-in replacement for `Process.monitor/1`.  To those ends, the
programming interface and all the complexities of how it carries out its task are simplified by a
simple unified programming interface.  All the functions that the caller needs to use have
convenient delegates available in the top-level `ZenMonitor` module.  The interface is detailed
below.

### ZenMonitor.monitor/1

This is a drop-in replacement for `Process.monitor/1` when it comes to processes.  It is
compatible with the various ways that `Process.monitor/1` can establish monitors and will accept
one of a `pid`, a `name` which is the `atom` that a local process is registered under, or a tuple
of `{name, node}` for a registered process on a remote node.  These are defined as the
`ZenMonitor.destination` type.

`ZenMonitor.monitor/1` returns a standard reference that can be used to `demonitor` and can be
matched against the reference provided in the `:DOWN` message.

Similar to `Process.monitor/1`, the caller is allowed to monitor the same process multiple times,
each monitor will be provided with a unique reference and all monitors will fire `:DOWN` messages
when the monitored process goes down.  Even though the caller can establish multiple monitors,
ZenMonitor is designed to handle this efficiently, the only cost is an additional ETS row on the
local node and additional processing time at fan-out.

### ZenMonitor.demonitor/2

This is a mostly drop-in replacement for `Process.demonitor/2` when it comes to processes.  The
first argument is the reference returned by `ZenMonitor.monitor/1`.  It accepts a list of option
atoms, but only honors the `:flush` option at this time.  Passing the `:info` option is allowed
but has no effect, this function always returns `true`.

### ZenMonitor.compatibility/1

When operating in a mixed environment where some nodes are ZenMonitor compatible and some are not,
it may be necessary to check the compatibility of a remote node.  `ZenMonitor.compatibility/1`
accepts any `ZenMonitor.destination` and will report back one of `:compatible` or `:incompatible`
for the remote's cached compatibility status.

All remotes start off as `:incompatible` until a positively acknowledged connection is
established.  See the `ZenMonitor.connect/1` function for more information on connecting nodes.

### ZenMonitor.compatibility_for_node/1

Performs the same operation as `ZenMonitor.compatibility/1` but it accepts a node atom instead of
a `ZenMonitor.destination`.

### ZenMonitor.connect/1

Attempts a positive connection with the provided remote node.  Connections are established by
using the `@gen_module`'s `call/4` method to send a `:ping` message to the process registered
under the atom `ZenMonitor.Proxy` on the remote.  If this process responds with a `:pong` atom
then the connection is positively established and the node is marked as `:compatible`.  Any other
response or error condition (timeout / noproc / etc) will be considered negative acknowledgement.

`ZenMonitor.connect/1` is actually a delegate for `ZenMonitor.Local.Connector.connect/1` see the
documentation there for more information about how connect behaves.

### Handling Down Messages

Any `:DOWN` message receivers (most commonly `GenServer.handle_info/2` callbacks) that match on
the reason should be updated to include an outer `{:zen_monitor, original_match}` wrapper.

```elixir
def handle_info({:DOWN, ref, :process, pid, :specific_reason}, state) do
  ...
end
```

Should be updated to the following.

```elixir
def handle_info({:DOWN, ref, :process, pid, {:zen_monitor, :specific_reason}}, state) do
  ...
end
```

## Why?

`ZenMonitor` was developed at [Discord](https://discordapp.com) to improve the stability of our
real-time communications infrastructure.  `ZenMonitor` improves stability in a couple of
different ways.

### Traffic Calming

When a process is being monitored by a large number of remote processes, that process going down
can cause both the node hosting the downed process and the node hosting the monitoring processes
to be suddenly flooded with an large amount of work.   This is commonly referred to as a
thundering herd and can overwhelm either node depending on the situation.

ZenMonitor relies on interval batching and `GenStage` to help calm the deluge into a throttled
stream of `:DOWN` messages that may take more wall clock time to process but has more predictable
scheduler utilization and network consumption.

### Message Interspersing

In the inverse scenario, a single process monitoring a large number of remote processes, a
systemic failure of a large number of monitored processes can result in blocking the message
queue.  This can cause other messages being sent to the process to backup behind the `:DOWN`
messages.

Here's what a message queue might look like if 100,000 monitors fired due to node failure.

```
+------------------------------------------------+
|    {:DOWN, ref, :process, pid_1, :nodedown}    |
+------------------------------------------------+
|    {:DOWN, ref, :process, pid_2, :nodedown}    |
+------------------------------------------------+
...             snip 99,996 messages           ...
+------------------------------------------------+
| {:DOWN, ref, :process, pid_99_999, :nodedown}  |
+------------------------------------------------+
| {:DOWN, ref, :process, pid_100_000, :nodedown} |
+------------------------------------------------+
|                     :work                      |
+------------------------------------------------+
|                     :work                      |
+------------------------------------------------+
|                     :work                      |
+------------------------------------------------+
...                    etc                     ...
```

The process has to process the 100,000 `:DOWN` messages before it can get back to doing work, if
the processing of a `:DOWN` message is non-trivial then this could result in the process
effectively appearing unresponsive to callers expecting it to do `:work`.

`ZenMonitor.Local.Dispatcher` provides a configurable batch sweeping system that dispatches a
fixed demand_amount of `:DOWN` messages every demand_interval (See the documentation for
`ZenMonitor.Local.Dispatcher` for configuration and defaults).  Using `ZenMonitor` the message
queue would look like this.

```
+------------------------------------------------+
|    {:DOWN, ref, :process, pid_1, :nodedown}    |
+------------------------------------------------+
...             snip 4,998 messages           ...
+------------------------------------------------+
|  {:DOWN, ref, :process, pid_5000, :nodedown}   |
+------------------------------------------------+
|                     :work                      |
+------------------------------------------------+
...    snip messages during demand_interval    ...
+------------------------------------------------+
|                     :work                      |
+------------------------------------------------+
|  {:DOWN, ref, :process, pid_5001, :nodedown}   |
+------------------------------------------------+
...             snip 4,998 messages           ...
+------------------------------------------------+
| {:DOWN, ref, :process, pid_10_000, :nodedown}  |
+------------------------------------------------+
|                     :work                      |
+------------------------------------------------+
...    snip messages during demand_interval    ...
+------------------------------------------------+
|                     :work                      |
+------------------------------------------------+
...                    etc                     ...
```

This means that the process can continue processing work messages while working through more
manageable batches of `:DOWN` messages, this improves the effective responsiveness of the process.

### Message Truncation

`:DOWN` messages include a `reason` field that can include large stack traces and GenServer state
dumps.  Large `reason`s generally don't pose an issue, but in a scenario where thousands of
processes are monitoring a process that generates a large `reason` the cumulative effect of
duplicating the large `reason` to each monitoring process can consume all available memory on a
node.

When a `:DOWN` message is received for dispatch to remote subscribers, the first step is to
truncate the message using `ZenMonitor.Truncator`, see the module documentation for more
information about how truncation is performed and what configuration options are supported.

This prevents the scenario where a single process with a large stack trace or large state gets
amplified on the receiving node and consumes an large amount of memory.

## Design

ZenMonitor is constructed of two cooperating systems, the _Local ZenMonitor System_ and the
_Proxy ZenMonitor System_.  When a process wishes to monitor a remote process, it should inform
the _Local ZenMonitor System_ which will efficiently dispatch the monitoring request to the remote
node's _Proxy ZenMonitor System_.

### Local ZenMonitor System

The _Local ZenMonitor System_ is composed of a few processes, these are managed by the
ZenMonitor.Local.Supervisor.  The processes that comprise the _Local ZenMonitor System_ are
described in detail in the following section.

#### ZenMonitor.Local

ZenMonitor.Local is responsible for accepting monitoring and demonitoring requests from local
processes.  It will send these requests to the Connector processes for efficient transmission
to the responsible ZenMonitor.Proxy processes.

When a monitored process dies, the ZenMonitor.Proxy will send this information in a summary
message to the ZenMonitor.Local.Connector process which will use the send down_dispatches to
ZenMonitor.Local for eventual delivery by the ZenMonitor.Local.Dispatcher.

ZenMonitor.Local is also responsible for monitoring the local interested process and performing
clean-up if the local interested process crashes for any reason, this prevents the Local
ZenMonitor System from leaking memory.

#### ZenMonitor.Local.Tables

This is a simple process that is responsible for owning shared ETS tables used by various parts of
the Local ZenMonitor System.

It maintains two tables, `ZenMonitor.Local.Tables.Nodes` and  `ZenMonitor.Local.Tables.References`
these tables are public and are normally written to and read from by the ZenMonitor.Local and
ZenMonitor.Local.Connector processes.

#### ZenMonitor.Local.Connector

ZenMonitor.Local.Connector is responsible for batching monitoring requests into summary requests
for the remote ZenMonitor.Proxy.  The Connector handles the actual distribution connection to the
remote ZenMonitor.Proxy including dealing with incompatible and down nodes.

When processes go down on the remote node, the Proxy ZenMonitor System will report summaries of
these down processes to the corresponding ZenMonitor.Local.Connector.

There will be one ZenMonitor.Local.Connector per remote node with monitored processes.

#### ZenMonitor.Local.Dispatcher

When a remote node or remote processes fail, messages will be enqueued for delivery.  The
ZenMonitor.Local.Dispatcher is responsible for processing these enqueued messages at a steady and
controlled rate.

### Proxy ZenMonitor System

The _Proxy ZenMonitor System_ is composed of a few processes, these are managed by the
`ZenMonitor.Proxy.Supervisor`.  The processes that comprise the _Proxy ZenMonitor System_ are
described in detail in the following section.

#### ZenMonitor.Proxy

`ZenMonitor.Proxy` is responsible for handling subscription requests from the
_Local ZenMonitor System_ and for maintaining the ERTS Process Monitors on the processes local to
the remote node.

`ZenMonitor.Proxy` is designed to be efficient with local monitors and will guarantee that for any
local process there is, at most, one ERTS monitor no matter the number remote processes and remote
nodes are interested in monitoring that process.

When a local process goes down `ZenMonitor.Proxy` will enqueue a new death certificate to the
`ZenMonitor.Proxy.Batcher` processes that correspond to the interested remotes.

#### ZenMonitor.Proxy.Tables

This is a simple process that is responsible for owning shared ETS tables used by various parts of
the _Proxy ZenMonitor System_.

It maintains a single table, `ZenMonitor.Proxy.Tables.Subscribers`.  This table is used by both
the `ZenMonitor.Proxy` and `ZenMonitor.Proxy.Batcher` processes.


#### ZenMonitor.Proxy.Batcher

This process has two primary responsibilities, collecting and summarizing death certificates and
monitoring the remote process.

For every remote `ZenMonitor.Local.Connector` that is interested in monitoring processes on this
node, a corresponding `ZenMonitor.Proxy.Batcher` is spawned that will collect and ultimately
deliver death certificates.  The `ZenMonitor.Proxy.Batcher` will also monitor the remote
`ZenMonitor.Local.Connector` and clean up after it if it goes down for any reason.

## Running a Compatible Node

ZenMonitor ships with an Application, `ZenMonitor.Application` which will start the overall
supervisor, `ZenMonitor.Supervisor`.  This creates a supervision tree as outlined below.

```
                                                                            -------------------------
                                                                      +----| ZenMonitor.Local.Tables |
                                                                      |     -------------------------
                                                                      |
                                                                      |     ------------------
                                                                      +----| ZenMontior.Local |
                                    -----------------------------     |     ------------------
                              +----| ZenMonitor.Local.Supervisor |----|
                              |     -----------------------------     |     -------------       ----------------------------
                              |                                       +----| GenRegistry |--N--| ZenMonitor.Local.Connector |
                              |                                       |     -------------       ----------------------------
                              |                                       |
                              |                                       |     -----------------------------
                              |                                       +----| ZenMonitor.Local.Dispatcher |
                              |                                             -----------------------------
  -----------------------     |
 | ZenMonitor.Supervisor |----|
  -----------------------     |                                             -------------------------
                              |                                       +----| ZenMonitor.Proxy.Tables |
                              |                                       |     -------------------------
                              |                                       |
                              |     -----------------------------     |     ------------------
                              +----| ZenMonitor.Proxy.Supervisor |----+----| ZenMonitor.Proxy |
                                    -----------------------------     |     ------------------
                                                                      |
                                                                      |     -------------       --------------------------
                                                                      +----| GenRegistry |--M--| ZenMonitor.Proxy.Batcher |
                                                                            -------------       --------------------------
```

