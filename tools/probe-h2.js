// Проверка HTTP/2 (как в браузере) при работающем системном обходе
const http2 = require('http2');
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

function probe(domain) {
  return new Promise((resolve) => {
    let done = false;
    const fin = (r) => { if (!done) { done = true; resolve(r); } };
    const t0 = Date.now();
    let client;
    try {
      client = http2.connect('https://' + domain + ':443', {
        rejectUnauthorized: false, servername: domain, ALPNProtocols: ['h2'],
      });
    } catch (e) { return fin({ err: e.code || e.message }); }
    const timer = setTimeout(() => { try { client.destroy(); } catch {} fin({ err: 'TIMEOUT' }); }, 12000);
    client.on('error', (e) => { clearTimeout(timer); fin({ err: e.code || e.message }); });
    client.on('connect', () => {
      const req = client.request({ ':path': '/', ':method': 'GET', 'user-agent': UA, accept: 'text/html,*/*' });
      let status = 0, bytes = 0;
      req.on('response', (h) => { status = h[':status']; });
      req.on('data', (c) => { bytes += c.length; });
      req.on('end', () => { clearTimeout(timer); try { client.close(); } catch {} fin({ status, bytes }); });
      req.on('error', (e) => { clearTimeout(timer); try { client.destroy(); } catch {} fin({ status, bytes, err: e.code || e.message }); });
      req.end();
    });
  });
}

(async () => {
  const domains = process.argv.slice(2);
  for (const d of (domains.length ? domains : ['discord.com', 'rutracker.org', 'www.youtube.com'])) {
    const r = await probe(d);
    const ok = r.status >= 200 && r.status < 400;
    console.log(`  ${d.padEnd(22)} h2: ${ok ? 'OK ' + r.status : 'FAIL ' + (r.err || r.status)} ${r.bytes || 0}б (${Date.now() - 0}ms)`);
  }
})();
