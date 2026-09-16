// Real VMess TCP traffic through production nginx/server templates, on loopback only.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { execFile, spawn } = require('node:child_process');
const { once } = require('node:events');
const { promisify } = require('node:util');
const { setTimeout: delay } = require('node:timers/promises');
const execute = promisify(execFile);

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ibmfree-vmess-'));
const children = new Set();
const commands = new Set();
const reservedPorts = new Set();
const payload = crypto.randomBytes(1024 * 1024);
const payloadHash = hash(payload);
const targetSockets = new Set();
let target;
let targetHits = 0;
let uploadedBytes = 0;
let binary;
let link;
let cleanupPromise;

function hash(data) { return crypto.createHash('sha256').update(data).digest('hex'); }

async function run(command, args, options = {}) {
  assert.ok(!cleanupPromise, 'test is shutting down');
  const task = execute(command, args, { encoding: 'utf8', timeout: 20000, maxBuffer: 1024 * 1024, ...options });
  commands.add(task.child);
  try { return (await task).stdout; } finally { commands.delete(task.child); }
}

function start(command, args, label) {
  assert.ok(!cleanupPromise, 'test is shutting down');
  const child = spawn(command, args, { stdio: ['ignore', 'ignore', 'pipe'] });
  child.label = label;
  child.log = '';
  child.on('error', error => { child.startError = error; });
  child.stderr.on('data', data => { child.log = (child.log + data.toString('utf8')).slice(-16000); });
  children.add(child);
  return child;
}

async function stop(child) {
  if (!child) return;
  if (child.pid && child.exitCode === null && child.signalCode === null) {
    const exited = once(child, 'exit');
    child.kill('SIGTERM');
    const timer = setTimeout(() => child.kill('SIGKILL'), 3000);
    try { await exited; } finally { clearTimeout(timer); }
  }
  children.delete(child);
}

async function freePort() {
  for (;;) {
    const server = net.createServer();
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const port = server.address().port;
    await new Promise(resolve => server.close(resolve));
    if (!reservedPorts.has(port)) { reservedPorts.add(port); return port; }
  }
}

async function waitPort(child, port) {
  for (let attempt = 0; attempt < 40; attempt++) {
    assert.ok(!child.startError && child.exitCode === null && child.signalCode === null,
      `${child.label} exited: ${child.startError || child.log}`);
    const connected = await new Promise(resolve => {
      const socket = net.connect({ host: '127.0.0.1', port });
      socket.once('connect', () => { socket.destroy(); resolve(true); });
      socket.once('error', () => resolve(false));
      socket.setTimeout(500, () => { socket.destroy(); resolve(false); });
    });
    if (connected) return;
    await delay(100);
  }
  throw new Error(`${child.label} did not bind: ${child.log}`);
}

async function startClient(mode, originPort, variant) {
  const port = await freePort();
  const outbound = {
    type: 'vmess', tag: 'fixture-proxy', server: '127.0.0.1', server_port: originPort,
    uuid: link.id, security: link.scy, alter_id: Number(link.aid), network: 'tcp',
    transport: { type: link.net, path: link.path, headers: { Host: link.host } },
  };
  if (mode === 'direct') {
    outbound.tls = {
      enabled: true, server_name: link.sni,
      certificate_path: path.join(root, 'config/tls/origin.crt'),
      utls: { enabled: true, fingerprint: link.fp },
    };
  }
  // Tunnel exercises the HTTP origin hop; Cloudflare's public TLS is not mocked.
  if (variant === 'wrong-uuid') outbound.uuid = '22222222-2222-4222-8222-222222222222';
  if (variant === 'wrong-path') outbound.transport.path += '/incorrect';
  const config = {
    log: { level: 'warn' },
    inbounds: [{ type: 'socks', listen: '127.0.0.1', listen_port: port }],
    outbounds: [outbound], route: { final: outbound.tag },
  };
  const file = path.join(root, `${mode}-${variant}.json`);
  fs.writeFileSync(file, JSON.stringify(config), 'utf8');
  await run(binary, ['check', '-c', file]);
  const child = start(binary, ['run', '-c', file], `${mode} ${variant} client`);
  await waitPort(child, port);
  return { child, port };
}

async function transfer(port, name, upload = false) {
  const output = path.join(root, `${name}.body`);
  const args = ['--disable', '--silent', '--show-error', '--fail', '--connect-timeout', '2',
    '--max-time', '8', '--noproxy', '', '--socks5-hostname', `127.0.0.1:${port}`, '--output', output];
  if (upload) args.push('--data-binary', '@' + path.join(root, 'payload.bin'));
  args.push(`http://127.0.0.1:${target.address().port}/${name}`);
  // Even NO_PROXY=* must not let curl bypass the VMess client for loopback URLs.
  await run('curl', args, { env: { ...process.env, NO_PROXY: '*', no_proxy: '*' } });
  assert.equal(hash(fs.readFileSync(output)), payloadHash, `${name}: corrupted response`);
}

async function checkMode(mode, originPort) {
  let template = fs.readFileSync(path.join(root, `${mode}.tpl.conf`), 'utf8')
    .replaceAll('/var/log/nginx/access.log', path.join(root, `${mode}.access.log`));
  if (mode === 'direct') {
    template = template.replace(/^\s*listen \[::\]:443.*;\r?$/gm, '')
      .replace(/listen 443 /g, `listen 127.0.0.1:${originPort} `);
  }
  const conf = path.join(root, `${mode}.conf`);
  fs.writeFileSync(conf, `worker_processes 1;\npid ${root}/${mode}.pid;\n` +
    `error_log stderr warn;\nevents { worker_connections 128; }\nhttp {\n` +
    `client_body_temp_path ${root}/client;\nproxy_temp_path ${root}/proxy;\n${template}\n}\n`, 'utf8');
  await run('nginx', ['-p', root + '/', '-c', conf, '-t']);
  const nginx = start('nginx', ['-p', root + '/', '-c', conf, '-g', 'daemon off; master_process off;'], `${mode} nginx`);
  await waitPort(nginx, originPort);
  let client;
  try {
    client = await startClient(mode, originPort, 'valid');
    const hitsBefore = targetHits;
    const bytesBefore = uploadedBytes;
    await Promise.all([
      transfer(client.port, `${mode}-download-a`),
      transfer(client.port, `${mode}-download-b`),
      transfer(client.port, `${mode}-upload`, true),
    ]);
    assert.equal(targetHits - hitsBefore, 3, 'requests bypassed or retried the target');
    assert.equal(uploadedBytes - bytesBefore, payload.length, 'upload did not arrive intact');
    await stop(client.child);
    for (const variant of ['wrong-uuid', 'wrong-path']) {
      client = await startClient(mode, originPort, variant);
      const before = targetHits;
      await assert.rejects(() => transfer(client.port, `${mode}-${variant}`), error =>
        typeof error.code === 'number' && error.code !== 0 && !error.killed,
      `${variant} must fail as a curl transport/proxy error, not a fixture error`);
      assert.equal(targetHits, before, `${variant} reached target without valid authentication/path`);
      await stop(client.child);
    }
    client = await startClient(mode, originPort, 'valid-after-rejection');
    await transfer(client.port, `${mode}-recovery`);
    console.log(`PASS real VMess ${mode}: exported link, concurrent 1 MiB downloads/upload, rejected UUID/path, recovery`);
  } catch (error) {
    console.error(`${mode} nginx: ${nginx.log}`);
    if (client) console.error(`${client.child.label}: ${client.child.log}`);
    throw error;
  } finally {
    if (client) await stop(client.child);
    await stop(nginx);
  }
}

function cleanup() {
  cleanupPromise ??= (async () => {
    await Promise.all([...commands, ...children].map(stop));
    for (const socket of targetSockets) socket.destroy();
    if (target) await new Promise(resolve => target.close(resolve));
    fs.rmSync(root, { recursive: true, force: true });
  })();
  return cleanupPromise;
}

for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143]]) {
  process.once(signal, () => { cleanup().finally(() => process.exit(code)); });
}

(async () => {
  try {
    assert.equal(process.platform, 'linux', 'real VMess integration requires Linux, nginx, OpenSSL, curl and tar');
    const corePort = await freePort();
    const originPort = await freePort();
    const metadata = await run('bash', [path.join(__dirname, 'prepare-vmess.sh'), root, String(corePort), String(originPort)]);
    const [version, arch, expectedHash] = metadata.trim().split(/\s+/);
    assert.match(version, /^\d+\.\d+\.\d+$/);
    assert.ok(['amd64', 'arm64', 's390x'].includes(arch));
    assert.match(expectedHash, /^[a-f0-9]{64}$/);
    const archive = path.join(root, 'sing-box.tar.gz');
    const release = `sing-box-${version}-linux-${arch}`;
    await run('curl', ['--disable', '--fail', '--location', '--silent', '--show-error',
      '--retry', '2', '--connect-timeout', '15', '--max-time', '120', '--output', archive,
      `https://github.com/SagerNet/sing-box/releases/download/v${version}/${release}.tar.gz`], { timeout: 180000 });
    assert.equal(hash(fs.readFileSync(archive)), expectedHash, 'pinned sing-box checksum mismatch');
    await run('tar', ['-xzf', archive, '-C', root, `${release}/sing-box`]);
    binary = path.join(root, release, 'sing-box');
    await run(binary, ['check', '-c', path.join(root, 'config/config.json')]);
    const uri = fs.readFileSync(path.join(root, 'config/client.txt'), 'utf8').trim();
    assert.ok(uri.startsWith('vmess://'));
    link = JSON.parse(Buffer.from(uri.slice(8), 'base64').toString('utf8'));
    assert.equal(link.tls, 'tls');
    assert.equal(link.net, 'ws');
    assert.equal(link.port, '443');
    assert.equal(link.aid, '0');
    const serverConfig = JSON.parse(fs.readFileSync(path.join(root, 'config/config.json'), 'utf8'));
    assert.equal(link.id, serverConfig.inbounds[0].users[0].uuid);
    assert.equal(link.path, serverConfig.inbounds[0].transport.path);
    fs.mkdirSync(path.join(root, 'logs'));
    fs.writeFileSync(path.join(root, 'payload.bin'), payload);
    await run('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
      '-subj', '/CN=edge.example.com', '-addext', 'subjectAltName=DNS:edge.example.com',
      '-keyout', path.join(root, 'config/tls/origin.key'), '-out', path.join(root, 'config/tls/origin.crt')]);
    target = http.createServer((req, res) => {
      targetHits++;
      const chunks = [];
      let size = 0;
      req.on('data', chunk => {
        size += chunk.length;
        if (size > payload.length) req.destroy();
        else chunks.push(chunk);
      });
      req.on('end', () => {
        uploadedBytes += size;
        res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
        res.end(req.method === 'POST' ? Buffer.concat(chunks) : payload);
      });
    });
    target.on('connection', socket => { targetSockets.add(socket); socket.once('close', () => targetSockets.delete(socket)); });
    target.listen(await freePort(), '127.0.0.1');
    await once(target, 'listening');
    const core = start(binary, ['run', '-c', path.join(root, 'config/config.json')], 'VMess server');
    await waitPort(core, corePort);
    await checkMode('tunnel', originPort);
    await checkMode('direct', await freePort());
  } catch (error) {
    console.error(error);
    for (const child of children) console.error(`${child.label}: ${child.log}`);
    process.exitCode = 1;
  } finally {
    await cleanup();
  }
})();
