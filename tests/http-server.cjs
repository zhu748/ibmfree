// A loopback-only HTTP/WebSocket fixture; it never connects to external hosts.
const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const sockets = new Set();
const server = http.createServer((req, res) => {
  res.writeHead(req.url === '/' ? 200 : 404);
  res.end('fixture');
});
server.on('connection', socket => {
  sockets.add(socket);
  socket.on('close', () => sockets.delete(socket));
});
server.on('upgrade', (req, socket) => {
  if (req.method !== 'GET' || req.url !== '/probe/0123456789abcdef' ||
      req.headers.host !== 'edge.example.com' || req.headers['sec-websocket-version'] !== '13') {
    socket.end('HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n');
    return;
  }
  const accept = crypto.createHash('sha1')
    .update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
    .digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n' +
    'Connection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n');
  // Stay open until curl's bounded timeout, like the real upgraded transport.
});
function stop() {
  for (const socket of sockets) socket.destroy();
  server.close(() => process.exit(0));
}
process.on('SIGTERM', stop);
setTimeout(stop, 20000);
server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(process.argv[2], String(server.address().port), 'utf8');
});
