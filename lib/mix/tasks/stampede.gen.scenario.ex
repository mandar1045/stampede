defmodule Mix.Tasks.Stampede.Gen.Scenario do
  @shortdoc "Generates a load test scenario"

  @moduledoc """
  Generates a scenario to start a load test from.

      $ mix stampede.gen.scenario Home
      $ mix stampede.gen.scenario Lobby --channels
      $ mix stampede.gen.scenario Checkout --live --url http://localhost:4000/cart

  Writes `loadtest/home.exs`, with a module named after your application,
  such as `MyApp.Load.Home`. Run it with `mix stampede.run loadtest/home.exs`.

  By default, the scenario requests a page over HTTP, which works against any
  Phoenix app as it is. The other kinds need a few changes to match your
  application, pointed out in the generated file.

  ## Options

    * `--http` - requests a page with `Stampede.HTTP`, the default
    * `--channels` - joins a channel and pushes to it with `Stampede.Channels`
    * `--live` - opens a LiveView with `Stampede.LiveView`
    * `--websocket` - talks to a plain WebSocket with `Stampede.WebSocket`
    * `--url` - the URL to start from, `http://localhost:4000/` by default,
      or the socket's URL for `--channels` and `--websocket`
    * `--rate` - starts iterations at a fixed rate, instead of keeping a
      number of VUs busy
    * `--force` - overwrites the file without asking
  """

  use Mix.Task

  @switches [
    http: :boolean,
    channels: :boolean,
    live: :boolean,
    websocket: :boolean,
    url: :string,
    rate: :boolean,
    force: :boolean
  ]

  @kinds [:http, :channels, :live, :websocket]

  @default_urls %{
    http: "http://localhost:4000/",
    channels: "ws://localhost:4000/socket",
    live: "http://localhost:4000/",
    websocket: "ws://localhost:4000/ws"
  }

  @impl true
  def run(args) do
    {opts, names} = OptionParser.parse!(args, strict: @switches)

    name =
      case names do
        [name] ->
          name

        _other ->
          Mix.raise("Expected a scenario name, such as: mix stampede.gen.scenario Home")
      end

    if not (name =~ ~r/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*$/) do
      Mix.raise("Expected the scenario name to be a module name, such as Home, got: #{name}")
    end

    kind =
      case Enum.filter(@kinds, &opts[&1]) do
        [] -> :http
        [kind] -> kind
        _many -> Mix.raise("Expected only one of --http, --channels, --live and --websocket")
      end

    module = Enum.join([namespace(), Macro.camelize(name)], ".")
    path = Path.join("loadtest", Macro.underscore(name) <> ".exs")

    contents = scenario(kind, module, path, opts[:url], opts[:rate] == true)

    if Mix.Generator.create_file(path, contents, force: opts[:force]) do
      Mix.shell().info("\nRun it with:\n\n    $ mix stampede.run #{path}\n")
    end
  end

  defp namespace do
    case Mix.Project.config()[:app] do
      nil -> "Load"
      app -> Macro.camelize(Atom.to_string(app)) <> ".Load"
    end
  end

  # Shared with mix stampede.install.
  @doc false
  def scenario(kind, module, path, url \\ nil, rate? \\ false) do
    url = url || @default_urls[kind]

    """
    defmodule #{module} do
      use Stampede.Scenario

    #{load(rate?, path)}
      @impl true
      def options do
        [
    #{load_options(rate?)}
          thresholds: [{#{inspect(metric(kind))}, p95: 500}, {"iteration.errors", count: 0}]
        ]
      end

      @impl true
    #{run(kind, url)}end
    """
  end

  defp load(false, path) do
    """
      # Ramps up to 50 VUs over 30 seconds, holds them for a minute and ramps
      # down. Run it with:
      #
      #     $ mix stampede.run #{path}
      #\
    """
  end

  defp load(true, path) do
    """
      # Starts 20 iterations a second for a minute, however long each one
      # takes, with up to 200 in progress at once. Run it with:
      #
      #     $ mix stampede.run #{path}
      #\
    """
  end

  defp load_options(false) do
    """
          stages: [{[second: 30], 50}, {[minute: 1], 50}, {[second: 10], 0}],\
    """
  end

  defp load_options(true) do
    """
          rate: 20,
          duration: [minute: 1],
          max_vus: 200,\
    """
  end

  defp metric(:http), do: "http.request"
  defp metric(:channels), do: "channel.join"
  defp metric(:live), do: "live.join"
  defp metric(:websocket), do: "ws.connect"

  defp run(:http, url) do
    """
      def run(_vu) do
        {:ok, response} = Stampede.HTTP.get(#{inspect(url)})
        Stampede.check("status is 200", response.status == 200)

        # Waits a second before the next page, as a person would.
        Process.sleep(1_000)
      end
    """
  end

  defp run(:channels, url) do
    """
      def run(vu) do
        {:ok, socket} = Stampede.Channels.connect(#{inspect(url)})

        # Change the topic and the event to ones your channel handles.
        {:ok, _reply} = Stampede.Channels.join(socket, "room:lobby")

        for _ <- 1..10 do
          {:ok, _reply} = Stampede.Channels.push(socket, "room:lobby", "ping", %{from: vu.id})
          Process.sleep(1_000)
        end
      end
    """
  end

  defp run(:live, url) do
    """
      def run(_vu) do
        {:ok, view} = Stampede.LiveView.connect(#{inspect(url)})

        # Send the events your LiveView handles with click/4, change/4 and
        # submit/4, for example:
        #
        #     {:ok, _reply} = Stampede.LiveView.click(view, "like", %{"id" => "1"})

        # Stays on the page for a while, as a reader would, then leaves.
        Process.sleep(5_000)
        :ok = Stampede.LiveView.close(view)
      end
    """
  end

  defp run(:websocket, url) do
    """
      def run(vu) do
        {:ok, ws} = Stampede.WebSocket.connect(#{inspect(url)})

        # Send what your server expects, and wait for its answer.
        :ok = Stampede.WebSocket.send(ws, JSON.encode!(%{hello: vu.id}))
        {:ok, _frame} = Stampede.WebSocket.await(ws)

        Process.sleep(1_000)
      end
    """
  end
end
