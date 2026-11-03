// Проверка путей, которые использует голос Discord:
//  1) HTTPS API сигнализации (voice/regions, gateway)
//  2) WebSocket voice-шлюз (wss://gateway.discord.gg) - по нему идёт voice state/update
//  3) UDP-медиапуть: STUN binding (NAT traversal, тот же класс, что и discord_ip_discovery)
//  4) UDP-доступность диапазонов портов голоса Discord (50000-50099, 19294-19344)
const dgram = require('dgram');
const crypto = require('crypto');
const https = require('https');

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const VOICE_UDP_PORTS = [50000, 50050, 19294, 19344];

function httpsGet(url, timeoutMs = 12000) {
  return new Promise((resolve) => {
    const t0 = Date.now();
    const req = https.request(url, {
      method: 'GET', headers: { 'user-agent': UA, accept: 'application/json' },
      rejectUnauthorized: false,
    }, (res) => {
      let bytes = 0;
      res.on('data', (c) => { bytes += c.length; });
      res.on('end', () => resolve({ status: res.statusCode, bytes, ms: Date.now() - t0 }));
    });
    req.setTimeout(timeoutMs, () => { req.destroy(); resolve({ err: 'TIMEOUT', ms: Date.now() - t0 }); });
    req.on('error', (e) => resolve({ err: e.code || e.message, ms: Date.now() - t0 }));
    req.end();
  });
}

// WSS voice-шлюз: ждём Hello (op=10)
function wssHello(url, timeoutMs = 12000) {
  return new Promise((resolve) => {
    const t0 = Date.now();
    let done = false;
    const fin = (r) => { if (!done) { done = true; resolve({ ...r, ms: Date.now() - t0 }); } };
    let ws;
    try { ws = new WebSocket(url); } catch (e) { return fin({ err: String(e.message || e) }); }
    const timer = setTimeout(() => { try { ws.close(); } catch {} fin({ err: 'TIMEOUT' }); }, timeoutMs);
    ws.onopen = () => {
      ws.onmessage = (ev) => {
        clearTimeout(timer);
        try { ws.close(); } catch {}
        try {
          const msg = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data));
          fin({ op: msg.op, hasHeartbeat: !!(msg.d && msg.d.heartbeat_interval) });
        } catch { fin({ err: 'BAD_JSON' }); }
      };
    };
    ws.onerror = () => { clearTimeout(timer); fin({ err: 'WS_ERROR' }); };
    ws.onclose = () => { clearTimeout(timer); fin({ err: 'WS_CLOSED' }); };
  });
}

// STUN binding request -> ожидаем Binding Success (0x0101)
function stunBinding(host, port, timeoutMs = 8000) {
  return new Promise((resolve) => {
    const t0 = Date.now();
    let done = false;
    const fin = (r) => { if (!done) { done = true; try { sock.close(); } catch {} resolve({ ...r, ms: Date.now() - t0 }); } };
    const sock = dgram.createSocket('udp4');
    const timer = setTimeout(() => fin({ err: 'TIMEOUT' }), timeoutMs);
    sock.on('error', (e) => { clearTimeout(timer); fin({ err: e.code || e.message }); });
    sock.on('message', (msg) => {
      clearTimeout(timer);
      if (msg.length >= 20) {
        const type = msg.readUInt16BE(0);
        const mapped = type === 0x0101 || type === 0x0111;
        fin({ type: '0x' + type.toString(16).padStart(4, '0'), mapped, bytes: msg.length });
      } else {
        fin({ type: 'short', bytes: msg.length });
      }
    });
    const txid = crypto.randomBytes(12);
    const pkt = Buffer.alloc(20);
    pkt.writeUInt16BE(0x0001, 0);      // Binding Request
    pkt.writeUInt16BE(0x0000, 2);      // length
    pkt.writeUInt32BE(0x2112A442, 4);  // magic cookie
    txid.copy(pkt, 8);
    sock.send(pkt, 0, pkt.length, port, host, (e) => { if (e) { clearTimeout(timer); fin({ err: e.code || e.message }); } });
  });
}

// Отправляем Discord IP-discovery (74 байта, 0x00010046) и слушаем ответ.
// Такой пакет шлёт сам клиент Discord при подключении к голосовому серверу.
function discordIpDiscovery(host, port, timeoutMs = 6000) {
  return new Promise((resolve) => {
    const t0 = Date.now();
    let done = false;
    const fin = (r) => { if (!done) { done = true; try { sock.close(); } catch {} resolve({ ...r, ms: Date.now() - t0 }); } };
    const sock = dgram.createSocket('udp4');
    const timer = setTimeout(() => fin({ err: 'NO_REPLY' }), timeoutMs);
    sock.on('error', (e) => { clearTimeout(timer); fin({ err: e.code || e.message }); });
    sock.on('message', (msg) => {
      clearTimeout(timer);
      fin({ reply: msg.length, hex: msg.subarray(0, 8).toString('hex') });
    });
    const pkt = Buffer.alloc(74);
    pkt.writeUInt16BE(0x0001, 0);
    pkt.writeUInt16BE(0x0046, 2);
    pkt.writeUInt16BE(0x0000, 4);   // ssid
    pkt.writeUInt32BE(0x00000000, 8 + 4);
    sock.send(pkt, 0, pkt.length, port, host, (e) => { if (e) { clearTimeout(timer); fin({ err: e.code || e.message }); } });
  });
}

(async () => {
  console.log('=== 1) HTTPS сигнализация (TCP/443, HTTP/2) ===');
  for (const u of ['https://discord.com/api/v9/gateway', 'https://discord.com/api/v9/voice/regions']) {
    const r = await httpsGet(u);
    const ok = r.status >= 200 && r.status < 500;
    console.log(`  ${u.replace('https://discord.com', '').padEnd(28)} ${ok ? 'OK ' + r.status : 'FAIL ' + (r.err || r.status)} ${r.bytes || 0}б`);
  }

  console.log('=== 2) WebSocket voice-шлюз (WSS, TCP/443) ===');
  const w = await wssHello('wss://gateway.discord.gg/?v=10&encoding=json');
  console.log(`  gateway.discord.gg           ${w.op === 10 ? 'OK Hello(op=10), heartbeat=' + w.hasHeartbeat : 'FAIL ' + (w.err || ('op=' + w.op))}`);

  console.log('=== 3) UDP-медиапуть: STUN binding (NAT traversal) ===');
  for (const [h, p] of [['stun.l.google.com', 19302], ['stun.cloudflare.com', 3478]]) {
    const s = await stunBinding(h, p);
    const ok = s.type === '0x0101' || s.type === '0x0111';
    console.log(`  ${h.padEnd(28)} ${ok ? 'OK ' + s.type + ' mapped=' + s.mapped : 'FAIL ' + (s.err || s.type)}`);
  }

  console.log('=== 4) UDP диапазоны голоса Discord (IP-discovery) ===');
  const host = 'discord.com';
  for (const p of VOICE_UDP_PORTS) {
    const d = await discordIpDiscovery(host, p);
    console.log(`  ${(host + ':' + p).padEnd(28)} ${d.reply ? 'OK ответ ' + d.reply + 'б' : (d.err || 'no reply')}`);
  }
})();
