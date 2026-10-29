import Config

# No force_ssl: the benchmark talks plain HTTP inside a private network,
# the way an app behind a load balancer that ends TLS does.

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
