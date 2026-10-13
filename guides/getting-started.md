# Getting started

This guide runs the server and connects a browser and a backend to it. To
embed the server in an Elixir app instead, see the [Embedding guide](embedding.md).
For a finished app you can copy, see the [chat example](../examples/chat/README.md).

## 1. Run the server

```bash
docker run -p 6001:6001 \
  -e SOCKETELX_APP_ID=my-app-id \
  -e SOCKETELX_APP_KEY=my-app-key \
  -e SOCKETELX_APP_SECRET=a-long-random-secret \
  ghcr.io/socketelx/socketelx:latest
```

The three values are your app's credentials. Generate the secret with
`openssl rand -hex 32` and keep it on your backend only; the key is public. If
you leave the secret unset the server uses a public default and logs a warning,
because anyone who knows it can sign requests.

Check it is up:

```bash
curl http://localhost:6001/
# ok
```

## 2. Connect a browser

```bash
npm install pusher-js
```

```js
import Pusher from 'pusher-js';

const pusher = new Pusher('my-app-key', {
  cluster: 'unused',            // pusher-js requires it; this server ignores it
  wsHost: 'localhost',
  wsPort: 6001,
  wssPort: 6001,
  forceTLS: false,              // true when you serve wss:// through a proxy
  enabledTransports: ['ws', 'wss'],
  disableStats: true,
});

pusher.connection.bind('state_change', (s) => console.log(s.current));

const channel = pusher.subscribe('news');
channel.bind('update', (data) => console.log('got', data));
```

You should see `connected` in the console. Any channel name that does not start
with `private-` or `presence-` is public and needs no auth.

## 3. Send an event from your backend

Use any official Pusher server library. Point it at your server instead of
pusher.com.

Node (`npm install pusher`):

```js
import Pusher from 'pusher';

const pusher = new Pusher({
  appId: 'my-app-id', key: 'my-app-key', secret: 'a-long-random-secret',
  host: '127.0.0.1', port: '6001', useTLS: false,
});

await pusher.trigger('news', 'update', { hello: 'world' });
await pusher.triggerBatch([
  { channel: 'news', name: 'update', data: '{"n":1}' },
  { channel: 'alerts', name: 'ping', data: '{}' },
]);
```

Other languages are the same idea: set the host and port, keep TLS off for a
local server. Without a library, send a signed request yourself; the
[Troubleshooting guide](troubleshooting.md#test-the-rest-api-by-hand) has a
copy-paste `curl` that does it.

Run the Node script while the browser page is open and the browser logs the
event.

## 4. Private and presence channels

Channels named `private-...` and `presence-...` need your backend to approve each
join. pusher-js asks an endpoint you provide, and that endpoint signs the request
with your secret.

```js
const pusher = new Pusher('my-app-key', {
  /* ...same options as above... */
  channelAuthorization: { endpoint: '/pusher/auth' },
});

const room = pusher.subscribe('presence-room');
room.bind('pusher:subscription_succeeded', (members) => members.each((m) => console.log(m.id, m.info)));
room.bind('pusher:member_added', (m) => console.log('joined', m.info));
room.bind('pusher:member_removed', (m) => console.log('left', m.info));
```

Your `/pusher/auth` endpoint decides whether this user may join, then signs. With
the Node SDK that is one call:

```js
app.post('/pusher/auth', (req, res) => {
  const { socket_id, channel_name } = req.body;
  // check your own session here, then:
  const auth = pusher.authorizeChannel(socket_id, channel_name, {
    user_id: String(user.id),
    user_info: { name: user.name },   // anything you want other members to see
  });
  res.send(auth);
});
```

`presence-` channels list who is online and announce joins and leaves. A user with
several tabs counts once. Leave out `user_id` for plain `private-` channels.

The [chat example](../examples/chat/README.md) puts all of this together, with
client events for a "typing" indicator.

## 5. React to what happens (optional)

Set `SOCKETELX_WEBHOOK_URL` and the server tells your backend when channels fill and
empty and when members come and go; see [Configuration](configuration.md#webhooks).

## Using a framework

- [Laravel](laravel.md): broadcasting and Echo.
- Anything with an official Pusher server library works the same way as the Node
  example above.

## Next

- [Configuration](configuration.md)
- [Deployment](deployment.md) for TLS and proxies
- [Multi-server](multi-server.md) to run more than one node
- [Load testing](load-testing.md)
