const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = __dirname;
const PORT = Number(process.env.PORT) || 8766;

const MIME = {
    '.lua': 'text/plain; charset=utf-8',
    '.luau': 'text/plain; charset=utf-8',
    '.md': 'text/plain; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.js': 'text/plain; charset=utf-8',
    '.html': 'text/html; charset=utf-8',
};

http.createServer((req, res) => {
    let decoded;
    try {
        decoded = decodeURIComponent(String(req.url || '/').split('?')[0]);
    } catch {
        res.writeHead(400);
        return res.end('bad request');
    }

    const name = decoded.replace(/^\/+/, '');
    const rootDir = path.resolve(ROOT);
    const file = path.resolve(rootDir, name);
    const rel = path.relative(rootDir, file);

    if (rel.startsWith('..') || path.isAbsolute(rel)) {
        res.writeHead(403);
        return res.end('forbidden');
    }

    fs.readFile(file, (err, data) => {
        if (err) {
            res.writeHead(404);
            return res.end('not found');
        }
        res.writeHead(200, {
            'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream',
            'Cache-Control': 'no-store',
        });
        res.end(data);
    });
}).listen(PORT, '127.0.0.1', () => {
    console.log(`serving ${ROOT}`);
    console.log(`inject: loadstring(game:HttpGet("http://127.0.0.1:${PORT}/lua/loaders/mafia_loader.lua"))()`);
});
