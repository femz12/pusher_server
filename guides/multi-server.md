# Running several servers

One node is enough for many applications and needs no other service. Run
several nodes when you need more capacity or want to restart without
disconnecting everyone at once. They coordinate through a single Redis.

## Setup

On every node set the **same**:

- `PUSHER_APP_ID`, `PUSHER_APP_KEY`, `PUSHER_APP_SECRET`
- `PUSHER_REDIS_URL`, for example `redis://:password@redis:6379` (`rediss://` for TLS)

Put a load balancer in front. `deploy/nginx.conf` is an example and
`docker-compose.example.yml` runs two nodes, Redis and nginx together:

```bash
docker compose -f docker-compose.example.yml up --build
```

No sticky sessions are needed. A WebSocket stays on the node it connected to,
and REST calls from your backend can land on any node.

Embedded: `{PusherServer, name: MyApp.PusherServer, redis_url: "redis://localhost:6379", ...}`.

## What is shared

- An event sent to any node reaches subscribers on every node.
- Presence is shared. `member_added` / `member_removed` fire once per user for
  the whole cluster.
- `channel_occupied` / `channel_vacated` webhooks fire once cluster-wide.
- The channel info endpoint counts subscribers on all nodes, and the channel
  list (`GET /apps/:app_id/channels`) includes channels from every node.
- Rate limits, `PUSHER_MAX_CONNECTIONS` and metrics are per node, not shared.

## When things fail

| What happens | Result |
|---|---|
| Redis becomes unreachable | Every node keeps serving its own clients. Delivery between nodes pauses and resumes when Redis returns. Nothing crashes. |
| Redis restarts empty or is flushed | Running nodes write their subscriptions and presence back within about 10 seconds. Clients are not re-announced as new members. |
| A node crashes or is killed | Its heartbeat key expires (30 s); a surviving node then removes its presence and occupancy and announces `member_removed` / `channel_vacated`. Expect ghost members for roughly 30 to 40 seconds after a hard crash. |
| A node is stopped cleanly | Clients are told to reconnect, then connect to another node. |

## Things to know

- Redis holds only live, ephemeral state. It needs no persistence and stays small.
- Delivery is at-most-once. A client that is disconnected when an event is sent
  does not receive it later.
- Joining or leaving a presence channel scans that channel's members inside
  Redis. That is fine for normal presence channels (Pusher itself caps them at
  100 members) but not for huge ones.
- Redis Cluster (sharded) is not supported. Use a single endpoint: plain,
  Sentinel, or a managed primary/replica service.
- Keys are prefixed `pusher:<app_id>`, so several apps can share one Redis.

## Checking it works

Connect a client to node 1, send an event through node 2's REST endpoint, and
confirm the client receives it. Then stop a node and restart Redis and confirm
clients and presence recover.
