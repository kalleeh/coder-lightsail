const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const HTML = fs.readFileSync(path.join(__dirname, 'index.html'));

http.createServer((req, res) => {
  // tmux send-keys for special keys (Escape, Tab, Up, C-c, etc.)
  if (req.method === 'POST' && req.url === '/send') {
    let body = '';
    req.on('data', c => { body += c; if (body.length > 64) { req.destroy(); return; } });
    req.on('end', () => {
      const key = body.trim();
      // Sanitize: only allow known tmux key names
      if (/^(Escape|Tab|Up|Down|Left|Right|Enter|BSpace|C-[a-z]|M-[a-z])$/.test(key)) {
        execFile('tmux', ['send-keys', '-t', 'main', key], (err) => {
          res.writeHead(err ? 500 : 200, {'Content-Type':'text/plain'});
          res.end(err ? 'error' : 'ok');
        });
      } else {
        res.writeHead(400, {'Content-Type':'text/plain'});
        res.end('invalid key');
      }
    });
    return;
  }

  // tmux send-keys -l for literal characters (|, ~, `)
  if (req.method === 'POST' && req.url === '/sendlit') {
    let body = '';
    req.on('data', c => { body += c; if (body.length > 64) { req.destroy(); return; } });
    req.on('end', () => {
      const ch = body.trim();
      // Sanitize: only allow single printable characters
      if (ch.length === 1 && ch.charCodeAt(0) >= 32 && ch.charCodeAt(0) <= 126) {
        execFile('tmux', ['send-keys', '-t', 'main', '-l', ch], (err) => {
          res.writeHead(err ? 500 : 200, {'Content-Type':'text/plain'});
          res.end(err ? 'error' : 'ok');
        });
      } else {
        res.writeHead(400, {'Content-Type':'text/plain'});
        res.end('invalid char');
      }
    });
    return;
  }

  // Serve index.html for everything else
  res.writeHead(200, {'Content-Type':'text/html'});
  res.end(HTML);
}).listen(7682, () => {
  console.log('Mobile terminal server on port 7682');
});
