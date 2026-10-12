# Changelog

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/), versioning
follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `POST /apps/:app_id/batch_events` (up to 10 events per request) and
  `GET /apps/:app_id/channels` (with `filter_by_prefix` and
  `info=user_count`), both working across nodes with Redis.
- The Docker workflow can also publish to Docker Hub, and tags `0.1.0`, `0.1` and `latest`.
- `PUSHER_BATCH_LIMIT` (default 10) sets the `batch_events` size limit.
- Webhook retries with exponential backoff (`PUSHER_WEBHOOK_RETRIES`,
  default 3). 5xx, 408, 429 and network errors are retried; other 4xx are not.
- Optional limits, all off by default: `PUSHER_REST_RATE_LIMIT`,
  `PUSHER_CLIENT_EVENT_RATE_LIMIT`, `PUSHER_MAX_CONNECTIONS`.
- Optional Prometheus metrics at `GET /metrics` (`PUSHER_METRICS`,
  `PUSHER_METRICS_TOKEN`).
- Multi-server mode: set `PUSHER_REDIS_URL` (or the `:redis_url` option) and
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
