# Embedding in your app

Add the dependency:

```elixir
# mix.exs
defp deps do
  [{:pusher_server, "~> 0.1"}]
end
```

Start it from your supervision tree:

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  MyAppWeb.Endpoint,
  {PusherServer,
   name: MyApp.PusherServer,
   port: 6001,
   app_key: System.fetch_env!("PUSHER_APP_KEY"),
   app_secret: System.fetch_env!("PUSHER_APP_SECRET"),
   app_id: System.fetch_env!("PUSHER_APP_ID")}
]
```

Nothing starts automatically when the package is a dependency. Only the
standalone release (this repository's own `config/runtime.exs`) turns on
auto-start; a dependency's config files are ignored by the host app.

## It runs its own listener

`PusherServer` starts its own Cowboy listener on its own `:port`. It is not a
Plug you mount in your Phoenix router or endpoint. Your frontend connects to
that port (directly or through your proxy), and your backend sends events to
the same port over the REST API.

## Several instances

Each instance needs a unique `:name` and its own `:port`, and keeps fully
separate channel and presence state:

```elixir
children = [
  {PusherServer, name: MyApp.PusherA, port: 6001, app_id: "a", app_key: "ka", app_secret: "sa"},
  {PusherServer, name: MyApp.PusherB, port: 6002, app_id: "b", app_key: "kb", app_secret: "sb"}
]
```

## Sending events from Elixir

Events are sent the same way as for any Pusher server: a signed
`POST /apps/:app_id/events`. Any Pusher HTTP client library works, pointed at
your host and port.

## Draining on shutdown

When the standalone release stops, it drains automatically. If you embed and
want clients to reconnect cleanly before your app exits, call
`PusherServer.drain/1` from your application's `prep_stop/1`:

```elixir
@impl true
def prep_stop(state) do
  PusherServer.drain(MyApp.PusherServer)
  Process.sleep(1_000)
  state
end
```

It must run in `prep_stop/1`, not `stop/1`: by `stop/1` the supervision tree is
already gone and the sockets are already closed.

## Redis

Pass `redis_url: "redis://..."` to share state between several nodes. See
[Multi-server](multi-server.md).
