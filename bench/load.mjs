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

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith('--')) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith('--') ? all[i + 1] : 'true']);
  return acc;
}, []));
if (args.help) {
  console.log('Options: --host --port --tls --key --app-id --secret --connections --channels --rate --duration --ramp --metrics-url --metrics-token');
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
const httpBase = `${tls ? 'https' : 'http'}://${host}:${port}`;

const stats = {
  connected: 0, connectFailed: 0, closedEarly: 0, subscribed: 0,
  sent: 0, sendFailed: 0, rateLimited: 0, expected: 0, received: 0, latencies: [],
};

async function trigger(channel, id) {
  const body = JSON.stringify({ name: 'bench', channels: [channel], data: JSON.stringify({ id, t: performance.timeOrigin + performance.now() }) });
  const params = {
    auth_key: key, auth_timestamp: String(Math.floor(Date.now() / 1000)), auth_version: '1.0',
    body_md5: crypto.createHash('md5').update(body).digest('hex'),
  };
  const query = Object.keys(params).sort().map((k) => `${k}=${params[k]}`).join('&');
  const path = `/apps/${appId}/events`;
  const sig = crypto.createHmac('sha256', secret).update(`POST\n${path}\n${query}`).digest('hex');
  const res = await fetch(`${httpBase}${path}?${query}&auth_signature=${sig}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body });
  return res.status;
}

const subscribersPerChannel = new Array(CHANNELS).fill(0);
let phase = 'ramping';

function openConnection(i) {
  const channel = `bench-${i % CHANNELS}`;
  return new Promise((resolve) => {
    const ws = new WebSocket(`${tls ? 'wss' : 'ws'}://${host}:${port}/app/${key}?protocol=7`);
    let done = false;
    const finish = () => { if (!done) { done = true; resolve(); } };
    ws.onopen = () => { stats.connected++; };
    ws.onerror = () => { if (!done) stats.connectFailed++; finish(); };
    ws.onclose = () => { if (phase !== 'done' && stats.connected > 0) stats.closedEarly++; finish(); };
    ws.onmessage = ({ data }) => {
      const msg = JSON.parse(data);
      if (msg.event === 'pusher:connection_established') {
        ws.send(JSON.stringify({ event: 'pusher:subscribe', data: { channel } }));
      } else if (msg.event === 'pusher_internal:subscription_succeeded') {
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

console.log(`Connecting ${N} clients to ${host}:${port} (${RAMP}/s) across ${CHANNELS} channels...`);
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
console.log(`Sending ${RATE} events/s for ${DURATION} s...`);
const start = Date.now();
let seq = 0;
const interval = 1000 / RATE;
let next = start;
const inflight = new Set();
while (Date.now() - start < DURATION * 1000) {
  const ch = Math.floor(Math.random() * CHANNELS);
  stats.expected += subscribersPerChannel[ch];
  stats.sent++;
  const p = trigger(`bench-${ch}`, seq++).then((s) => { if (s === 429) stats.rateLimited++; else if (s !== 200) stats.sendFailed++; }, () => { stats.sendFailed++; });
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
console.log(`connections:        ${stats.subscribed}/${N} subscribed, ${stats.connectFailed} failed, ${stats.closedEarly} dropped during the test`);
console.log(`events sent:        ${stats.sent} (${(stats.sent / secs).toFixed(0)}/s), ${stats.sendFailed} failed, ${stats.rateLimited} rate limited (429)`);
console.log(`messages delivered: ${stats.received} of ${stats.expected} expected (${stats.expected ? ((100 * stats.received) / stats.expected).toFixed(2) : 'n/a'}%)`);
console.log(`delivery rate:      ${(stats.received / secs).toFixed(0)} messages/s received across all clients`);
console.log(`latency (ms):       p50 ${fmt(pct(stats.latencies, 50))}  p95 ${fmt(pct(stats.latencies, 95))}  p99 ${fmt(pct(stats.latencies, 99))}  max ${fmt(stats.latencies.at(-1))}`);
await metrics();
process.exit(0);
