# Troubleshooting

## The client cannot connect

- **Error 4001 (app does not exist)**: the key in the browser does not match
  `PUSHER_APP_KEY` on the server. Check `VITE_PUSHER_APP_KEY` and rebuild your
  assets; Vite bakes it in at build time.
- **Connection closes immediately behind a proxy**: the proxy is not passing the
  WebSocket upgrade. You need HTTP/1.1 and the `Upgrade` / `Connection` headers;
  see [Deployment](deployment.md).
- **Connection drops about every minute**: a proxy timeout is shorter than 60 s.
  Raise it (300 s is typical).
- **Mixed content / blocked**: an `https` page needs `wss://`, which means TLS in
  front of the server and `forceTLS: true`.

## Private or presence subscription fails

- **Error 4009 (invalid signature)**: the secret used by Laravel's
  `/broadcasting/auth` differs from `PUSHER_APP_SECRET` on the server, or the
  response is for a different `socket_id` or channel name. Compare the three
  values (id, key, secret) on both sides.
- **Error 4200**: the `channel_data` in a presence auth response is not valid
  JSON with a `user_id`.
- **`/broadcasting/auth` returns 403**: that is Laravel's channel authorization
  (`routes/channels.php`), not this server.

## Events sent from Laravel never arrive

1. Is a queue worker running? Events broadcast with `ShouldBroadcast` are queued.
2. Is `BROADCAST_CONNECTION=pusher` (or `BROADCAST_DRIVER` on older Laravel)?
3. Can Laravel reach `PUSHER_HOST:PUSHER_PORT`? Inside Docker, `127.0.0.1` is the
   container itself; use the service name.
4. Look at the Laravel log for a Pusher exception. A 401 means the secret or app
   id does not match, the body hash is wrong, or the clocks differ by more than
   10 minutes. A 400 means the request body was not valid.
5. Event names: Echo listens for `.name` (leading dot) for a custom
   `broadcastAs()`, and for `App\Events\Name` otherwise.

## Test the REST API by hand

This sends a signed event, the same way Laravel does:

```bash
APP_ID=my-app-id; KEY=my-app-key; SECRET=a-long-random-secret
BODY='{"name":"test","channels":["orders"],"data":"{\"hello\":\"world\"}"}'
MD5=$(printf '%s' "$BODY" | openssl md5 | awk '{print $NF}')
TS=$(date +%s)
QUERY="auth_key=$KEY&auth_timestamp=$TS&auth_version=1.0&body_md5=$MD5"
SIG=$(printf 'POST\n/apps/%s/events\n%s' "$APP_ID" "$QUERY" \
  | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')
curl -i -X POST "http://localhost:6001/apps/$APP_ID/events?$QUERY&auth_signature=$SIG" \
  -H 'Content-Type: application/json' -d "$BODY"
```

`200` means the signature was accepted. `401` means the secret, app id,
body hash or timestamp is wrong.

## Several servers

- Do all nodes have the same `PUSHER_APP_ID`, `PUSHER_APP_KEY`,
  `PUSHER_APP_SECRET` **and** `PUSHER_REDIS_URL`? The app id is part of the
  Redis key prefix, so a different id means a separate cluster.
- Can every node reach Redis? If Redis is down each node keeps working alone, so
  clients on different nodes stop seeing each other's events. Look for Redis
  warnings in the logs.
- **Ghost members** for 30 to 40 seconds after a node was killed: expected. The
  surviving nodes clean up once the dead node's heartbeat expires.

## Limits and metrics

- **REST calls fail with 429**: `PUSHER_REST_RATE_LIMIT` is lower than your
  traffic. Raise it or remove it.
- **Clients get error 4004**: the node reached `PUSHER_MAX_CONNECTIONS`.
- **Client events get error 4301 mentioning the rate limit**: a connection
  exceeded `PUSHER_CLIENT_EVENT_RATE_LIMIT`.
- **`/metrics` returns 404**: set `PUSHER_METRICS=true`. A 401 means the bearer
  token is missing or wrong.
- **Webhook receiver sees duplicates or out-of-order events**: expected with
  retries. Make the receiver idempotent.

## Other

- **Warning about the default secret**: you did not set `PUSHER_APP_SECRET`.
  Set it.
- **A webhook receiver misses events**: a webhook is retried only 3 times by default and only while the node stays up. Check the logs for "Webhook POST ... failed".
- **Port already in use**: change `PORT`, or the `:port` option, per instance.

Still stuck? Open an issue with your server logs, the client error code if any,
and whether you run one node or several.
