defmodule Stampede.TestPostgres do
  @moduledoc false

  # Connection options for the test database in STAMPEDE_TEST_POSTGRES.
  def opts do
    uri = URI.parse(System.fetch_env!("STAMPEDE_TEST_POSTGRES"))
    [username, password] = String.split(uri.userinfo || "postgres:postgres", ":", parts: 2)

    [
      hostname: uri.host,
      port: uri.port || 5432,
      username: username,
      password: password,
      database: String.trim_leading(uri.path || "/postgres", "/")
    ]
  end
end
