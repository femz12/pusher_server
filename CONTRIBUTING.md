# Contributing

Thanks for helping. Bug reports, protocol fixes, docs and tests are all welcome.

## Setup

```bash
mix deps.get
mix test
```

The Redis tests (tagged `:redis`) are skipped unless you point them at a
throwaway Redis. They only touch keys starting with `pusher:` in the database
you give:

```bash
docker run -d -p 6379:6379 redis:7
PUSHER_TEST_REDIS_URL=redis://localhost:6379/15 mix test
```

Run `mix format` before committing; CI runs `mix format --check-formatted`.

## Code map

| Path | What it does |
|---|---|
| `lib/pusher_server.ex` | Public supervisor, `drain/1` |
| `lib/pusher_server/ws_handler.ex` | WebSocket protocol (one process per connection) |
| `lib/pusher_server/http_router.ex` | REST API and health check |
| `lib/pusher_server/auth.ex` | Channel and request signature checks |
| `lib/pusher_server/cluster.ex` | Facade: local delivery first, then the backend |
| `lib/pusher_server/backend/local.ex` | In-memory backend (single node) |
| `lib/pusher_server/backend/redis.ex` | Redis backend (pub/sub, Lua scripts, janitor) |
| `lib/pusher_server/webhook.ex` | Signed webhooks with retries |
| `lib/pusher_server/metrics.ex`, `rate_limiter.ex` | Prometheus counters, REST rate limit |
| `test/support/ws_client.ex` | Minimal WebSocket client used by the tests |

## Pull requests

1. Open an issue first for anything big, so we can agree on the approach.
2. Add or update tests. Behaviour that touches Redis needs a `:redis` test.
3. Update `CHANGELOG.md` under "Unreleased".
4. Keep the Pusher protocol behaviour compatible with `pusher-js`.

By contributing you agree your work is released under the MIT license.
