// Checks a running chat end to end without a browser (Node 22+):
//   node smoke-test.mjs http://localhost:3000     (standalone)
//   node smoke-test.mjs http://localhost:4000     (embedded)
// It joins the presence channel like a browser would, posts a message, and
// waits for the message to come back over the WebSocket.
const base = process.argv[2] ?? 'http://localhost:3000';
const cfg = await (await fetch(`${base}/config.json`)).json();
const host = cfg.wsHost === 'localhost' ? '127.0.0.1' : cfg.wsHost;
const ws = new WebSocket(`${cfg.forceTLS ? 'wss' : 'ws'}://${host}:${cfg.wsPort}/app/${cfg.key}?protocol=7`);
const fail = (msg) => { console.error('FAIL:', msg); process.exit(1); };
setTimeout(() => fail('timed out after 10 s'), 10_000);

ws.onerror = () => fail('could not connect to the WebSocket server');
ws.onmessage = async ({ data }) => {
  const msg = JSON.parse(data);
  if (msg.event === 'pusher:connection_established') {
    console.log('ok  connected');
    const { socket_id } = JSON.parse(msg.data);
    const auth = await fetch(`${base}/pusher/auth`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ socket_id, channel_name: 'presence-chat', username: 'smoke' }),
    });
    if (!auth.ok) fail(`auth endpoint answered ${auth.status}`);
    const { auth: sig, channel_data } = await auth.json();
    ws.send(JSON.stringify({ event: 'pusher:subscribe', data: { channel: 'presence-chat', auth: sig, channel_data } }));
  } else if (msg.event === 'pusher_internal:subscription_succeeded') {
    console.log('ok  joined presence-chat');
    const res = await fetch(`${base}/messages`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ user: 'smoke', text: 'hello from the smoke test' }),
    });
    if (!res.ok) fail(`/messages answered ${res.status}`);
  } else if (msg.event === 'message') {
    console.log('ok  received:', msg.data);
    console.log('PASS');
    process.exit(0);
  } else if (msg.event === 'pusher:error') {
    fail(msg.data);
  }
};
