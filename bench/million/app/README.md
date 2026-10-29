# The app under test

A fresh `mix phx.new` app (Phoenix 1.8, LiveView 1.2, Bandit), with only
what the benchmark needs added:

  * `MillionWeb.RoomChannel` at `/socket`, for `room:*` topics. It accepts
    every join and replies to `"ping"` with what it was sent.
  * `MillionWeb.CounterLive` at `/counter`, a page with a counter and a
    button.

Config changes from the generated app, all in `config/`:

  * No `force_ssl`, since the benchmark talks plain HTTP on a private network.
  * Bandit takes up to 65,536 connections per acceptor instead of 16,384, and
    has a listen backlog of 65,535.
  * `LOG_LEVEL` sets the log level in production.

Run it in production mode with:

```console
$ MIX_ENV=prod mix deps.get && MIX_ENV=prod mix compile
$ MIX_ENV=prod PHX_SERVER=true PORT=4000 PHX_HOST=<its address> \
    SECRET_KEY_BASE=$(mix phx.gen.secret) mix phx.server
```
