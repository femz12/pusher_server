// A tiny chat backend with no dependencies (Node 18+).
// It does three things: serves the page, authorizes presence-channel joins,
// and sends chat messages to the Pusher-protocol server over its REST API.
import http from 'node:http';
import crypto from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const env = process.env;
const APP_ID = env.SOCKETELX_APP_ID ?? 'chat';
const APP_KEY = env.SOCKETELX_APP_KEY ?? 'chat-key';
const APP_SECRET = env.SOCKETELX_APP_SECRET ?? 'change-me-please';
const SOCKETELX_URL = env.SOCKETELX_URL ?? 'http://127.0.0.1:6001';   // where this backend reaches the server
const PUBLIC_WS_PORT = Number(env.PUBLIC_WS_PORT ?? 6001);       // where browsers reach it
const PUBLIC_WS_HOST = env.PUBLIC_WS_HOST;                       // default: the host the page was opened on
const FORCE_TLS = env.PUBLIC_WS_TLS === 'true';
const PORT = Number(env.PORT ?? 3000);
const CHANNEL = 'presence-chat';

const hmac = (s) => crypto.createHmac('sha256', APP_SECRET).update(s).digest('hex');

// Send an event the way any Pusher server SDK does: a signed POST to /apps/:id/events.
async function trigger(channel, event, data) {
  const body = JSON.stringify({ name: event, channels: [channel], data: JSON.stringify(data) });
  const params = {
    auth_key: APP_KEY,
    auth_timestamp: String(Math.floor(Date.now() / 1000)),
    auth_version: '1.0',
    body_md5: crypto.createHash('md5').update(body).digest('hex'),
  };
  const query = Object.keys(params).sort().map((k) => `${k}=${params[k]}`).join('&');
  const apiPath = `/apps/${APP_ID}/events`;
  const signature = hmac(`POST\n${apiPath}\n${query}`);
  const res = await fetch(`${SOCKETELX_URL}${apiPath}?${query}&auth_signature=${signature}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body,
  });
  if (!res.ok) throw new Error(`pusher server answered ${res.status}`);
}

const readBody = async (req) => { let s = ''; for await (const c of req) s += c; return s; };
const json = (res, code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://x');

    if (req.method === 'GET' && url.pathname === '/') {
      const dir = path.dirname(fileURLToPath(import.meta.url));
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      return res.end(await readFile(path.join(dir, 'public', 'index.html')));
    }

    if (req.method === 'GET' && url.pathname === '/config.json') {
      const host = PUBLIC_WS_HOST ?? (req.headers.host ?? 'localhost').split(':')[0];
      return json(res, 200, { key: APP_KEY, wsHost: host, wsPort: PUBLIC_WS_PORT, forceTLS: FORCE_TLS });
    }

    // pusher-js calls this when joining a private or presence channel.
    // In a real app, check your session or token here before signing.
    if (req.method === 'POST' && url.pathname === '/pusher/auth') {
      const form = new URLSearchParams(await readBody(req));
      const socketId = form.get('socket_id');
      const channel = form.get('channel_name');
      const username = (form.get('username') ?? '').trim().slice(0, 32);
      if (!socketId || channel !== CHANNEL || !username) return json(res, 403, { error: 'forbidden' });
      const channelData = JSON.stringify({ user_id: username, user_info: { name: username } });
      return json(res, 200, { auth: `${APP_KEY}:${hmac(`${socketId}:${channel}:${channelData}`)}`, channel_data: channelData });
    }

    if (req.method === 'POST' && url.pathname === '/messages') {
      const { user, text } = JSON.parse(await readBody(req));
      if (typeof user !== 'string' || typeof text !== 'string' || !text.trim() || text.length > 500) return json(res, 400, { error: 'bad message' });
      await trigger(CHANNEL, 'message', { user: user.slice(0, 32), text, at: Date.now() });
      res.writeHead(204); return res.end();
    }

    json(res, 404, { error: 'not found' });
  } catch (err) {
    console.error(err);
    json(res, 500, { error: 'server error' });
  }
});

server.listen(PORT, () => console.log(`chat backend on http://localhost:${PORT} (pusher server: ${SOCKETELX_URL})`));
