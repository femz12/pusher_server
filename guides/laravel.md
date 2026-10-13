# Using it with Laravel

Laravel's built-in `pusher` broadcaster and Laravel Echo work with this server,
because both only need the Pusher protocol. This page is the short setup.

## Server

Run the server as in [Getting started](getting-started.md), then give Laravel the
same id, key and secret.

## `.env`

Use `BROADCAST_DRIVER` instead of `BROADCAST_CONNECTION` on Laravel 10 and older.

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

## `config/broadcasting.php`

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

```bash
composer require pusher/pusher-php-server
```

If your events are queued, keep a queue worker running or nothing is sent.

## Echo

```bash
npm install --save-dev laravel-echo pusher-js
```

```js
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
    cluster: 'unused',
});
```

Private and presence channels use Laravel's `/broadcasting/auth` route, which
signs with the same secret this server checks.

## Notes

- Laravel's REST calls are signed Pusher API calls, the same as any SDK.
- Laravel treats an HTTP 429 as a failed broadcast. If you set
  `SOCKETELX_REST_RATE_LIMIT`, keep it above your real peak.
- `BROADCAST_CONNECTION=pusher` plus the `host` option is all that distinguishes
  this from pusher.com.
