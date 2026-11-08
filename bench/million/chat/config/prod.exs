import Config

# No force_ssl: the benchmark talks plain HTTP inside a private network, with no
# proxy in front.
config :logger, level: :info
