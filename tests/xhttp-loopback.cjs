// Real VLESS/XHTTP (plain and Encryption) traffic through production nginx/server templates, on loopback only.
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

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ibmfree-xhttp-'));
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
let profile;
let auth = '';
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
  const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  child.label = label;
  child.log = '';
  child.on('error', error => { child.startError = error; });
  child.stderr.on('data', data => { child.log = (child.log + data.toString('utf8')).slice(-16000); });
  child.stdout.on('data', data => { child.log = (child.log + data.toString('utf8')).slice(-16000); });
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
  const query = link.searchParams;
  const user = { id: link.username, encryption: query.get('encryption') };
  const outbound = {
    protocol: 'vless', tag: 'fixture-proxy',
    settings: { vnext: [{ address: '127.0.0.1', port: originPort, users: [user] }] },
    streamSettings: {
      network: query.get('type'), security: 'none',
      xhttpSettings: { host: query.get('host'), path: query.get('path'), mode: query.get('mode') },
    },
  };
  if (mode === 'direct') {
    outbound.streamSettings.security = 'tls';
    outbound.streamSettings.tlsSettings = {
      serverName: query.get('sni'), fingerprint: query.get('fp'), alpn: ['h2'],
      certificates: [{ certificateFile: path.join(root, 'config/tls/origin.crt'), usage: 'verify' }],
    };
  }
  // Tunnel tests the actual HTTP origin hop, not Cloudflare's public network.
  if (variant === 'wrong-uuid') user.id = '22222222-2222-4222-8222-222222222222';
  if (variant === 'wrong-path') outbound.streamSettings.xhttpSettings.path += '/incorrect';
  if (variant === 'wrong-host') outbound.streamSettings.xhttpSettings.host = 'unknown.example.com';
  if (variant === 'wrong-encryption') {
    const parts = user.encryption.split('.');
    parts[3] = (parts[3][0] === 'A' ? 'B' : 'A') + parts[3].slice(1);
    user.encryption = parts.join('.');
  }
  const config = {
    log: { loglevel: process.env.XRAY_TEST_DEBUG ? 'debug' : 'warning' },
    inbounds: [{ protocol: 'socks', listen: '127.0.0.1', port, settings: { auth: 'noauth' } }],
    outbounds: [outbound],
  };
  const file = path.join(root, `${mode}-${variant}.json`);
  fs.writeFileSync(file, JSON.stringify(config), 'utf8');
  await run(binary, ['run', '-test', '-config', file]);
  const child = start(binary, ['run', '-config', file], `${mode} ${variant} client`);
  await waitPort(child, port);
  return { child, port };
}

async function transfer(port, name, upload = false) {
  const output = path.join(root, `${name}.body`);
  const args = ['--disable', '--silent', '--show-error', '--fail', '--connect-timeout', '2',
    '--max-time', '8', '--noproxy', '', '--socks5-hostname', `127.0.0.1:${port}`, '--output', output];
  if (upload) args.push('--data-binary', '@' + path.join(root, 'payload.bin'));
  args.push(`http://127.0.0.1:${target.address().port}/${name}`);
  // Even NO_PROXY=* must not let curl bypass the VLESS client for loopback URLs.
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
    `client_body_temp_path ${root}/client;\nproxy_temp_path ${root}/proxy;\nfastcgi_temp_path ${root}/fastcgi;\nuwsgi_temp_path ${root}/uwsgi;\nscgi_temp_path ${root}/scgi;\n${template}\n}\n`, 'utf8');
  await run('nginx', ['-p', root + '/', '-c', conf, '-t']);
  const nginx = start('nginx', ['-p', root + '/', '-c', conf, '-g', 'daemon off; master_process off;'], `${mode} nginx`);
  await waitPort(nginx, originPort);
  let client;
  try {
    const site = await run('curl', ['--disable', '--silent', '--show-error', '--noproxy', '*',
      '--header', 'Host: edge.example.com', ...(mode === 'direct' ? ['--cacert', path.join(root, 'config/tls/origin.crt'),
      '--resolve', `edge.example.com:${originPort}:127.0.0.1`] : []),
      `${mode === 'direct' ? 'https://edge.example.com' : 'http://127.0.0.1'}:${originPort}/`]);
    assert.match(site, /loopback fixture/);
    if (mode === 'tunnel') {
      await run('bash', ['-c', 'source "$1"; check_local_site', 'health-fixture', path.join(root, 'installer.sh')], {
        env: { ...process.env, FIXTURE_ROOT: root, REPO_ROOT: path.resolve(__dirname, '..'),
          PROXY_MODE: profile, PUBLIC_DOMAIN: link.hostname,
          WS_PATH: link.searchParams.get('path'), ORIGIN_PORT: String(originPort) },
      });
    }
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
    for (const variant of ['wrong-uuid', 'wrong-path', 'wrong-host',
      ...(profile.endsWith('-encryption') ? ['wrong-encryption'] : [])]) {
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
    console.log(`PASS real ${profile}${auth ? `/${auth}` : ''} ${mode}: exported link, concurrent 1 MiB downloads/upload, rejected UUID/path/Host/key, recovery`);
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
    assert.equal(process.platform, 'linux', 'XHTTP integration requires Linux, nginx, OpenSSL, curl and unzip');
    const metadata = await run('bash', ['-c',
      'source "$1"; trap - EXIT; read -r asset sum < <(detect_xray_arch); printf "%s %s %s\\n" "$XRAY_VERSION" "$asset" "$sum"',
      'release-fixture', path.join(__dirname, '../install.sh')]);
    const [version, arch, expectedHash] = metadata.trim().split(/\s+/);
    assert.match(version, /^\d+\.\d+\.\d+$/);
    assert.ok(['64', 'arm64-v8a', 's390x'].includes(arch));
    assert.match(expectedHash, /^[a-f0-9]{64}$/);
    const archive = path.join(root, 'xray.zip');
    if (process.env.XRAY_TEST_ARCHIVE) fs.copyFileSync(process.env.XRAY_TEST_ARCHIVE, archive);
    else await run('curl', ['--disable', '--fail', '--location', '--silent', '--show-error',
      '--retry', '2', '--connect-timeout', '15', '--max-time', '120', '--output', archive,
      `https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${arch}.zip`], { timeout: 180000 });
    assert.equal(hash(fs.readFileSync(archive)), expectedHash, 'pinned Xray checksum mismatch');
    await run('unzip', ['-q', archive, 'xray', '-d', root]);
    binary = path.join(root, 'xray');
    fs.symlinkSync(binary, path.join(root, 'edge-router'));
    fs.mkdirSync(path.join(root, 'config/tls'), { recursive: true });
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
    for ([profile, auth] of [['vless-xhttp', ''], ['vless-xhttp-encryption', 'x25519'],
      ['vless-xhttp-encryption', 'mlkem768']]) {
      const corePort = await freePort(), originPort = await freePort();
      await run('bash', [path.join(__dirname, 'prepare-vmess.sh'), root, String(corePort), String(originPort), profile],
        auth ? { env: { ...process.env, VLESS_AUTH: auth } } : {});
      await run(binary, ['run', '-test', '-config', path.join(root, 'config/config.json')]);
      link = new URL(fs.readFileSync(path.join(root, 'config/client.txt'), 'utf8').trim());
      assert.equal(link.protocol, 'vless:');
      assert.equal(link.searchParams.get('security'), 'tls');
      assert.equal(link.searchParams.get('type'), 'xhttp');
      assert.equal(link.searchParams.get('mode'), 'packet-up');
      const server = JSON.parse(fs.readFileSync(path.join(root, 'config/config.json'), 'utf8')).inbounds[0];
      assert.equal(link.username, server.settings.clients[0].id);
      assert.equal(link.searchParams.get('path'), server.streamSettings.xhttpSettings.path);
      if (auth === 'mlkem768') {
        assert.equal(link.searchParams.get('encryption').split('.').at(-1).length, 1579, 'client ML-KEM-768 public key length');
        assert.equal(server.settings.decryption.split('.').at(-1).length, 86, 'server ML-KEM-768 seed length');
      }
      if (profile.endsWith('-encryption')) {
        assert.ok(!link.href.includes(server.settings.decryption.split('.').at(-1)), 'private key in share link');
        assert.equal(fs.statSync(path.join(root, 'config/vless-keys.json')).mode & 0o777, 0o600);
      }
      const configFile = path.join(root, 'config/config.json');
      const config = JSON.parse(fs.readFileSync(configFile, 'utf8'));
      // Xray 26.11.9 blocks private targets by default. Permit ONLY this test
      // endpoint, in the temporary fixture; production keeps upstream defaults.
      config.outbounds[0].settings = { finalRules: [{ action: 'allow', network: 'tcp',
        ip: ['127.0.0.1/32'], port: String(target.address().port) }] };
      if (process.env.XRAY_TEST_DEBUG) config.log.loglevel = 'debug';
      fs.writeFileSync(configFile, JSON.stringify(config));
      await run(binary, ['run', '-test', '-config', configFile]);
      const core = start(binary, ['run', '-config', path.join(root, 'config/config.json')], profile + (auth ? `/${auth}` : '') + ' server');
      try {
        await waitPort(core, corePort);
        await checkMode('tunnel', originPort);
        await checkMode('direct', await freePort());
      } catch (error) {
        console.error(`${core.label}: ${core.log}`);
        throw error;
      } finally { await stop(core); }
    }
  } catch (error) {
    console.error(error);
    for (const child of children) console.error(`${child.label}: ${child.log}`);
    process.exitCode = 1;
  } finally {
    await cleanup();
  }
})();
