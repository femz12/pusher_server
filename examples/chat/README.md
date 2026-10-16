# Simple chat example

A small chat room: an online list, messages, and a "is typing…" indicator. It
shows every piece you need to build real-time features on `socketelx`.

It comes in two versions. Pick one:

| Version | Use it when | You need |
|---|---|---|
| [`standalone/`](#a-standalone-docker) | Your backend is any language and you run `socketelx` as a Docker container | Docker |
| [`embedded/`](#b-embedded-in-an-elixir-app) | Your app is Elixir and you want one app, no extra container | Elixir 1.15+ |

Both serve the same page (`index.html`). Open `http://localhost:3000` (standalone)
or `http://localhost:4000` (embedded) in **two browser tabs**, pick two names,
and chat.

## How it works

1. The page connects to `socketelx` with `pusher-js` and joins the channel
   `presence-chat`.
2. A presence channel needs your backend to approve each join. pusher-js calls
   `POST /pusher/auth`; the backend signs the request with the app secret and
   returns it. The signed `user_id` and `user_info` are what the online list shows.
3. To send a message the page calls `POST /messages` on your backend. The backend
   publishes a `message` event to the channel, and the server delivers it to every
   open tab.
4. "is typing…" uses a client event (`client-typing`): one browser sends it
   straight to the others through the server, with no backend involved.
5. Joins and leaves arrive as `pusher:member_added` and `pusher:member_removed`.

The only Pusher-specific code in the browser is the `new Pusher(...)` block at the
top of `index.html`. In the backend it is two small functions: sign a join, and
publish an event.

## A. Standalone (Docker)

Files:

```
standalone/
  docker-compose.yml   runs the socketelx image and the chat backend
  server.mjs           the backend (Node 18+, no packages): page, /pusher/auth, /messages
  public/index.html    the chat page
```

Steps:

1. Install Docker.
2. `cd examples/chat/standalone`
3. `docker compose up`
4. Open <http://localhost:3000> in two tabs and chat.

To check it without a browser (Node 22+): `node ../smoke-test.mjs http://localhost:3000`
prints `PASS`.

What to read in `server.mjs`:

- `trigger(channel, event, data)` sends an event the same way every Pusher server
  library does: a signed `POST /apps/:id/events`. In your own project, use the
  official library for your language instead of writing this by hand.
- the `/pusher/auth` branch signs a presence join with the app secret.
- the `/messages` branch validates the message and calls `trigger`.

Settings (environment variables of the `chat` service):

| Variable | Meaning |
|---|---|
| `SOCKETELX_APP_ID`, `SOCKETELX_APP_KEY`, `SOCKETELX_APP_SECRET` | Must match the `pusher` service. Change the secret. |
| `SOCKETELX_URL` | How the backend reaches the server (inside Docker: `http://pusher:6001`) |
| `PUBLIC_WS_HOST`, `PUBLIC_WS_PORT`, `PUBLIC_WS_TLS` | How the browser reaches the server. Default: the page's own host, port 6001, no TLS. |

## B. Embedded in an Elixir app

Files:

```
embedded/
  mix.exs                  dependencies: socketelx, plug_cowboy, jason
  lib/chat/application.ex  starts Socketelx (port 6001) and the web app (port 4000)
  lib/chat/router.ex       the page, /pusher/auth, /messages
  lib/chat.ex              settings from environment variables
  priv/static/index.html   the chat page
```

Steps:

1. Install Elixir 1.15 or newer.
2. `cd examples/chat/embedded`
3. `mix deps.get`
4. `mix run --no-halt`
5. Open <http://localhost:4000> in two tabs and chat.

Check it without a browser (Node 22+): `node ../smoke-test.mjs http://localhost:4000`.

The whole integration is in `router.ex`:

```elixir
# sign a join (the /pusher/auth route)
Socketelx.authorize_channel(Chat.Socketelx, socket_id, "presence-chat",
  user_id: username, user_info: %{name: username})

# publish a message (the /messages route); no HTTP call, the server is in this app
Socketelx.trigger(Chat.Socketelx, "presence-chat", "message", %{user: user, text: text})
```

and one line in `application.ex` that adds `{Socketelx, name: Chat.Socketelx, ...}`
to the supervision tree. In a Phoenix app, put that line in your own supervision
tree and call the two functions from your controllers or LiveViews.

`mix.exs` depends on `socketelx` `~> 0.3` from Hex. To develop against a local
checkout, use `{:socketelx, path: "../../.."}` instead.

## Making it your own

- **Real users:** in `/pusher/auth`, read your session or token, reject if the user
  may not join, and use the real user id and name instead of the typed name.
- **Several rooms:** use `presence-room-<id>`, check access per room in
  `/pusher/auth`, and send to that room's channel.
- **Private messages:** use `private-user-<id>` channels (no `user_id` needed) and
  only authorize that user for their own channel.
- **History:** this example keeps no history. Store messages in your database in
  the `/messages` handler and load them when the page opens.
- **Production:** change the secret, serve everything over HTTPS, put the
  WebSocket behind TLS, and set `PUBLIC_WS_TLS=true`. See the
  [Deployment guide](../../guides/deployment.md).

## For AI assistants and code generators

To reproduce this in another stack, keep these four pieces and nothing else:

1. A browser page using `pusher-js` with `wsHost`/`wsPort` pointing at the server
   and `channelAuthorization.endpoint` pointing at your backend.
2. `POST /pusher/auth`: reads `socket_id` and `channel_name`, authorizes the user,
   returns `{auth, channel_data}` signed with the app secret (an official Pusher
   server library's `authorizeChannel` does this).
3. A backend call that publishes events (an official library's `trigger`, or
   `Socketelx.trigger/5` when embedded).
4. The server: `ghcr.io/socketelx/socketelx` with `SOCKETELX_APP_ID`,
   `SOCKETELX_APP_KEY` and `SOCKETELX_APP_SECRET`, or `{Socketelx, ...}` in an
   Elixir supervision tree.
