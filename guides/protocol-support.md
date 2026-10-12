# Protocol support

The Pusher Channels protocol, as used by `pusher-js`, `laravel-echo` and the
Pusher server SDKs. Only what is listed under "Supported" is implemented;
anything else is unsupported.

## Supported

**WebSocket** at `/app/:app_key`

- `pusher:connection_established` on connect (advertises a 30 s activity timeout)
- `pusher:subscribe`, `pusher:unsubscribe`
- public, private and presence channels
- channel auth: HMAC-SHA256 over `socket_id:channel` (plus `:channel_data` for
  presence)
- `pusher:ping` / `pusher:pong`
- client events (`client-*`) on private and presence channels
- idle connections are closed after 60 s of silence

**HTTP**

| Endpoint | Purpose |
|---|---|
| `GET /` | Health check, returns `ok` |
| `POST /apps/:app_id/events` | Trigger an event on one or more channels |
| `POST /apps/:app_id/batch_events` | Trigger up to 10 events, configurable with `PUSHER_BATCH_LIMIT` (`{"batch": [{channel, name, data, socket_id?}]}`) |
| `GET /apps/:app_id/channels` | List occupied channels. `filter_by_prefix`, and `info=user_count` with `filter_by_prefix=presence-` |
| `GET /apps/:app_id/channels/:channel` | Occupancy and subscription count (and `user_count` for presence channels) |
| `GET /metrics` | Prometheus metrics, off unless enabled; see [Configuration](configuration.md#metrics) |

REST requests are signed like Pusher's API: sorted query parameters,
`METHOD\nPATH\nquery`, `body_md5`, and an `auth_timestamp` within 10 minutes.

**Webhooks**: `channel_occupied`, `channel_vacated`, `member_added`,
`member_removed`, `client_event`. Signed with `X-Pusher-Key` and
`X-Pusher-Signature`. Failed deliveries are retried (see
[Configuration](configuration.md#webhooks)).

## Error codes sent to clients

| Code | Meaning |
|---|---|
| 4000 | Server is shutting down; reconnect |
| 4001 | App key does not exist |
| 4009 | Invalid channel auth signature |
| 4200 | Invalid `channel_data` |
| 4004 | Over capacity (`:max_connections` reached) |
| 4301 | Client event not allowed, or over the client-event rate limit |

## Not implemented

- the users endpoints (`/channels/:channel/users`)
- user sign-in features (`pusher:signin`, watchlist). Unknown events are
  silently ignored.
- per-IP rate limits (limits are per instance or per connection)
- durable webhook retries (retries live in memory)
- built-in TLS (use a proxy)
- Redis Cluster
- message replay or caching channels: delivery is at-most-once
