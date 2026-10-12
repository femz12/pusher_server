# Getting started

This guide runs the standalone server and connects a Laravel app (and its
Echo client) to it. If you want to embed the server in an Elixir app instead,
see the [Embedding guide](embedding.md).

> Laravel and Echo compatibility is by protocol: the server implements what the
> `pusher` broadcaster and `pusher-js` use. It has not yet been tested end to
> end against a real Laravel app. Treat the first run as a test.

## 1. Run the server

```bash
docker build -t pusher-server .
docker run -p 6001:6001 \
  -e PUSHER_APP_ID=my-app-id \
  -e PUSHER_APP_KEY=my-app-key \
  -e PUSHER_APP_SECRET=a-long-random-secret \
  pusher-server
```

Generate a real secret, for example with `openssl rand -hex 32`. If you leave
the secret unset the server falls back to a public default and logs a warning,
because anyone who knows it could sign requests and subscribe to private
channels.

Check it is up:

```bash
curl http://localhost:6001/
# ok
```

## 2. Point Laravel at it

Install the PHP SDK if you haven't:

```bash
composer require pusher/pusher-php-server
```

`.env` (use `BROADCAST_DRIVER` instead of `BROADCAST_CONNECTION` on Laravel 10
and older):

```dotenv
BROADCAST_CONNECTION=pusher
PUSHER_APP_ID=my-app-id
PUSHER_APP_KEY=my-app-key
PUSHER_APP_SECRET=a-long-random-secret
PUSHER_HOST=127.0.0.1
PUSHER_PORT=6001
PUSHER_SCHEME=http

VITE_PUSHER_APP_KEY="${PUSHER_APP_KEY}"
VITE_PUSHER_HOST="${PUSHER_HOST}"
VITE_PUSHER_PORT="${PUSHER_PORT}"
```

The three values (id, key, secret) must be identical on the server and in
Laravel. `config/broadcasting.php`:

```php
'pusher' => [
    'driver' => 'pusher',
    'key' => env('PUSHER_APP_KEY'),
    'secret' => env('PUSHER_APP_SECRET'),
    'app_id' => env('PUSHER_APP_ID'),
    'options' => [
        'host' => env('PUSHER_HOST', '127.0.0.1'),
        'port' => env('PUSHER_PORT', 6001),
        'scheme' => env('PUSHER_SCHEME', 'http'),
        'useTLS' => env('PUSHER_SCHEME', 'http') === 'https',
    ],
],
```

If your app queues broadcasts, make sure a queue worker is running, or events
will never be sent.

## 3. Point the browser at it

```bash
npm install --save-dev laravel-echo pusher-js
```

```js
// resources/js/echo.js
import Echo from 'laravel-echo';
import Pusher from 'pusher-js';

window.Pusher = Pusher;

window.Echo = new Echo({
    broadcaster: 'pusher',
    key: import.meta.env.VITE_PUSHER_APP_KEY,
    wsHost: import.meta.env.VITE_PUSHER_HOST,
    wsPort: import.meta.env.VITE_PUSHER_PORT,
    wssPort: import.meta.env.VITE_PUSHER_PORT,
    forceTLS: false,
    enabledTransports: ['ws', 'wss'],
    cluster: 'mt1', // required by pusher-js, ignored by this server
});
```

Private and presence channels need Laravel's `/broadcasting/auth` route, as with
any Pusher setup. That route signs the subscription with the same secret the
server checks.

## 4. Try it

Subscribe from the browser console:

```js
Echo.channel('orders').listen('.test', (e) => console.log(e));
```

Then send an event from Laravel (`php artisan tinker`):

```php
broadcast(new class implements Illuminate\Contracts\Broadcasting\ShouldBroadcastNow {
    public function broadcastOn() { return new Illuminate\Broadcasting\Channel('orders'); }
    public function broadcastAs() { return 'test'; }
});
```

The browser should log the event. If nothing arrives, see
[Troubleshooting](troubleshooting.md).

## Next

- [Configuration](configuration.md) for webhooks and client events
- [Deployment](deployment.md) for TLS and proxies
- [Multi-server](multi-server.md) to run more than one node
