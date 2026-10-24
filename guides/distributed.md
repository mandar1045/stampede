# Spreading the load over machines

A single machine running a load test runs out of something long before a
large Phoenix app does: CPU, file descriptors or ports. Stampede can spread
one test over several machines with Erlang distribution, and merge what they
measured into one result.

## When one machine isn't enough

When the machine running the load test is overloaded, every timing goes up
at once, while the server under test still has CPU to spare. Those timings
measure the load test, not the server. Watch the load test's CPU while it
runs, with `top` or similar. As a rule of thumb, spread the load once it
stays above about 70%.

Before adding machines, check the limits of the one you have:

  * **File descriptors.** Every connection needs one, and many systems allow
    1,024 per process. Raise the limit in the shell that starts the test,
    such as with `ulimit -n 100000`.
  * **Ports.** Every connection to the same server address uses a local port,
    and Linux hands out about 28,000 of them by default. The range is in
    `/proc/sys/net/ipv4/ip_local_port_range`. Past that, connections fail
    with `:eaddrnotavail`.
  * **BEAM ports.** The Erlang VM allows 65,536 sockets and files at once by
    default. Raise it with `elixir --erl "+Q 200000" -S mix stampede.run ...`.

## Starting the nodes

Every machine runs the same project, compiled the same way, with the same
Elixir and Erlang versions. On each machine that should run VUs, start a
node with a name and a shared secret cookie:

```console
$ iex --name worker@10.0.0.2 --cookie load-test-secret -S mix
```

Then run the test from one more machine, naming the others:

```console
$ elixir --name loader@10.0.0.1 --cookie load-test-secret -S mix stampede.run loadtest/lobby.exs \
    --nodes worker@10.0.0.2,worker@10.0.0.3
```

`--name` with the machine's address works across machines, while `--sname`
only works when the machines can resolve each other's host names.

From code, connect the nodes first and pass them to `Stampede.run/2`:

```elixir
true = Node.connect(:"worker@10.0.0.2")
Stampede.run(MyApp.Load.Lobby, nodes: [node() | Node.list()])
```

## How the load is split

  * VUs and rates are split evenly between the nodes, the one running the
    test included. With `--vus 3000` and three nodes, each runs 1,000 VUs.
  * `c:Stampede.Scenario.setup/1` runs once, on the node running the test,
    and what it returns is sent to every node.
  * Scenarios defined in the file given to `mix stampede.run` are loaded on
    every node. Modules they use from your project must be compiled there
    already, which is why every node runs the same project.
  * Every node sends what it measured each second, and the results add up as
    if a single machine ran the whole test. Percentiles stay within 1% of
    the exact value.

## Networks and security

Nodes find each other through `epmd` on port 4369, then talk on a port the
VM picks at random. Behind a firewall, fix the range of those ports and open
it along with 4369:

```console
$ iex --name worker@10.0.0.2 --cookie load-test-secret \
    --erl "-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9110" -S mix
```

A node that knows the cookie can run any code on the others, so keep the
nodes on a private network, and use a cookie that is long and random.
