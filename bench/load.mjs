#!/usr/bin/env node
// Load test for a Pusher-protocol server. No dependencies; needs Node 22+.
//
//   node bench/load.mjs --host 127.0.0.1 --port 6001 --key app-key \
//        --app-id app-id --secret app-secret \
//        --connections 2000 --channels 50 --rate 100 --duration 60
//
// What it does:
//   1. opens --connections WebSocket connections (--ramp new ones per second)
//      and subscribes each to one of --channels public channels,
//   2. sends --rate events per second through the REST API, each to a random
//      channel, for --duration seconds,
//   3. measures how long each event takes to reach each subscriber, and how
//      many were lost.
// Latency is stamped and measured by this script, so it is valid even when
// the server is on another machine (no clock sync needed).
import crypto from 'node:crypto';

const KNOWN = ['host', 'port', 'tls', 'key', 'app-id', 'secret', 'connections', 'channels', 'rate', 'duration', 'ramp', 'targets', 'metrics-url', 'metrics-token', 'no-preflight', 'no-ping', 'help'];

// Accepts both `--connections 5000` and `--connections=5000`; a bare `--tls` means true.
const args = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (!a.startsWith('--')) { console.error(`Unexpected argument "${a}". Try --help.`); process.exit(1); }
  const eq = a.indexOf('=');
  const name = eq === -1 ? a.slice(2) : a.slice(2, eq);
  if (!KNOWN.includes(name)) { console.error(`Unknown option --${name}. Try --help.`); process.exit(1); }
  if (eq !== -1) args[name] = a.slice(eq + 1);
  else if (argv[i + 1] !== undefined && !argv[i + 1].startsWith('--')) args[name] = argv[++i];
  else args[name] = 'true';
}
if (args.help) {
  console.log(`Options: ${KNOWN.filter((k) => k !== 'help').map((k) => '--' + k).join(' ')}`);
  process.exit(0);
}
const host = args.host ?? '127.0.0.1';
const port = Number(args.port ?? 6001);
const tls = args.tls === 'true';
const key = args.key ?? 'app-key';
const appId = args['app-id'] ?? 'app-id';
const secret = args.secret ?? 'app-secret';
const N = Number(args.connections ?? 1000);
const CHANNELS = Number(args.channels ?? 20);
const RATE = Number(args.rate ?? 50);
const DURATION = Number(args.duration ?? 30);
const RAMP = Number(args.ramp ?? 200);
// One or more servers. With several (--targets a:6001,b:6001), connection i goes to
// server i mod N and events are published through the servers in turn, so most
// deliveries have to cross from one node to another: this is the multi-node test.
const targets = (args.targets ?? `${host}:${port}`).split(',').map((t) => {
  const [h, p] = t.trim().split(':');
  return { host: h, port: Number(p ?? 6001), http: `${tls ? 'https' : 'http'}://${h}:${p ?? 6001}`, connected: 0 };
});
const httpBase = targets[0].http;

const stats = {
  connected: 0, connectFailed: 0, closedEarly: 0, subscribed: 0,
  sent: 0, sendFailed: 0, rateLimited: 0, expected: 0, received: 0, latencies: [],
  failReasons: {}, connectReasons: {},
};

async function trigger(channel, id, target = targets[0]) {
  const body = JSON.stringify({ name: 'bench', channels: [channel], data: JSON.stringify({ id, t: performance.timeOrigin + performance.now() }) });
  const params = {
    auth_key: key, auth_timestamp: String(Math.floor(Date.now() / 1000)), auth_version: '1.0',
    body_md5: crypto.createHash('md5').update(body).digest('hex'),
  };
  const query = Object.keys(params).sort().map((k) => `${k}=${params[k]}`).join('&');
  const path = `/apps/${appId}/events`;
  const sig = crypto.createHmac('sha256', secret).update(`POST\n${path}\n${query}`).digest('hex');
  const res = await fetch(`${target.http}${path}?${query}&auth_signature=${sig}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body });
  if (res.status !== 200 && res.status !== 429) {
    // keep the first few reasons so a wrong secret or app id is obvious
    const text = (await res.text()).slice(0, 200);
    const k = `HTTP ${res.status} ${text}`;
    stats.failReasons[k] = (stats.failReasons[k] ?? 0) + 1;
  }
  return res.status;
}

const subscribersPerChannel = new Array(CHANNELS).fill(0);
let phase = 'ramping';

function openConnection(i) {
  const channel = `bench-${i % CHANNELS}`;
  return new Promise((resolve) => {
    let pinger;
    let subscribed = false;
    const target = targets[i % targets.length];
    const ws = new WebSocket(`${tls ? 'wss' : 'ws'}://${target.host}:${target.port}/app/${key}?protocol=7`);
    let done = false;
    const finish = () => { if (!done) { done = true; resolve(); } };
    ws.onopen = () => { stats.connected++; };
    ws.onerror = (e) => {
      if (!done) {
        stats.connectFailed++;
        const k = String(e?.message ?? e?.error?.message ?? 'connection error');
        stats.connectReasons[k] = (stats.connectReasons[k] ?? 0) + 1;
      }
      finish();
    };
    ws.onclose = () => {
      clearInterval(pinger);
      if (phase !== 'done' && stats.connected > 0) stats.closedEarly++;
      // a dropped client no longer counts towards the deliveries we expect
      if (subscribed && phase !== 'done') subscribersPerChannel[i % CHANNELS]--;
      finish();
    };
    ws.onmessage = ({ data }) => {
      const msg = JSON.parse(data);
      if (msg.event === 'pusher:error') {
        const k = `server error ${msg.data?.code ?? ''} ${msg.data?.message ?? JSON.stringify(msg.data)}`;
        stats.connectReasons[k] = (stats.connectReasons[k] ?? 0) + 1;
      } else if (msg.event === 'pusher:connection_established') {
        ws.send(JSON.stringify({ event: 'pusher:subscribe', data: { channel } }));
        // Real clients (pusher-js) ping when the connection is quiet; the server
        // closes sockets that stay silent for twice the advertised activity timeout.
        if (args['no-ping'] !== 'true') {
          const every = (JSON.parse(msg.data).activity_timeout ?? 30) * 1000;
          pinger = setInterval(() => ws.readyState === 1 && ws.send('{"event":"pusher:ping","data":{}}'), every);
        }
      } else if (msg.event === 'pusher_internal:subscription_succeeded') {
        subscribed = true;
        target.connected++;
        stats.subscribed++; subscribersPerChannel[i % CHANNELS]++; finish();
      } else if (msg.event === 'bench') {
        stats.received++;
        stats.latencies.push(performance.timeOrigin + performance.now() - JSON.parse(msg.data).t);
      }
    };
  });
}

const pct = (arr, p) => (arr.length ? arr[Math.min(arr.length - 1, Math.floor((p / 100) * arr.length))] : NaN);
const fmt = (n) => (Number.isFinite(n) ? n.toFixed(1) : 'n/a');

async function metrics() {
  if (!args['metrics-url']) return;
  const res = await fetch(args['metrics-url'], { headers: args['metrics-token'] ? { Authorization: `Bearer ${args['metrics-token']}` } : {} });
  const text = await res.text();
  const line = (n) => text.split('\n').find((l) => l.startsWith(n + ' '));
  console.log('server metrics:', ['socketelx_connections', 'socketelx_channels', 'socketelx_events_triggered_total'].map(line).join(' | '));
}

// One signed event before the ramp: a wrong key, app id or secret shows up
// here as a clear message instead of thousands of silent failures later.
if (args['no-preflight'] !== 'true') {
  for (const target of targets) {
    try {
      const status = await trigger('bench-preflight', -1, target);
      if (status !== 200) {
        console.error(`Preflight failed: ${target.http} answered HTTP ${status} to a signed event.`);
        console.error(Object.keys(stats.failReasons).join('\n') || '(no body)');
        console.error('Check --key, --app-id and --secret (and the address). Use --no-preflight to skip this check.');
        process.exit(1);
      }
      stats.failReasons = {};
    } catch (e) {
      console.error(`Preflight failed: could not reach ${target.http} (${e.cause?.code ?? e.message}).`);
      process.exit(1);
    }
  }
}

console.log(`Connecting ${N} clients to ${targets.map((t) => `${t.host}:${t.port}`).join(', ')} (${RAMP}/s) across ${CHANNELS} channels...`);
const t0 = Date.now();
const pending = [];
for (let i = 0; i < N; i++) {
  pending.push(openConnection(i));
  if ((i + 1) % RAMP === 0) {
    await new Promise((r) => setTimeout(r, 1000));
    process.stdout.write(`\r  ${stats.subscribed}/${N} subscribed, ${stats.connectFailed} failed`);
  }
}
await Promise.all(pending);
console.log(`\r  ${stats.subscribed}/${N} subscribed, ${stats.connectFailed} failed, in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
await metrics();

phase = 'sending';
const fanout = RATE * (stats.subscribed / CHANNELS);
console.log(`Sending ${RATE} events/s for ${DURATION} s... (each event reaches ~${Math.round(stats.subscribed / CHANNELS)} clients, so ~${Math.round(fanout)} messages/s to receive)`);
if (fanout > 50000) console.log('  Note: this script is one Node process; above ~50k messages/s it may become the bottleneck, not the server.');
const start = Date.now();
let seq = 0;
const interval = 1000 / RATE;
let next = start;
const inflight = new Set();
while (Date.now() - start < DURATION * 1000) {
  const ch = Math.floor(Math.random() * CHANNELS);
  stats.expected += subscribersPerChannel[ch];
  stats.sent++;
  const p = trigger(`bench-${ch}`, seq, targets[seq++ % targets.length]).then((s) => { if (s === 429) stats.rateLimited++; else if (s !== 200) stats.sendFailed++; }, (e) => {
    stats.sendFailed++;
    const k = `request error ${e?.cause?.code ?? e?.cause?.message ?? e?.message ?? e}`;
    stats.failReasons[k] = (stats.failReasons[k] ?? 0) + 1;
  });
  inflight.add(p); p.finally(() => inflight.delete(p));
  next += interval;
  const wait = next - Date.now();
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  if (seq % Math.max(1, Math.round(RATE)) === 0) process.stdout.write(`\r  sent ${stats.sent}, received ${stats.received}`);
}
const secs = (Date.now() - start) / 1000;
await Promise.all(inflight);
await new Promise((r) => setTimeout(r, 2000)); // let the last events arrive
phase = 'done';

stats.latencies.sort((a, b) => a - b);
console.log('\n--- result ---');
if (stats.connectFailed > 0 || stats.closedEarly > 0) {
  console.log('  Some connections failed. Before blaming the server, check the open-file limit of BOTH');
  console.log('  terminals (server and this script): run `ulimit -n`. Each connection needs one file');
  console.log('  descriptor, and macOS/Linux often allow only 256-1024. Raise it with `ulimit -n 65536`.');
}
for (const [k, n] of Object.entries(stats.connectReasons)) console.log(`  connection problem x${n}: ${k}`);
for (const [k, n] of Object.entries(stats.failReasons)) console.log(`  send problem x${n}: ${k}`);
if (targets.length > 1) console.log(`per server:         ${targets.map((t) => `${t.host}:${t.port}=${t.connected}`).join('  ')} (events are published through each server in turn)`);
console.log(`connections:        ${stats.subscribed}/${N} subscribed, ${stats.connectFailed} failed, ${stats.closedEarly} dropped during the test`);
console.log(`events sent:        ${stats.sent} (${(stats.sent / secs).toFixed(0)}/s), ${stats.sendFailed} failed, ${stats.rateLimited} rate limited (429)`);
console.log(`messages delivered: ${stats.received} of ${stats.expected} expected (${stats.expected ? ((100 * stats.received) / stats.expected).toFixed(2) : 'n/a'}%)`);
console.log(`delivery rate:      ${(stats.received / secs).toFixed(0)} messages/s received across all clients`);
console.log(`latency (ms):       p50 ${fmt(pct(stats.latencies, 50))}  p95 ${fmt(pct(stats.latencies, 95))}  p99 ${fmt(pct(stats.latencies, 99))}  max ${fmt(stats.latencies.at(-1))}`);
await metrics();
process.exit(0);
