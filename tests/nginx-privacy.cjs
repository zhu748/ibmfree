// Exercise the actual nginx templates on loopback without changing system config.
const assert = require('node:assert/strict');
const http = require('node:http');
const https = require('node:https');
const tls = require('node:tls');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');
const { setTimeout: delay } = require('node:timers/promises');

const repo = path.resolve(__dirname, '..');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ibmfree-nginx-'));
const site = path.join(root, 'site');
const wsPath = '/service/0123456789abcdef';
let child;
let backend;
let failureCode = 400;
let hits = 0;
const sockets = new Set();

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8' });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stderr || result.stdout);
}

async function freePort() {
  const server = http.createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}

function request(mode, port, uri, options = {}) {
  return new Promise((resolve, reject) => {
    const client = mode === 'direct' ? https : http;
    const req = client.request({
      host: '127.0.0.1', port, path: uri, method: options.method || 'GET',
      servername: 'edge.example.com', rejectUnauthorized: false,
      headers: { Host: 'edge.example.com', ...options.headers }, timeout: 2500,
    }, res => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', chunk => { body += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    req.on('upgrade', (res, socket) => {
      socket.destroy();
      resolve({ status: res.statusCode, headers: res.headers, body: '' });
    });
    req.on('timeout', () => req.destroy(new Error('request timed out')));
    req.on('error', reject);
    req.end();
  });
}

async function stopNginx() {
  if (!child) return;
  const current = child;
  child = undefined;
  if (current.exitCode === null && current.signalCode === null) {
    const stopped = once(current, 'exit');
    current.kill('SIGTERM');
    const timer = setTimeout(() => current.kill('SIGKILL'), 3000);
    try { await stopped; } finally { clearTimeout(timer); }
  }
}

async function checkMode(mode) {
  const port = await freePort();
  const access = path.join(root, `${mode}.access.log`);
  const error = path.join(root, `${mode}.error.log`);
  const conf = path.join(root, `${mode}.conf`);
  const values = {
    ORIGIN_PORT: port, PUBLIC_DOMAIN: 'edge.example.com', WS_PATH: wsPath,
    SING_BOX_PORT: backend.address().port, SITE_ROOT: site,
    TLS_CERT_PATH: path.join(root, 'cert.pem'), TLS_KEY_PATH: path.join(root, 'key.pem'),
  };
  let template = fs.readFileSync(path.join(repo, 'templates', `nginx-${mode}.conf.tpl`), 'utf8')
    .replace(/\{\{([A-Z_]+)\}\}/g, (_, key) => {
      assert.ok(Object.hasOwn(values, key), `unknown placeholder ${key}`);
      return values[key];
    })
    .replaceAll('/var/log/nginx/access.log', access);
  if (mode === 'direct') {
    // Only adapt public listen ports for an unprivileged, loopback-only test.
    template = template.replace(/^\s*listen \[::\]:443.*;\r?$/gm, '')
      .replace(/listen 443 /g, `listen 127.0.0.1:${port} `);
  }
  fs.writeFileSync(conf, `worker_processes 1;\npid ${root}/${mode}.pid;\n` +
    `error_log ${error} warn;\nevents { worker_connections 128; }\nhttp {\n` +
    `client_body_temp_path ${root}/client;\nproxy_temp_path ${root}/proxy;\n${template}\n}\n`, 'utf8');
  run('nginx', ['-p', root + '/', '-c', conf, '-t']);
  let stderr = '';
  child = spawn('nginx', ['-p', root + '/', '-c', conf, '-g', 'daemon off; master_process off;']);
  child.stderr.on('data', chunk => { stderr += chunk; });
  let ready = false;
  for (let attempt = 0; attempt < 30; attempt++) {
    try { ready = (await request(mode, port, '/')).status === 200; } catch { /* waiting for bind */ }
    if (ready) break;
    await delay(100);
  }
  assert.ok(ready, `nginx not ready: ${stderr}`);
  const baseline = await request(mode, port, '/missing');
  assert.equal(baseline.status, 404);
  assert.ok(!/nginx|sing-box|vmess|edge-router/i.test(baseline.body));
  const privatePaths = ['/index.html.bak.20260101', '/index.html.restore.test', '/config.json',
    '/client.txt', '/tunnel.token', '/.git/config', '/%2egit/config', '/index.html~'];
  for (const uri of [...privatePaths, wsPath]) {
    const res = await request(mode, port, uri);
    assert.equal(res.status, 404, uri);
    assert.equal(res.body, baseline.body, uri);
  }
  const wrongHost = await request(mode, port, wsPath, { headers: { Host: 'unknown.example.com' } });
  assert.equal(wrongHost.status, 404);
  assert.equal(wrongHost.body, baseline.body);
  const redirect = await request(mode, port, '/assets');
  assert.equal(redirect.status, 301);
  assert.equal(redirect.headers.location, '/assets/');
  const before = hits;
  const blocked = await request(mode, port, wsPath, { method: 'POST', headers: { Upgrade: 'websocket' } });
  assert.equal(blocked.status, 404);
  assert.equal(hits, before, 'invalid request reached backend');
  const badHeaders = { Connection: 'Upgrade', Upgrade: 'websocket' };
  for (const code of [400, 403, 404, 405, 426, 500, 502, 503, 504]) {
    failureCode = code;
    const res = await request(mode, port, wsPath, { headers: badHeaders });
    assert.equal(res.status, 404, `upstream status ${code}`);
    assert.equal(res.body, baseline.body, `upstream body ${code}`);
  }
  const valid = await request(mode, port, wsPath, { headers: { ...badHeaders,
    'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==' } });
  assert.equal(valid.status, 101, 'valid WebSocket no longer works');
  assert.equal(valid.headers['sec-websocket-accept'], 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=');
  await request(mode, port, '/missing?token=private-query-sentinel', {
    headers: { Referer: 'https://example.com/private-referrer-sentinel' },
  });
  if (mode === 'direct') {
    await new Promise((resolve, reject) => {
      const socket = tls.connect({ host: '127.0.0.1', port, servername: 'unknown.example.com',
        rejectUnauthorized: false });
      socket.once('secureConnect', () => { socket.destroy(); reject(new Error('unknown SNI accepted')); });
      socket.once('error', resolve);
      socket.setTimeout(2500, () => { socket.destroy(); reject(new Error('SNI rejection timed out')); });
    });
  }
  await stopNginx();
  const log = fs.readFileSync(access, 'utf8');
  assert.ok(log.includes('404'), 'diagnostic status log missing');
  for (const value of [wsPath, 'private-query-sentinel', 'private-referrer-sentinel']) {
    assert.ok(!log.includes(value), `access log contains ${value}`);
  }
  console.log(`PASS real nginx ${mode}: private files, uniform 404, relative redirects, access-log privacy, WebSocket 101`);
}

(async () => {
  try {
    fs.mkdirSync(path.join(root, 'logs'));
    fs.mkdirSync(path.join(site, 'assets'), { recursive: true });
    fs.mkdirSync(path.join(site, '.git'));
    fs.writeFileSync(path.join(site, 'index.html'), '<html>fixture site</html>', 'utf8');
    for (const name of ['index.html.bak.20260101', 'index.html.restore.test', 'config.json',
      'client.txt', 'tunnel.token', 'index.html~', '.git/config']) {
      fs.writeFileSync(path.join(site, name), 'private-content-sentinel', 'utf8');
    }
    run('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
      '-subj', '/CN=edge.example.com', '-keyout', path.join(root, 'key.pem'), '-out', path.join(root, 'cert.pem')]);
    backend = http.createServer((req, res) => { hits++; res.writeHead(failureCode); res.end('backend-detail-sentinel'); });
    backend.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
    backend.on('upgrade', (req, socket) => {
      hits++;
      if (!req.headers['sec-websocket-key']) {
        socket.end(`HTTP/1.1 ${failureCode} Failure\r\nContent-Length: 23\r\n\r\nbackend-detail-sentinel`);
        return;
      }
      const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] +
        '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
      socket.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n' +
        `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
    });
    backend.listen(0, '127.0.0.1');
    await once(backend, 'listening');
    await checkMode('tunnel');
    await checkMode('direct');
  } catch (error) {
    console.error(error);
    process.exitCode = 1;
  } finally {
    await stopNginx();
    for (const socket of sockets) socket.destroy();
    if (backend) await new Promise(resolve => backend.close(resolve));
    // Only remove the exact private directory created by this test.
    fs.rmSync(root, { recursive: true, force: true });
  }
})();
