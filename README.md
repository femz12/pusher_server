# Socketelx

A Pusher-compatible WebSocket server for Elixir, inspired by Laravel Reverb.
Browsers connect with `pusher-js` (or any Pusher client library), and your
backend sends events with any Pusher server library or a plain signed HTTP
request. You host it yourself.

Run it two ways, from the same code:

- **Standalone:** a Docker image you run next to your app.
- **Embedded:** a Hex dependency inside your own Elixir/Phoenix app.

It runs on one server with nothing else, or on several servers sharing a Redis.

> Socketelx is an independent open-source project. It implements the public Pusher
> Channels protocol so existing Pusher clients and libraries work with it. It is
> not affiliated with, endorsed by or sponsored by Pusher Ltd. "Pusher" is a
> trademark of its owner and is used here only to describe compatibility.

## What you can build with it

Chat, live notifications, presence ("who is online"), live dashboards,
collaborative cursors, order tracking: anything where the server pushes updates
to browsers and phones as they happen.

- Public, private and presence channels, with signed channel auth
- Presence that counts a user once across tabs and devices
- Client events (`client-*`) for things like typing indicators
- REST API: trigger events, batch events, list channels, channel info
- Signed webhooks with retries
- Optional rate limits, connection cap, and Prometheus metrics
- Multi-server mode through Redis (optional)
- Graceful shutdown: clients are told to reconnect before a node exits

It works with the clients and libraries you probably already use: `pusher-js`,
`laravel-echo`, and the official Pusher server SDKs (Node, PHP, Python, Ruby,
Go and others).

## Quickstart: Docker

```bash
docker run -p 6001:6001 \
  -e SOCKETELX_APP_ID=my-app-id \
  -e SOCKETELX_APP_KEY=my-app-key \
  -e SOCKETELX_APP_SECRET=a-long-random-secret \
  ghcr.io/socketelx/socketelx:latest
```

**In the browser** (`npm install pusher-js`):

```js
import Pusher from 'pusher-js';

const pusher = new Pusher('my-app-key', {
  cluster: 'unused',            // required by pusher-js, ignored by this server
  wsHost: 'localhost',
  wsPort: 6001,
  forceTLS: false,
  enabledTransports: ['ws', 'wss'],
  disableStats: true,
});

pusher.subscribe('news').bind('update', (data) => console.log(data));
```

**From your backend** (`npm install pusher`, shown in Node; every official SDK works the same way):

```js
import Pusher from 'pusher';

const pusher = new Pusher({
  appId: 'my-app-id', key: 'my-app-key', secret: 'a-long-random-secret',
  host: '127.0.0.1', port: '6001', useTLS: false,
});

await pusher.trigger('news', 'update', { hello: 'world' });
```

The browser logs `{ hello: 'world' }`. Private and presence channels also need an
auth endpoint in your backend; the [chat example](examples/chat/README.md) shows
the whole thing.

## Quickstart: embed in your Elixir app

```elixir
# mix.exs
{:socketelx, "~> 0.2"}

# lib/my_app/application.ex
children = [
  MyApp.Repo,
  MyAppWeb.Endpoint,
  {Socketelx,
   name: MyApp.Socketelx,
   port: 6001,
   app_id: "my-app-id",
   app_key: "my-app-key",
   app_secret: "a-long-random-secret"}
]
```

Publish from anywhere in your app, with no HTTP call, and sign channel joins:

```elixir
Socketelx.trigger(MyApp.Socketelx, "news", "update", %{hello: "world"})

Socketelx.authorize_channel(MyApp.Socketelx, socket_id, "presence-room",
  user_id: user.id, user_info: %{name: user.name})
```

The server runs its own listener on its own port; it is not a Plug inside your
Phoenix endpoint. See the [Embedding guide](guides/embedding.md).

## A complete example: simple chat

[`examples/chat`](examples/chat/README.md) is a small chat app (online list,
messages, "is typing") in two versions: one using the Docker image with a tiny
Node backend, one fully embedded in an Elixir app. Each is a few short files and
a step-by-step setup.

## Similar projects

- [Poxa](https://github.com/edgurgel/poxa): an older, well-known Pusher-compatible server written in Elixir.
- [Laravel Reverb](https://reverb.laravel.com/): the PHP server that inspired this project, speaking the same protocol.

## Several servers

Give every node the same app credentials and the same `SOCKETELX_REDIS_URL`, and
put a load balancer in front. Events, presence and channel occupancy are shared.
Without `SOCKETELX_REDIS_URL` no Redis connection is ever opened. See the
[Multi-server guide](guides/multi-server.md).

## Documentation

- [Getting started](guides/getting-started.md): run it and connect a client
- [Configuration](guides/configuration.md): every option and environment variable
- [Embedding](guides/embedding.md): use it as a library
- [Multi-server](guides/multi-server.md): Redis and failure behaviour
- [Deployment](guides/deployment.md): TLS, proxies, Docker, shutdown
- [Load testing](guides/load-testing.md): simulate connections and measure capacity
- [Protocol support](guides/protocol-support.md): what is and isn't implemented
- [Troubleshooting](guides/troubleshooting.md)
- [Using it with Laravel](guides/laravel.md)

## Status

Early (0.x), and in use in a real chat application. The test suite starts real
nodes on real sockets, speaks the WebSocket protocol to them, signs REST calls,
and, with a real Redis, covers cross-node delivery, a node dying, Redis being
flushed and Redis being unreachable. The chat example is also tested end to end
in a real browser with `pusher-js` 8.

Not verified yet: behaviour at very large scale (see
[Load testing](guides/load-testing.md) to measure your own), the Compose/nginx
example, and Elixir versions other than the ones CI uses.

Not implemented: user sign-in features and the users endpoints, durable webhook
retries, per-IP limits, built-in TLS, Redis Cluster. Delivery is at-most-once,
like Pusher. Details in [Protocol support](guides/protocol-support.md).

## Development and contributing

```bash
mix deps.get
mix test            # Redis tests are skipped unless SOCKETELX_TEST_REDIS_URL is set
iex -S mix          # starts the listener on PORT (default 6001)
```

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: see
[SECURITY.md](SECURITY.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## License

MIT, see [LICENSE](https://github.com/socketelx/socketelx/blob/main/LICENSE).
