# Several apps in one server

One Socketelx server can serve several Pusher apps on one port. Each app has its
own id, key and secret, and is fully separate from the others: a connection with
app A's key never sees app B's channels, presence, webhooks or counters.

Use it when you host more than one product, or want a staging and a production
app on the same box. If you only have one app you don't need any of this.

## Docker (JSON in one variable)

```bash
docker run -p 6001:6001 \
  -e SOCKETELX_APPS='[
    {"id":"chat","key":"chat-key","secret":"a-long-random-secret",
     "allowed_origins":["https://chat.example.com"]},
    {"id":"admin","key":"admin-key","secret":"another-long-secret",
     "webhook_url":"https://admin.example.com/hooks"}
  ]' \
  ghcr.io/socketelx/socketelx
```

Each app needs `id`, `key` and `secret`. It may also set `webhook_url`,
`client_messages_enabled`, `allowed_origins`, `max_connections`,
`max_connections_per_ip`, `rest_rate_limit`, `client_event_rate_limit` and
`batch_limit`. Everything else (port, Redis, cluster, metrics, TLS) is
server-wide and comes from the usual variables.

Ids and keys must be unique. Setting `SOCKETELX_APPS` replaces
`SOCKETELX_APP_ID`, `SOCKETELX_APP_KEY` and `SOCKETELX_APP_SECRET`.

## Elixir

```elixir
{Socketelx,
 name: MyApp.Socketelx,
 port: 6001,
 max_connections: 5_000,
 apps: [
   [id: "chat", key: "chat-key", secret: "...", allowed_origins: ["https://chat.example.com"]],
   [id: "admin", key: "admin-key", secret: "..."]
 ]}
```

Options outside `apps` are defaults for every app; an app's own value wins. On a
multi-app server say which app you mean:

```elixir
Socketelx.trigger(MyApp.Socketelx, "room-1", "message", %{text: "hi"}, app: "chat")
Socketelx.authorize_channel(MyApp.Socketelx, socket_id, "private-room-1", app: "chat")
```

## What each client uses

Clients connect with their app's key (`new Pusher("chat-key", ...)`), and your
backend uses that app's id and secret for the REST API
(`/apps/chat/events`). A wrong secret for an app's id is refused, the same as
any bad signature.

## Details

- **Limits are per app.** `max_connections: 5_000` means 5,000 per app, not in
  total.
- **Metrics** carry an `app="<id>"` label when there is more than one app.
- **Redis and clusters** work as before. Every node must list the same apps.
  Keys in Redis are namespaced by app id.
- **Cost.** Each app runs its own small set of processes (and its own Redis
  connections with the Redis backend), so dozens of apps are fine; thousands
  are not what this is for.
