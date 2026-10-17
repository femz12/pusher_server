# Capacity planning

How much can one server carry, and what limits you first? This guide explains what a
connection and an event cost, gives measured numbers, and works through an 8 GB
example. Use it to pick a machine size, then confirm with the
[load test](load-testing.md) on your own hardware.

> **About the numbers.** They were measured on one small Linux container (2 vCPU, 8 GB,
> Erlang/OTP 25, a development build) with the load generator on the same machine. A
> release build on current Erlang and dedicated cores will do at least as well, but treat
> every figure as a starting point, not a promise. Repeat the measurement on your setup:
> it takes a few minutes.

## What things cost

### A connection

One WebSocket connection is **one Erlang process** (it holds the socket and runs the
protocol) plus a small entry in the channel registry for each channel it joins. Erlang
processes are very cheap to create and schedule, which is why this kind of server can
hold tens of thousands of them.

The VM allows over a million processes by default (OTP 26 and newer, which the Docker
image uses). On older Erlang the default is 262,144; raise it with
`ERL_FLAGS="+P 1000000"`.

An idle connection costs memory and a file descriptor, and almost no CPU:

| Measured | Result |
|---|---|
| Server with no connections | about 54 MB |
| 10,000 subscribed connections | about 200 MB, so **about 15 KB per connection** |
| Same, while delivering 10,000 messages/s | about 200 MB (no growth) |

Idle connections "hibernate": Erlang shrinks the process to the minimum while it waits.
Before this was added, the same 10,000 connections used about 570 MB (about 52 KB each).
Presence channels add a little per member, and busy connections briefly use more while
they handle messages, so plan with **20 to 25 KB per connection** to be safe.

### An event

A trigger (one `POST /apps/:id/events`) does three things: check the signature, find the
channel's subscribers, and send the message to each. The first two are tiny. What costs is
**delivery**: writing the message to each subscriber's socket. So think in
**messages delivered**, not events sent:

```
messages per second  =  events per second  x  subscribers on the channel
```

A message to a channel with 500 subscribers is 500 deliveries.

| Measured | Result |
|---|---|
| Server CPU per delivered message | about **20 to 35 microseconds** |

(The cost per message is higher when each event reaches few clients, because the fixed
per-event work is spread over fewer messages, and lower for large fan-out.) At 25
microseconds, one CPU core can deliver roughly **40,000 messages per second** at 100%
use. Plan to run at about half of that, so one core is comfortable up to about
**20,000 messages per second**.

### Bandwidth

Each delivered message is sent on the wire as your payload plus about 70 bytes of
protocol envelope, plus TCP/IP headers. A 200-byte payload is about 350 bytes on the
wire.

```
outgoing bandwidth  =  messages per second  x  bytes per message
```

50,000 messages per second at 350 bytes is about 17.5 MB/s, or 140 Mbit/s. On a modest
cloud instance **the network can be your limit before the CPU is.**

## What limits you first

Check these in this order. The smallest answer wins.

| Limit | Formula | Where to fix |
|---|---|---|
| **Open files** | connections + about 1,000 must fit under `ulimit -n` | [Production guide](production.md#open-file-limit-ulimit) |
| **Memory** | connections x 25 KB, plus the base, with headroom (keep under about 50% of RAM) | a bigger machine, or more nodes |
| **CPU** | messages/s x 25 us, divided by cores, kept under about 50% | more cores, or more nodes |
| **Bandwidth** | messages/s x bytes per message | a faster network, or more nodes |
| **Proxy ports** | about 28,000 connections per proxy IP to one upstream address | [Production guide](production.md#the-proxy-port-limit) |

## Worked example: an 8 GB, 4-core server

**Memory.** Use at most half of 8 GB for connections: 4 GB. At 25 KB each, that is
about **160,000 connections** before memory is the problem. Memory is rarely the
limit.

**Open files.** To allow 100,000 connections, set the limit to at least 101,000 (round up
to 131,072).

**CPU.** Four cores at about 20,000 messages per second each, with half held in reserve,
is about **80,000 messages per second**.

**Bandwidth.** 80,000 messages per second at 350 bytes is 28 MB/s, about 225 Mbit/s: fine
on a 1 Gbit link, too much for a 100 Mbit one.

So this machine's real limit depends on your traffic, not its RAM. Two shapes:

| Traffic shape | Connections | Rate | Messages/s | Result |
|---|---|---|---|---|
| Notifications: mostly idle, one small message per user per minute | 100,000 | 1,700 events/s, 1 recipient each | 1,700 | CPU idle. Limit is open files and memory (about 2.5 GB). |
| Busy chat: 10,000 users in rooms of 100, each room sending 1 message/s | 10,000 | 100 events/s, 100 recipients each | 10,000 | About 0.25 core, about 30 Mbit/s. Very comfortable. |
| Big live event: 50,000 viewers on one channel, 5 updates/s | 50,000 | 5 events/s, 50,000 recipients each | 250,000 | Over this machine's CPU and bandwidth. Needs more nodes, or fewer updates. |

The third row shows the usual trap: **fan-out multiplies**. One channel with a huge
audience costs far more than many small rooms of the same total size.

## Choosing a size

1. Estimate peak **connections**, and peak **messages per second** (events x recipients).
2. Check each limit above. Take the smallest.
3. Add headroom. Run at half of the CPU figure and well under half of the memory.
4. For high availability, run at least two nodes, each able to carry the **whole** load
   if the other fails, or three nodes each sized for half ([Multi-server](multi-server.md)).
5. Measure. Use the [load test](load-testing.md) at your real connection count and rate,
   from a different machine, through your real proxy.

## Measure your own server

```bash
# connections held, with a realistic message rate
node bench/load.mjs --connections=10000 --rate=50 --duration=60

# server memory: before connecting, and while the test runs
ps -o rss= -p <server pid>
```

Divide the memory growth by the connection count to get your bytes per connection, and
read the server CPU (`docker stats`, or `top`) while the test sends to get your cost per
message. Your numbers replace the ones in this guide.
