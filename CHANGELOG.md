# Changelog

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/), versioning
follows [Semantic Versioning](https://semver.org/).

## [0.3.0]

### Added
- **Experimental:** Erlang cluster mode (`cluster: :erlang` /
  `SOCKETELX_CLUSTER=erlang`). Several nodes share events, presence, channel
  occupancy and webhooks over Erlang's own clustering, with no Redis. Nodes can
  find each other from `SOCKETELX_CLUSTER_NODES` or `SOCKETELX_CLUSTER_DNS`, or
  use a cluster your app already has. Survives a node dying, the leader dying
  and a network split that later heals. Tested across real separate nodes.
  See the Multi-server guide for setup and limits.
- `docker-compose.cluster.example.yml`, a two-node example with no Redis.

## [0.2.0]

### Changed (breaking)
- **Renamed from `pusher_server` to Socketelx.** The Hex package, OTP app and release
  are `socketelx`, the main module is `Socketelx` (was `PusherServer`), and the Docker image
  is `socketelx`. Update `{:pusher_server, ...}` to `{:socketelx, ...}` and
  `{PusherServer, ...}` to `{Socketelx, ...}`.
- Environment variables are now `SOCKETELX_*`. The old `PUSHER_*` names are still
  accepted, and `SOCKETELX_*` wins when both are set.
- Metric names start with `socketelx_` (was `pusher_server_`), and Redis keys start
  with `socketelx:` (was `pusher:`). Redis state is ephemeral, so nothing needs migrating.

### Added
- `Socketelx.trigger/5` publishes an event straight from your Elixir code, and
  `Socketelx.authorize_channel/4` signs private and presence channel joins,
  so an embedded app needs no HTTP round trip.
- `examples/chat`: a complete chat app (presence, messages, typing indicator) as
  a standalone Docker version and an embedded Elixir version, with a smoke test.
- `bench/load.mjs` and a load-testing guide to simulate many connections.
- Documentation reworked around `pusher-js` and the official Pusher server
  libraries; Laravel setup moved to its own guide.
- `POST /apps/:app_id/batch_events` (up to 10 events per request) and
  `GET /apps/:app_id/channels` (with `filter_by_prefix` and
  `info=user_count`), both working across nodes with Redis.
- The Docker workflow can also publish to Docker Hub, and tags semver versions and `latest`.
- `SOCKETELX_BATCH_LIMIT` (default 10) sets the `batch_events` size limit.
- Webhook retries with exponential backoff (`SOCKETELX_WEBHOOK_RETRIES`,
  default 3). 5xx, 408, 429 and network errors are retried; other 4xx are not.
- Optional limits, all off by default: `SOCKETELX_REST_RATE_LIMIT`,
  `SOCKETELX_CLIENT_EVENT_RATE_LIMIT`, `SOCKETELX_MAX_CONNECTIONS`.
- Optional Prometheus metrics at `GET /metrics` (`SOCKETELX_METRICS`,
  `SOCKETELX_METRICS_TOKEN`).
- Multi-server mode: set `SOCKETELX_REDIS_URL` (or the `:redis_url` option) and
  several nodes share broadcasts, presence and channel occupancy through
  Redis. A janitor heartbeats each node, removes state left by dead nodes
  and rebuilds a node's state if Redis loses its data. Single-node use is
  unchanged and still needs no Redis.
- `deploy/nginx.conf` and a two-node `docker-compose.example.yml`
- Redis service in CI so the multi-node tests run there
- User guides (`guides/`), grouped API docs, CONTRIBUTING, SECURITY, code of
  conduct, and issue / PR templates
- A warning is logged when the public default app secret is in use

### Changed
- The server now advertises a 30 s `activity_timeout` and closes connections
  silent for 60 s. Both were 120 s, so a quiet client's ping could race the
  server's own idle timeout.

### Fixed
- Several ExDoc warnings (hidden-function links, missing `Config.t()` type).
- Graceful shutdown never reached clients: the drain ran in
  `Application.stop/1`, which OTP calls after the supervision tree is gone.
  It now runs in `prep_stop/1`, with a regression test.
- CI's `mix format --check-formatted` step would have failed; the code is now
  formatted and `.formatter.exs` knows the `plug` macro.
- `config/runtime.exs` no longer starts a listener under `mix test`.
- Dockerfile copies `mix.lock` when present.

## [0.1.0] - 2026-07-09

### Added
- Pusher protocol websocket handshake, subscribe/unsubscribe, ping/pong
- Private and presence channel auth (HMAC-SHA256)
- Presence membership tracking, deduped by `user_id` across connections
- REST trigger endpoint (`POST /apps/:app_id/events`)
- Client events (`client-*`) on private/presence channels
- Webhooks (`channel_occupied`/`vacated`, `member_added`/`removed`, `client_event`)
- Read-only channel info endpoint (`GET /apps/:app_id/channels/:channel`)
- Graceful shutdown (drains connections on SIGTERM) and idle connection timeout
- Test suite for signature verification, presence semantics, and webhook payloads

### Known limitations
- Redis Cluster (sharded) is not supported; use a single Redis endpoint
- No SSL termination built in (put a reverse proxy in front)
- No rate limiting or connection caps
- No batch events endpoint
