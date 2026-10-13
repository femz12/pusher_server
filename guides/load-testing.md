# Load testing

`bench/load.mjs` opens many WebSocket connections, sends events through the REST
API, and reports how many arrived and how fast. It needs Node 22 or newer and no
packages.

```bash
node bench/load.mjs --host 127.0.0.1 --port 6001 \
  --key app-key --app-id app-id --secret app-secret \
  --connections 2000 --channels 50 --rate 100 --duration 60
```

| Option | Default | Meaning |
|---|---|---|
| `--connections` | 1000 | WebSocket clients to open |
| `--ramp` | 200 | New connections per second |
| `--channels` | 20 | Public channels; each client joins one |
| `--rate` | 50 | Events per second sent through the REST API |
| `--duration` | 30 | Seconds to send events |
| `--tls` | off | Use `wss://` and `https://` |
| `--metrics-url`, `--metrics-token` | none | Also print the server's own `/metrics` gauges |

Example result:

```
connections:        1000/1000 subscribed, 0 failed, 0 dropped during the test
events sent:        500 (50/s), 0 failed, 0 rate limited (429)
messages delivered: 25000 of 25000 expected (100.00%)
latency (ms):       p50 2.5  p95 3.6  p99 6.4  max 18.0
```

That run was a single small machine with the load generator on the same host,
so treat it as a smoke test. Measure your own hardware.

## Reading the numbers

- **Fan-out is what costs.** Each event is delivered to every subscriber of its
  channel. `--rate 100` with 40 subscribers per channel means 4,000 messages per
  second leaving the server. To model a big room, use fewer `--channels`.
- **Delivered below 100%** means events were lost or arrived after the 2 s grace
  period. Under heavy load that is the first sign you are past capacity.
- **Latency percentiles** matter more than the average. Watch p99.
- **Dropped during the test** means connections closed unexpectedly. Check the
  server logs and any proxy timeouts.

## Getting a fair test

1. **Run the load generator on a different machine** from the server, or the two
   compete for the same CPU and the result is meaningless.
2. **Raise file descriptor limits.** Each connection is a file descriptor on both
   ends. On Linux run `ulimit -n 100000` in the shell that starts the generator
   (and for the server container, `--ulimit nofile=100000:100000`).
3. **Mind the port limit.** One source IP can open about 28,000 connections to a
   single destination IP and port. For more, run several generators from
   different IPs, or give the server more than one address.
4. **Test through your real path.** If production goes through Cloudflare, nginx
   or a tunnel, point the test at that path too. Proxies have their own limits.
5. **Watch the server while it runs.** `docker stats` for CPU and memory, and
   `/metrics` (with `SOCKETELX_METRICS=true`) for `socketelx_connections`.
6. **Ramp up.** Run 1,000, then 5,000, then 10,000, and note where latency starts
   to climb. That knee is your practical capacity per node.

## Testing several nodes

Start the nodes with a shared `SOCKETELX_REDIS_URL` (see
[Multi-server](multi-server.md)), point the generator at the load balancer, and
compare delivery percentage and latency with a single node. Cross-node delivery
goes through Redis, so latency will be slightly higher.

## Limits you may hit on purpose

`SOCKETELX_REST_RATE_LIMIT` makes the generator report 429s, and
`SOCKETELX_MAX_CONNECTIONS` makes connections fail with error 4004. That is a good
way to confirm the safety valves work before you rely on them.
