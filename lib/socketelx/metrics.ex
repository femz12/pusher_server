defmodule Socketelx.Metrics do
  @moduledoc """
  Counters and a Prometheus-format exporter for one instance.

  Turn it on with `metrics: true` (or `SOCKETELX_METRICS=true`) and scrape
  `GET /metrics`. Set `:metrics_token` (`SOCKETELX_METRICS_TOKEN`) to require an
  `Authorization: Bearer <token>` header. Without a token the endpoint is
  open to anyone who can reach the port, so block `/metrics` at your proxy.

  Counters are per node and reset when the node restarts, which is what
  Prometheus expects (`rate()` handles resets). With several nodes, scrape
  each one.
  """

  @counters [
    connections_total: "WebSocket connections accepted",
    connections_rejected_total: "WebSocket connections refused (over :max_connections)",
    subscriptions_total: "Successful channel subscriptions",
    events_triggered_total: "Events delivered through the REST API (one per channel)",
    client_events_total: "Client events relayed",
    client_events_rate_limited_total: "Client events refused by the per-connection rate limit",
    rest_requests_total: "REST API requests received",
    rest_rate_limited_total: "REST API requests refused by the rate limit",
    webhooks_sent_total: "Webhook requests delivered (2xx)",
    webhook_retries_total: "Webhook delivery retries",
    webhooks_failed_total: "Webhooks given up on after all retries"
  ]

  @index @counters |> Keyword.keys() |> Enum.with_index(1) |> Map.new()

  @doc false
  def init(name) do
    :persistent_term.put(
      {__MODULE__, name},
      :counters.new(map_size(@index), [:write_concurrency])
    )

    :ok
  end

  @doc "Adds `n` to a counter. A no-op when the instance has no counters (e.g. in unit tests)."
  def incr(name, key, n \\ 1) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> :ok
      ref -> :counters.add(ref, Map.fetch!(@index, key), n)
    end
  end

  @doc "Current value of a counter."
  def get(name, key) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> 0
      ref -> :counters.get(ref, Map.fetch!(@index, key))
    end
  end

  @doc "Renders every counter and gauge in the Prometheus text exposition format."
  def render(name), do: render_many([{name, nil}])

  @doc """
  Like `render/1` for several apps at once: one sample per app, labelled
  `app="<id>"`, under a single HELP/TYPE header per metric. `apps` is a list
  of `{instance, app_id}`; an app id of `nil` means no label.
  """
  def render_many(apps) do
    counters =
      for {key, help} <- @counters do
        samples = for {name, id} <- apps, do: {id, get(name, key)}
        block("socketelx_#{key}", help, "counter", samples)
      end

    gauges = [
      {"socketelx_connections", "Open WebSocket connections on this node",
       fn name -> connections(name) end},
      {"socketelx_channels", "Channels with a subscriber on this node",
       fn name -> channel_count(name) end}
    ]

    gauge_text =
      for {metric, help, fun} <- gauges do
        block(metric, help, "gauge", for({name, id} <- apps, do: {id, fun.(name)}))
      end

    IO.iodata_to_binary(counters ++ gauge_text)
  end

  defp block(metric, help, type, samples) do
    lines =
      for {id, value} <- samples do
        label = if id, do: ~s({app="#{escape(id)}"}), else: ""
        "#{metric}#{label} #{value}\n"
      end

    ["# HELP #{metric} #{help}\n# TYPE #{metric} #{type}\n" | lines]
  end

  defp escape(id), do: id |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

  defp connections(name),
    do: Registry.count_match(Socketelx.Naming.registry(name), :__all_connections__, :_)

  defp channel_count(name) do
    name
    |> Socketelx.Naming.registry()
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.reject(&(&1 == :__all_connections__))
    |> Enum.uniq()
    |> length()
  end
end
