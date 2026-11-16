// Проверка HTTP/2 (как в браузере) при работающем системном обходе.
//
// Использование:
//   node tools/probe-h2.js [домен ...]
//   node tools/probe-h2.js --strict discord.com    # ненулевой выход при FAIL
//   node tools/probe-h2.js --verify-tls discord.com # проверять сертификат
//
// По умолчанию сертификат не проверяется (rejectUnauthorized:false): цель
// пробы - увидеть, проходит ли ответ через DPI, а на обходе цепочка может
// быть ещё не прогрета. --verify-tls включает строгую проверку.
const http2 = require('http2');
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

const args = process.argv.slice(2);
const strict = args.includes('--strict');
const verifyTls = args.includes('--verify-tls');
const domains = args.filter((a) => !a.startsWith('--'));

function probe(domain) {
  return new Promise((resolve) => {
    let done = false;
    const fin = (r) => { if (!done) { done = true; resolve(r); } };
    const t0 = Date.now();
    let client;
    try {
      client = http2.connect('https://' + domain + ':443', {
        rejectUnauthorized: verifyTls, servername: domain, ALPNProtocols: ['h2'],
      });
    } catch (e) { return fin({ err: e.code || e.message, ms: Date.now() - t0 }); }
    const timer = setTimeout(() => { try { client.destroy(); } catch {} fin({ err: 'TIMEOUT', ms: Date.now() - t0 }); }, 12000);
    client.on('error', (e) => { clearTimeout(timer); fin({ err: e.code || e.message, ms: Date.now() - t0 }); });
    client.on('connect', () => {
      const req = client.request({ ':path': '/', ':method': 'GET', 'user-agent': UA, accept: 'text/html,*/*' });
      let status = 0, bytes = 0;
      req.on('response', (h) => { status = h[':status']; });
      req.on('data', (c) => { bytes += c.length; });
      req.on('end', () => { clearTimeout(timer); try { client.close(); } catch {} fin({ status, bytes, ms: Date.now() - t0 }); });
      req.on('error', (e) => { clearTimeout(timer); try { client.destroy(); } catch {} fin({ status, bytes, err: e.code || e.message, ms: Date.now() - t0 }); });
      req.end();
    });
  });
}

(async () => {
  let failed = 0;
  for (const d of (domains.length ? domains : ['discord.com', 'rutracker.org', 'www.youtube.com'])) {
    const r = await probe(d);
    const ok = r.status >= 200 && r.status < 400;
    if (!ok) failed++;
    // Длительность считается от старта запроса, а не «текущее время в мс».
    console.log(`  ${d.padEnd(22)} h2: ${ok ? 'OK ' + r.status : 'FAIL ' + (r.err || r.status)} ${r.bytes || 0}б (${r.ms}ms)`);
  }
  if (strict && failed) process.exitCode = 1;
})();
