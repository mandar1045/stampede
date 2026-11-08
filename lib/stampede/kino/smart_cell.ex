if Code.ensure_loaded?(Kino.SmartCell) do
  defmodule Stampede.Kino.SmartCell do
    @moduledoc false

    # The "Load test" smart cell, described in Stampede.Kino. It writes a
    # scenario from a few fields, and runs it with Stampede.Kino.run/2.

    use Kino.JS
    use Kino.JS.Live
    use Kino.SmartCell, name: "Load test"

    @kinds ~w(http live channels llm)

    @urls %{
      "http" => "http://localhost:4000/",
      "live" => "http://localhost:4000/",
      "channels" => "ws://localhost:4000/socket",
      "llm" => "http://localhost:11434/v1"
    }

    @metrics %{
      "http" => "http.request",
      "live" => "live.join",
      "channels" => "channel.join",
      "llm" => "llm.ttft"
    }

    @defaults %{
      "name" => "LoadTest",
      "kind" => "http",
      "url" => @urls["http"],
      "topic" => "room:lobby",
      "event" => "ping",
      "model" => "qwen2.5:0.5b",
      "vus" => 10,
      "ramp" => 10,
      "hold" => 30,
      "pause" => 1,
      "p95" => 500,
      "probe" => "",
      "cookie" => ""
    }

    @numbers ~w(vus ramp hold pause p95)

    # Called when Stampede starts, so Livebook lists the cell.
    @doc false
    def register, do: Kino.SmartCell.register(__MODULE__)

    @impl true
    def init(attrs, ctx) do
      fields = Map.merge(@defaults, Map.take(attrs, Map.keys(@defaults)))
      {:ok, assign(ctx, fields: fields)}
    end

    @impl true
    def handle_connect(ctx), do: {:ok, ctx.assigns.fields, ctx}

    @impl true
    def handle_event("update", %{"field" => field, "value" => value}, ctx) do
      fields = put_field(ctx.assigns.fields, field, value)
      broadcast_event(ctx, "update", fields)
      {:noreply, assign(ctx, fields: fields)}
    end

    defp put_field(fields, "kind", kind) when kind in @kinds do
      %{fields | "kind" => kind, "url" => follow_url(fields["url"], fields["kind"], kind)}
    end

    defp put_field(fields, field, value) when field in @numbers do
      case Integer.parse(to_string(value)) do
        {number, ""} when number >= 0 -> %{fields | field => number}
        _invalid -> fields
      end
    end

    defp put_field(fields, field, value)
         when field in ~w(name url topic event model probe cookie) and is_binary(value) do
      %{fields | field => String.trim(value)}
    end

    defp put_field(fields, _field, _value), do: fields

    # A URL that's still the default changes to the new kind's default. Any
    # other keeps its host, with the scheme and path a socket or a page needs.
    defp follow_url(url, from, to) do
      uri = URI.parse(url)

      cond do
        url == @urls[from] ->
          @urls[to]

        from != "channels" and to == "channels" ->
          retarget(uri, %{"https" => "wss"}, "ws", "/socket")

        from == "channels" and to != "channels" ->
          retarget(uri, %{"wss" => "https"}, "http", "/")

        true ->
          url
      end
    end

    defp retarget(%URI{host: host} = uri, secure, scheme, path) when is_binary(host) do
      URI.to_string(%{uri | scheme: Map.get(secure, uri.scheme, scheme), path: path, query: nil})
    end

    defp retarget(uri, _secure, _scheme, _path), do: URI.to_string(uri)

    @impl true
    def to_attrs(ctx), do: ctx.assigns.fields

    @impl true
    def to_source(attrs) do
      fields = Map.merge(@defaults, attrs)
      name = if valid_name?(fields["name"]), do: fields["name"], else: @defaults["name"]

      """
      defmodule #{name} do
        use Stampede.Scenario

        @impl true
        #{run(fields)}
      end

      #{cookie(fields)}
      Stampede.Kino.run(#{name}, #{options(fields)})
      """
      |> Code.format_string!()
      |> IO.iodata_to_binary()
    end

    defp valid_name?(name), do: name =~ ~r/^[A-Z]\w*(\.[A-Z]\w*)*$/

    defp run(%{"kind" => "http"} = fields) do
      """
      def run(_vu) do
        {:ok, response} = Stampede.HTTP.get(#{inspect(fields["url"])})
        Stampede.check("status is 200", response.status == 200)
        #{pause(fields)}
      end
      """
    end

    defp run(%{"kind" => "live"} = fields) do
      """
      def run(_vu) do
        {:ok, view} = Stampede.LiveView.connect(#{inspect(fields["url"])})
        #{pause(fields)}
        :ok = Stampede.LiveView.close(view)
      end
      """
    end

    defp run(%{"kind" => "channels"} = fields) do
      topic = inspect(fields["topic"])

      """
      def run(vu) do
        {:ok, socket} = Stampede.Channels.connect(#{inspect(fields["url"])})
        {:ok, _reply} = Stampede.Channels.join(socket, #{topic})

        for _ <- 1..10 do
          {:ok, _reply} = Stampede.Channels.push(socket, #{topic}, #{inspect(fields["event"])}, %{from: vu.id})
          #{pause(fields)}
        end
      end
      """
    end

    defp run(%{"kind" => "llm"} = fields) do
      """
      def run(_vu) do
        {:ok, reply} =
          Stampede.LLM.chat(#{inspect(fields["url"])},
            model: #{inspect(fields["model"])},
            messages: [%{role: "user", content: "Why is the sky blue?"}],
            max_tokens: 100
          )

        Stampede.check("finished", reply.finish_reason in ["stop", "length"])
        #{pause(fields)}
      end
      """
    end

    defp pause(%{"pause" => 0}), do: ""
    defp pause(%{"pause" => seconds}), do: "Process.sleep(to_timeout(second: #{seconds}))"

    defp options(fields) do
      %{"vus" => vus, "ramp" => ramp, "hold" => hold, "p95" => p95} = fields

      # Ramps up, then holds, for at least a second.
      stages =
        [{ramp, vus}, {if(ramp == 0, do: max(hold, 1), else: hold), vus}]
        |> Enum.filter(fn {seconds, _vus} -> seconds > 0 end)
        |> Enum.map_join(", ", fn {seconds, vus} -> "{[second: #{seconds}], #{vus}}" end)

      metric = inspect(@metrics[fields["kind"]])

      probe =
        if fields["probe"] == "",
          do: "",
          else: ", probe: #{inspect(String.to_atom(fields["probe"]))}"

      "stages: [#{stages}], " <>
        ~s(thresholds: [{#{metric}, p95: #{p95}}, {"iteration.errors", count: 0}]) <> probe
    end

    # The app's node usually has a cookie of its own.
    defp cookie(%{"probe" => probe, "cookie" => cookie}) when probe != "" and cookie != "" do
      "Node.set_cookie(#{inspect(String.to_atom(probe))}, #{inspect(String.to_atom(cookie))})"
    end

    defp cookie(_fields), do: ""

    asset "main.js" do
      """
      export function init(ctx, fields) {
        ctx.importCSS("main.css");

        ctx.root.innerHTML = `
          <form class="app">
            <div class="row header">
              <label class="field">
                <span>Load test</span>
                <select name="kind">
                  <option value="http">An HTTP page</option>
                  <option value="live">A LiveView</option>
                  <option value="channels">A Phoenix channel</option>
                  <option value="llm">An AI chat API</option>
                </select>
              </label>
              <label class="field grow"><span>URL</span><input name="url" type="text"></label>
              <label class="field" data-kind="channels"><span>Topic</span><input name="topic" type="text"></label>
              <label class="field" data-kind="channels"><span>Event</span><input name="event" type="text"></label>
              <label class="field" data-kind="llm"><span>Model</span><input name="model" type="text"></label>
            </div>
            <div class="row">
              <label class="field"><span>Users</span><input name="vus" type="number" min="0"></label>
              <label class="field"><span>Ramp up, s</span><input name="ramp" type="number" min="0"></label>
              <label class="field"><span>Hold, s</span><input name="hold" type="number" min="0"></label>
              <label class="field"><span>Pause, s</span><input name="pause" type="number" min="0"></label>
              <label class="field"><span>p95 under, ms</span><input name="p95" type="number" min="0"></label>
            </div>
            <div class="row">
              <label class="field"><span>Scenario</span><input name="name" type="text"></label>
              <label class="field grow"><span>Probe the app's node</span><input name="probe" type="text" placeholder="app@127.0.0.1"></label>
              <label class="field"><span>Its cookie</span><input name="cookie" type="text"></label>
            </div>
          </form>
        `;

        const form = ctx.root.querySelector("form");

        const show = (fields) => {
          for (const [name, value] of Object.entries(fields)) {
            const input = form.elements[name];
            if (input && input !== document.activeElement) input.value = value;
          }

          for (const field of form.querySelectorAll("[data-kind]")) {
            field.hidden = field.dataset.kind !== fields.kind;
          }
        };

        show(fields);
        form.addEventListener("submit", (event) => event.preventDefault());
        form.addEventListener("change", (event) => {
          ctx.pushEvent("update", { field: event.target.name, value: event.target.value });
        });

        ctx.handleEvent("update", show);

        // Sends a field still being edited before the cell runs.
        ctx.handleSync(() => {
          const input = document.activeElement;
          if (input && form.contains(input)) input.dispatchEvent(new Event("change", { bubbles: true }));
        });
      }
      """
    end

    asset "main.css" do
      """
      .app {
        font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
        font-size: 14px;
        border: 1px solid #e1e8f0;
        border-radius: 8px;
        overflow: hidden;
      }
      .row {
        display: flex;
        flex-wrap: wrap;
        gap: 12px;
        padding: 12px 16px;
      }
      .row + .row { border-top: 1px solid #e1e8f0; }
      .header { background: #f0f5f9; }
      .field { display: flex; flex-direction: column; gap: 4px; min-width: 7rem; }
      .field[hidden] { display: none; }
      .field.grow { flex: 1; min-width: 14rem; }
      .field span { color: #445668; font-size: 12px; font-weight: 500; }
      input, select {
        box-sizing: border-box;
        width: 100%;
        padding: 6px 8px;
        border: 1px solid #cad5e0;
        border-radius: 6px;
        background: #fff;
        color: #0b0b0b;
        font: inherit;
      }
      input[type="number"] { width: 7rem; }
      """
    end
  end
end
