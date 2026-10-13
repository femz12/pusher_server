# Security policy

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private vulnerability
reporting: the **Security** tab of this repository, then **Report a
vulnerability**. Include what you found, how to reproduce it and the version.

You can expect an acknowledgement within a few days. Fixes are released as soon
as practical and credited unless you prefer otherwise.

## Supported versions

Only the latest 0.x release receives fixes.

## Deployment notes

- Always set your own `SOCKETELX_APP_SECRET`. The built-in default is public.
- The server speaks plain HTTP/WS. Terminate TLS in front of it.
- The REST API is protected by request signatures. An optional per-instance rate
  limit exists (`SOCKETELX_REST_RATE_LIMIT`), off by default. Do not expose the API
  to the internet unless you need to.
- `/metrics` is off by default. If you enable it, set `SOCKETELX_METRICS_TOKEN` or
  block the path at your proxy.
- Redis (multi-server mode) holds channel names and presence data including
  user info. Protect it with a password or network rules, and use `rediss://`
  across untrusted networks.
