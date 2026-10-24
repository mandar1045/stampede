# GraphQL subscriptions with Absinthe

Absinthe runs GraphQL over Phoenix Channels. A client joins the
`__absinthe__:control` topic, sends each GraphQL document as a `"doc"` event,
and gets the results of each subscription on a topic of its own.
`Stampede.Channels` speaks that directly, with no GraphQL client needed.

The examples below use a schema where a mutation posts a message to a room,
and a subscription delivers it to everyone in that room:

```elixir
mutation do
  field :post_message, :message do
    arg :room, non_null(:string)
    arg :body, non_null(:string)
    resolve &Chat.post_message/2
  end
end

subscription do
  field :message_posted, :message do
    arg :room, non_null(:string)
    config fn args, _ -> {:ok, topic: args.room} end
    trigger :post_message, topic: fn message -> message.room end
  end
end
```

## A chat under load

Each user subscribes to a room, then posts messages to it and times how long
each one takes to come back through the subscription:

```elixir
defmodule MyApp.Load.Chat do
  use Stampede.Scenario

  @control "__absinthe__:control"

  @subscription """
  subscription($room: String!) {
    messagePosted(room: $room) { id body }
  }
  """

  @mutation """
  mutation($room: String!, $body: String!) {
    postMessage(room: $room, body: $body) { id }
  }
  """

  @impl true
  def options do
    [
      stages: [{[second: 30], 200}, {[minute: 1], 200}, {[second: 10], 0}],
      thresholds: [{"graphql.roundtrip", p95: 250}, {"iteration.errors", count: 0}]
    ]
  end

  @impl true
  def run(vu) do
    {:ok, socket} = Stampede.Channels.connect("ws://localhost:4000/socket")
    {:ok, _reply} = Stampede.Channels.join(socket, @control)

    {:ok, %{"subscriptionId" => subscription}} =
      Stampede.Channels.push(socket, @control, "doc", %{query: @subscription, variables: %{room: "lobby"}},
        metric: "graphql.subscribe"
      )

    for i <- 1..10 do
      body = "#{vu.id}-#{vu.iteration}-#{i}"

      Stampede.measure("graphql.roundtrip", fn ->
        {:ok, %{"data" => _data}} =
          Stampede.Channels.push(socket, @control, "doc", %{query: @mutation, variables: %{room: "lobby", body: body}},
            metric: "graphql.mutation"
          )

        {:ok, _result} =
          Stampede.Channels.await(socket, subscription, "subscription:data",
            match: &(&1["result"]["data"]["messagePosted"]["body"] == body)
          )
      end)

      Process.sleep(1_000)
    end
  end
end
```

> **Heads-up:** as of October 2026, Absinthe Phoenix 2.0.5 doesn't deliver
> subscription results on Phoenix 1.8.16
> ([absinthe_phoenix#113](https://github.com/absinthe-graphql/absinthe_phoenix/issues/113)).
> If every `await` for `"subscription:data"` times out, check those
> versions. I tested this guide on Phoenix 1.8.15.

`push/5` returns `{:ok, %{"data" => ...}}` for queries and mutations, and
`{:error, %{"errors" => [...]}}` when they fail. A subscription replies with
its `"subscriptionId"`, which is also the topic its results arrive on, as
`"subscription:data"` events.

## What to look at

  * `graphql.mutation` times each mutation, until its reply.
  * `graphql.roundtrip` adds the time until the subscription delivered the
    message. Every message goes to every user in the room, so it grows with
    the number of users.
  * `graphql.subscribe` times the subscription itself, which Absinthe has to
    parse and validate like any other document.
  * `channel.messages` counts every result delivered to every subscriber.
