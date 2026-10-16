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
  are not retried. Retried events can arrive out of order, so receivers
  should be idempotent.

  By default pending retries live in memory: if the node stops meanwhile
  they are lost, and delivery is at-least-once only while the node stays up.
  Set `:webhook_queue_path` (`SOCKETELX_WEBHOOK_QUEUE_PATH`) to a directory
  and a webhook that failed its first attempt is also written to a small
  file there, removed once it is delivered or given up on. After a restart
  the node delivers whatever is still in the file. In Docker, mount a volume
  at that path. It protects against this node restarting, not against losing
  its disk.
  """
  require Logger
  alias Socketelx.{Auth, Config, Metrics}
  alias Socketelx.Webhook.Queue

  @doc "Builds the {body, headers} for a webhook payload. Pure — no I/O, easy to test."
  def build(name, events) when is_list(events) do
    config = Config.get(name)
    body = Jason.encode!(%{time_ms: System.system_time(:millisecond), events: events})
    {body, headers(config, body)}
  end

  defp headers(config, body) do
    [
      {~c"content-type", ~c"application/json"},
      {~c"x-pusher-key", to_charlist(config.app_key)},
      {~c"x-pusher-signature", to_charlist(Auth.sign(config.app_secret, body))}
    ]
  end

  @doc "Starts delivery in the background (with retries). No-op if this instance has no webhook_url configured."
  def dispatch(name, events) when is_list(events) do
    if Config.get(name).webhook_url do
      {body, _headers} = build(name, events)
      Task.start(fn -> run(name, new_id(), body, 0) end)
    end

    :ok
  end

  @doc false
  def child_specs(name, %{webhook_queue_path: path, webhook_url: url}) do
    if path && url,
      do: [Supervisor.child_spec({Socketelx.Webhook.Queue, name}, id: {:webhook_queue, name})],
      else: []
  end

  @doc false
  # Used by the queue after a restart: carry on delivering a saved webhook.
  def resume(name, id, body, attempt), do: run(name, id, body, attempt)

  defp new_id, do: {System.system_time(:microsecond), :erlang.unique_integer([:positive])}

  defp run(name, id, body, n) do
    config = Config.get(name)

    case config.webhook_url && post(config.webhook_url, body, headers(config, body)) do
      nil ->
        Queue.delete(name, id)

      :ok ->
        Metrics.incr(name, :webhooks_sent_total)
        Queue.delete(name, id)

      {:retry, _reason} when n < config.webhook_retries ->
        Metrics.incr(name, :webhook_retries_total)
        # keep a copy on disk (when enabled) before waiting, so a restart doesn't lose it
        Queue.save(name, id, body, n + 1)
        # 1s, 2s, 4s ... (with the default base)
        Process.sleep(config.webhook_retry_base_ms * Integer.pow(2, n))
        run(name, id, body, n + 1)

      {_kind, reason} ->
        Metrics.incr(name, :webhooks_failed_total)
        Queue.delete(name, id)

        Logger.warning(
          "Webhook POST to #{config.webhook_url} failed after #{n + 1} attempt(s): #{reason}"
        )
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
