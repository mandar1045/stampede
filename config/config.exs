import Config

if config_env() == :test do
  config :logger, level: :warning

  config :phoenix, :json_library, JSON

  config :stampede, Stampede.TestEndpoint,
    adapter: Bandit.PhoenixAdapter,
    http: [ip: {127, 0, 0, 1}, port: 0],
    server: true,
    secret_key_base: String.duplicate("stampede", 8),
    live_view: [signing_salt: "stampede-live"],
    pubsub_server: Stampede.TestPubSub
end
