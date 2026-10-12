# Configuration

Every setting can be passed as an option to `PusherServer.start_link/1` (or as
`{PusherServer, opts}` in a supervision tree) or set as an environment
variable. An explicit option wins over the environment variable.

| Option                     | Env var                         | Default            | Notes |
|----------------------------|---------------------------------|--------------------|-------|
| `:app_id`                  | `PUSHER_APP_ID`                 | `"app-id"`         | Must match the client SDK / Laravel. Also namespaces Redis keys. |
| `:app_key`                 | `PUSHER_APP_KEY`                | `"app-key"`        | Public; used in the WebSocket URL `/app/:app_key`. |
| `:app_secret`              | `PUSHER_APP_SECRET`             | `"app-secret"`     | Keep private. The default is public and logs a warning. |
| `:port`                    | `PORT`                          | `6001`             | Plain HTTP/WS. Put TLS in front. |
| `:webhook_url`             | `PUSHER_WEBHOOK_URL`            | none               | Where webhooks are POSTed. |
| `:client_messages_enabled` | `PUSHER_ENABLE_CLIENT_MESSAGES` | `true`             | `false` rejects all `client-*` events. |
| `:redis_url`               | `PUSHER_REDIS_URL`              | none               | Enables multi-server mode. `rediss://` for TLS. |
| `:redis_opts`              | none                            | `[]`               | Extra [Redix](https://hexdocs.pm/redix) options, e.g. `ssl: true`. |
| `:webhook_retries`         | `PUSHER_WEBHOOK_RETRIES`        | `3`                | Retries after the first attempt. `0` turns retries off. |
| `:webhook_retry_base_ms`   | none                            | `1000`             | First retry delay; doubles each time. |
| `:rest_rate_limit`         | `PUSHER_REST_RATE_LIMIT`        | none               | Max REST API requests per second for the instance. |
| `:client_event_rate_limit` | `PUSHER_CLIENT_EVENT_RATE_LIMIT`| none               | Max client events per second, per connection. |
| `:max_connections`         | `PUSHER_MAX_CONNECTIONS`        | none               | Max WebSocket connections on this node. |
| `:batch_limit`             | `PUSHER_BATCH_LIMIT`            | `10`               | Max events in one `batch_events` request. Pusher's own limit is 10. |
| `:metrics`                 | `PUSHER_METRICS`                | `false`            | Serve Prometheus metrics at `GET /metrics`. |
| `:metrics_token`           | `PUSHER_METRICS_TOKEN`          | none               | Require `Authorization: Bearer <token>` on `/metrics`. |
| `:name`                    | none                            | `PusherServer`     | Embedded only. Unique per instance. |

## One app per instance

An instance serves exactly one app (one id, key and secret). To serve several
apps, embed several named instances on different ports; see the
[Embedding guide](embedding.md).

## Client events

Clients can send `client-*` events on private and presence channels, only to
channels they are subscribed to, and never on public channels. Set
`PUSHER_ENABLE_CLIENT_MESSAGES=false` to refuse them all (the client receives
error 4301).

## Webhooks

With `PUSHER_WEBHOOK_URL` set, the server POSTs JSON for these events:

- `channel_occupied`, `channel_vacated`
- `member_added`, `member_removed` (presence channels)
- `client_event`

Each request carries `X-Pusher-Key` and `X-Pusher-Signature` (HMAC-SHA256 of the
raw body with your app secret), the same as Pusher's webhooks. Verify the
signature before trusting a request.

Delivery runs in the background and never blocks a connection. A failed
delivery (network error, timeout, HTTP 5xx, 408 or 429) is retried up to
`PUSHER_WEBHOOK_RETRIES` times (default 3) with a doubling delay: 1 s, 2 s,
4 s. Other 4xx responses are not retried, because the receiver rejected the
payload. Two things to design for:

- Retries are held in memory. If the node stops while a retry is pending, that
  webhook is lost.
- Retried events can arrive after later events, so make your receiver
  idempotent and don't rely on order.

## Rate limits and capacity

All are off by default.

- `PUSHER_REST_RATE_LIMIT=100` allows 100 REST API requests per second for the
  whole instance (the health check and `/metrics` are exempt). Extra requests
  get `429` with `Retry-After: 1`. Laravel treats that as a failed broadcast,
  so set it above your real peak.
- `PUSHER_CLIENT_EVENT_RATE_LIMIT=10` allows each connection 10 client events
  per second. Extra events are dropped and the client gets `pusher:error` 4301.
- `PUSHER_MAX_CONNECTIONS=10000` refuses new WebSocket connections on this
  node beyond that count with `pusher:error` 4004. Clients reconnect, and with
  a load balancer they may land on another node.

The limits are per instance and per node. With several nodes, each node
applies its own limit.

## Metrics

Set `PUSHER_METRICS=true` and scrape `GET /metrics` (Prometheus text format).
Counters are per node and reset on restart; scrape every node.

| Metric | Type |
|---|---|
| `pusher_server_connections` | gauge: open WebSocket connections on this node |
| `pusher_server_channels` | gauge: channels with a subscriber on this node |
| `pusher_server_connections_total`, `pusher_server_connections_rejected_total` | counter |
| `pusher_server_subscriptions_total` | counter |
| `pusher_server_events_triggered_total` | counter: events delivered via the REST API, one per channel |
| `pusher_server_client_events_total`, `pusher_server_client_events_rate_limited_total` | counter |
| `pusher_server_rest_requests_total`, `pusher_server_rest_rate_limited_total` | counter |
| `pusher_server_webhooks_sent_total`, `pusher_server_webhook_retries_total`, `pusher_server_webhooks_failed_total` | counter |

Set `PUSHER_METRICS_TOKEN` to require `Authorization: Bearer <token>`. Without
a token anyone who can reach the port can read `/metrics`, so block that path
at your proxy.

## Redis

See [Multi-server](multi-server.md). Redis is used only when `:redis_url` is set.
