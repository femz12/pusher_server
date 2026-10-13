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
  def render(name) do
    counters =
      for {key, help} <- @counters do
        metric = "socketelx_#{key}"
        "# HELP #{metric} #{help}\n# TYPE #{metric} counter\n#{metric} #{get(name, key)}\n"
      end

    registry = Socketelx.Naming.registry(name)
    connections = Registry.count_match(registry, :__all_connections__, :_)

    channels =
      registry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.reject(&(&1 == :__all_connections__))
      |> Enum.uniq()
      |> length()

    gauges = [
      {"socketelx_connections", "Open WebSocket connections on this node", connections},
      {"socketelx_channels", "Channels with a subscriber on this node", channels}
    ]

    gauge_text =
      for {metric, help, value} <- gauges do
        "# HELP #{metric} #{help}\n# TYPE #{metric} gauge\n#{metric} #{value}\n"
      end

    IO.iodata_to_binary(counters ++ gauge_text)
  end
end
