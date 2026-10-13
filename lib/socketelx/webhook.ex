defmodule Socketelx.Webhook do
  @moduledoc """
  Fires webhooks in the same shape Pusher sends them, so your backend can
  handle them with any code written for Pusher webhooks:

      POST {webhook_url for this instance}
      X-Pusher-Key: <app_key>
      X-Pusher-Signature: HMAC-SHA256(app_secret, raw_body)

      {"time_ms": 1699999999999, "events": [{"name": "channel_occupied", "channel": "..."}]}

  Only fires if the instance has a `webhook_url` configured. Delivery runs
  in its own process (a `Task.start/1`), so a slow or dead webhook receiver
  never blocks a websocket connection.

  A failed delivery (network error, timeout, HTTP 5xx, 408 or 429) is
  retried up to `:webhook_retries` times (default 3) with a doubling delay
  starting at `:webhook_retry_base_ms` (default 1 s). Other 4xx responses
  are not retried. Retries live in memory: if the node stops meanwhile,
  pending retries are lost, and retried events can arrive out of order, so
  receivers should be idempotent. Delivery is at-least-once while the node
  stays up.
  """
  require Logger
  alias Socketelx.{Auth, Config, Metrics}

  @doc "Builds the {body, headers} for a webhook payload. Pure — no I/O, easy to test."
  def build(name, events) when is_list(events) do
    config = Config.get(name)
    body = Jason.encode!(%{time_ms: System.system_time(:millisecond), events: events})
    signature = Auth.sign(config.app_secret, body)

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"x-pusher-key", to_charlist(config.app_key)},
      {~c"x-pusher-signature", to_charlist(signature)}
    ]

    {body, headers}
  end

  @doc "Starts delivery in the background (with retries). No-op if this instance has no webhook_url configured."
  def dispatch(name, events) when is_list(events) do
    case Config.get(name).webhook_url do
      nil -> :ok
      url -> Task.start(fn -> send_webhook(name, url, events) end)
    end

    :ok
  end

  defp send_webhook(name, url, events) do
    config = Config.get(name)
    {body, headers} = build(name, events)
    attempt(name, url, body, headers, 0, config.webhook_retries, config.webhook_retry_base_ms)
  end

  defp attempt(name, url, body, headers, n, max_retries, base_ms) do
    case post(url, body, headers) do
      :ok ->
        Metrics.incr(name, :webhooks_sent_total)

      {:retry, _reason} when n < max_retries ->
        Metrics.incr(name, :webhook_retries_total)
        # 1s, 2s, 4s ... (with the default base)
        Process.sleep(base_ms * Integer.pow(2, n))
        attempt(name, url, body, headers, n + 1, max_retries, base_ms)

      {_kind, reason} ->
        Metrics.incr(name, :webhooks_failed_total)
        Logger.warning("Webhook POST to #{url} failed after #{n + 1} attempt(s): #{reason}")
    end
  end

  # Server errors, timeouts and network failures are worth retrying;
  # other 4xx responses mean the receiver rejected the payload, so retrying
  # would just repeat the rejection.
  defp post(url, body, headers) do
    case :httpc.request(
           :post,
           {to_charlist(url), headers, ~c"application/json", body},
           [{:timeout, 5_000}],
           []
         ) do
      {:ok, {{_version, status, _reason}, _headers, _body}} when status in 200..299 ->
        :ok

      {:ok, {{_version, status, _reason}, _headers, _body}}
      when status >= 500 or status in [408, 429] ->
        {:retry, "HTTP #{status}"}

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:permanent, "HTTP #{status}"}

      {:error, reason} ->
        {:retry, inspect(reason)}
    end
  end
end
