# pusher_server

A small Elixir server that speaks the [Pusher Channels](https://pusher.com/docs/channels/)
WebSocket and HTTP protocol. Use it as a self-hosted replacement for Laravel
Reverb, Soketi or Pusher itself: Laravel's built-in `pusher` broadcaster and
`laravel-echo` / `pusher-js` talk to it unmodified.

It ships two ways from the same code:

- **Standalone**: a Docker image you run next to your app.
- **Embedded**: a Hex dependency you add to your own supervision tree.

Runs on one server with no other services, or on several servers sharing a
Redis. Redis is optional.

## Features

- Public, private and presence channels, with HMAC-SHA256 channel auth
- Presence deduplicated per user across tabs (`member_added` / `member_removed`
  fire on first join / last leave)
- Client events (`client-*`) on private and presence channels
- REST API signed like Pusher's: trigger events, batch events, list channels,
  channel info
- Signed webhooks (`channel_occupied`, `channel_vacated`, `member_added`,
  `member_removed`, `client_event`) with retries
- Optional rate limits and connection cap, and Prometheus metrics
- Multi-server mode through Redis (optional)
- Graceful shutdown: clients are told to reconnect before the node exits
- Several independent instances in one app (different app ids, different ports)

## Quickstart: Docker + Laravel

```bash
docker build -t pusher-server .
docker run -p 6001:6001 \
  -e PUSHER_APP_ID=my-app-id \
  -e PUSHER_APP_KEY=my-app-key \
  -e PUSHER_APP_SECRET=a-long-random-secret \
  pusher-server
```

Point Laravel at it in `.env`:

```dotenv
BROADCAST_CONNECTION=pusher
PUSHER_APP_ID=my-app-id
PUSHER_APP_KEY=my-app-key
PUSHER_APP_SECRET=a-long-random-secret
PUSHER_HOST=127.0.0.1
PUSHER_PORT=6001
PUSHER_SCHEME=http
```

The full Laravel and Echo setup is in the
[Getting started guide](guides/getting-started.md).

## Quickstart: embed in your Elixir app

```elixir
# mix.exs
{:pusher_server, "~> 0.1"}

# lib/my_app/application.ex
children = [
  MyApp.Repo,
  MyAppWeb.Endpoint,
  {PusherServer,
   name: MyApp.PusherServer,
   port: 6001,
   app_key: "my-key",
   app_secret: "my-secret",
   app_id: "my-app-id"}
]
```

Every option falls back to the same environment variables the standalone image
uses. The server runs its own listener on its own port; it does not live inside
your Phoenix endpoint. See the [Embedding guide](guides/embedding.md).

## Several servers

Set the same app credentials and the same `PUSHER_REDIS_URL` on every node and
put a load balancer in front. Events, presence and occupancy are then shared
across nodes. Without `PUSHER_REDIS_URL` no Redis connection is ever opened.
See the [Multi-server guide](guides/multi-server.md).

## Documentation

- [Getting started](guides/getting-started.md): Docker, Laravel, Echo
- [Configuration](guides/configuration.md): every option and environment variable
- [Embedding](guides/embedding.md): use it as a library
- [Multi-server](guides/multi-server.md): Redis, failure behaviour
- [Deployment](guides/deployment.md): TLS, proxies, shutdown, Compose
- [Protocol support](guides/protocol-support.md): what is and isn't implemented
- [Troubleshooting](guides/troubleshooting.md)

## Status

Early (0.x). The test suite starts real nodes on real sockets, speaks the
WebSocket protocol to them, signs REST calls the way Laravel does, and, with a
real Redis, covers cross-node delivery, a node dying, Redis being flushed and
Redis being unreachable.

Not verified yet: behaviour at load, and Elixir versions other than the one CI uses. The
batch, channel-list, retry, limit and metrics features are covered by tests
only. Please test your own setup before relying on it, and report what you find.

Not implemented: user sign-in features and the users endpoints, durable webhook
retries, per-IP limits, built-in TLS, Redis Cluster. Delivery is at-most-once,
like Pusher. Details in
[Protocol support](guides/protocol-support.md).

## Development and contributing

```bash
mix deps.get
mix test            # Redis tests are skipped unless PUSHER_TEST_REDIS_URL is set
iex -S mix          # starts the listener on PORT (default 6001)
```

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: see
[SECURITY.md](SECURITY.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## License

MIT, see [LICENSE](https://github.com/femz12/pusher_server/blob/main/LICENSE).
