# Troubleshooting

## The client cannot connect

- **Error 4001 (app does not exist)**: the key in the browser does not match
  `SOCKETELX_APP_KEY` on the server. Check `VITE_SOCKETELX_APP_KEY` and rebuild your
  assets; Vite bakes it in at build time.
- **Connection closes immediately behind a proxy**: the proxy is not passing the
  WebSocket upgrade. You need HTTP/1.1 and the `Upgrade` / `Connection` headers;
  see [Deployment](deployment.md).
- **Connection drops about every minute**: a proxy timeout is shorter than 60 s.
  Raise it (300 s is typical).
- **Mixed content / blocked**: an `https` page needs `wss://`, which means TLS in
  front of the server and `forceTLS: true`.

## Private or presence subscription fails

- **Error 4009 (invalid signature)**: the secret your auth endpoint signs with
  differs from `SOCKETELX_APP_SECRET` on the server, or the response is for a
  different `socket_id` or channel name. Compare the three values (id, key,
  secret) on both sides.
- **Error 4200**: the `channel_data` in a presence auth response is not valid
  JSON with a `user_id`.
- **Your auth endpoint returns 403**: that is your backend refusing the user, not
  this server. (In Laravel, see `routes/channels.php`.)

## Events sent from your backend never arrive

1. Does the backend point at the right host and port? Inside Docker, `127.0.0.1`
   is the container itself; use the service name.
2. Are the app id, key and secret identical on the backend and the server? A `401`
   from the server means the secret or app id does not match, the body hash is
   wrong, or the clocks differ by more than 10 minutes. A `400` means the request
   body was not valid.
3. Is the backend actually sending? Queued jobs, async publishers and background
   workers can hold events back. (In Laravel: run a queue worker, and check
   `BROADCAST_CONNECTION=pusher`.)
4. Does the browser listen for the exact event name on the exact channel? Names
   are case-sensitive, and `private-` and `presence-` are part of the channel name.
5. Try the signed `curl` below. If it delivers, the server is fine and the problem
   is in your backend or client.

## Test the REST API by hand

This sends a signed event, the same way any Pusher server library does:

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

- Do all nodes have the same `SOCKETELX_APP_ID`, `SOCKETELX_APP_KEY`,
  `SOCKETELX_APP_SECRET` **and** `SOCKETELX_REDIS_URL`? The app id is part of the
  Redis key prefix, so a different id means a separate cluster.
- Can every node reach Redis? If Redis is down each node keeps working alone, so
  clients on different nodes stop seeing each other's events. Look for Redis
  warnings in the logs.
- **Ghost members** for 30 to 40 seconds after a node was killed: expected. The
  surviving nodes clean up once the dead node's heartbeat expires.

## Limits and metrics

- **REST calls fail with 429**: `SOCKETELX_REST_RATE_LIMIT` is lower than your
  traffic. Raise it or remove it.
- **Clients get error 4004**: the node reached `SOCKETELX_MAX_CONNECTIONS`.
- **Client events get error 4301 mentioning the rate limit**: a connection
  exceeded `SOCKETELX_CLIENT_EVENT_RATE_LIMIT`.
- **`/metrics` returns 404**: set `SOCKETELX_METRICS=true`. A 401 means the bearer
  token is missing or wrong.
- **Webhook receiver sees duplicates or out-of-order events**: expected with
  retries. Make the receiver idempotent.

## Other

- **Warning about the default secret**: you did not set `SOCKETELX_APP_SECRET`.
  Set it.
- **A webhook receiver misses events**: a webhook is retried only 3 times by default and only while the node stays up. Check the logs for "Webhook POST ... failed".
- **Port already in use**: change `PORT`, or the `:port` option, per instance.

Still stuck? Open an issue with your server logs, the client error code if any,
and whether you run one node or several.
