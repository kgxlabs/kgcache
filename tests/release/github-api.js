// A stateful loopback API. It never connects to GitHub or creates real releases.
const http = require('node:http');
const fs = require('node:fs');
const crypto = require('node:crypto');

const root = process.argv[2];
const statePath = `${root}/state.json`;
const staleReleasesPath = `${root}/stale-releases.json`;
const initial = { releases: [], assets: {}, latest: null, nextId: 1 };
fs.writeFileSync(statePath, JSON.stringify(initial));

const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    const prefix = '/repos/fixture/kgcache';
    if (!url.pathname.startsWith(`${prefix}/`)) {
        res.writeHead(404).end();
        return;
    }
    const chunks = [];
    let length = 0;
    for await (const chunk of req) {
        length += chunk.length;
        if (length > 1048576) {
            res.writeHead(413).end();
            return;
        }
        chunks.push(chunk);
    }
    const bytes = Buffer.concat(chunks);
    const path = url.pathname.slice(prefix.length);
    const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    const faultPath = `${root}/fault.json`;
    const fault = fs.existsSync(faultPath) ? JSON.parse(fs.readFileSync(faultPath)) : {};
    const matchesFault = fault.method === req.method && fault.path === path;
    if (fs.existsSync(`${root}/lag-release-list`) && !fs.existsSync(staleReleasesPath) &&
        (req.method === 'POST' && path === '/releases' ||
         req.method === 'PATCH' && /^\/releases\/\d+$/.test(path))) {
        fs.writeFileSync(staleReleasesPath, JSON.stringify(state.releases));
    }
    fs.appendFileSync(`${root}/calls.jsonl`, `${JSON.stringify({ method: req.method, path: req.url })}\n`);
    const send = (code, body, binary = false) => {
        fs.writeFileSync(statePath, JSON.stringify(state));
        if (matchesFault && fault.after) {
            fs.unlinkSync(faultPath);
            req.socket.destroy();
            return;
        }
        res.writeHead(code, { 'Content-Type': binary ? 'application/octet-stream' : 'application/json' });
        res.end(binary ? body : JSON.stringify(body));
    };
    if (matchesFault && !fault.after) {
        fs.unlinkSync(faultPath);
        send(503, { message: 'fixture failure before write' });
        return;
    }
    if (req.method === 'GET' && path.startsWith('/contents/')) {
        const content = Buffer.from('Compatible release. No migration is needed.\n');
        const sha = crypto.createHash('sha1').update(`blob ${content.length}\0`).update(content).digest('hex');
        send(200, { type: 'file', encoding: 'base64', sha, content: content.toString('base64') });
    } else if (req.method === 'GET' && path === '/releases') {
        const page = Number(url.searchParams.get('page') || 1);
        const releases = fs.existsSync(staleReleasesPath) ?
            JSON.parse(fs.readFileSync(staleReleasesPath)) : state.releases;
        send(200, releases.slice((page - 1) * 100, page * 100));
    } else if (req.method === 'GET' && path === '/releases/latest') {
        const release = state.releases.find((item) => item.id === state.latest);
        send(release ? 200 : 404, release || { message: 'Not Found' });
    } else if (req.method === 'GET' && /^\/releases\/\d+$/.test(path)) {
        const release = state.releases.find((item) => item.id === Number(path.split('/')[2]));
        send(release ? 200 : 404, release || { message: 'Not Found' });
    } else if (req.method === 'POST' && path === '/releases') {
        const body = JSON.parse(bytes);
        if (!body.draft || body.make_latest !== 'false' || !/^[0-9a-f]{40}$/.test(body.target_commitish)) {
            send(422, { message: 'unsafe release request' });
            return;
        }
        const release = { ...body, id: state.nextId++, assets: [] };
        state.releases.push(release);
        send(201, release);
    } else if (req.method === 'PATCH' && /^\/releases\/\d+$/.test(path)) {
        const release = state.releases.find((item) => item.id === Number(path.split('/')[2]));
        if (!release) { send(404, {}); return; }
        const body = JSON.parse(bytes);
        Object.assign(release, body);
        if (body.make_latest === 'true') state.latest = release.id;
        send(200, release);
    } else if (/^\/releases\/\d+\/assets$/.test(path)) {
        const release = state.releases.find((item) => item.id === Number(path.split('/')[2]));
        if (!release) { send(404, {}); return; }
        if (req.method === 'GET') {
            send(200, release.assets);
        } else if (req.method === 'POST') {
            const name = url.searchParams.get('name');
            if (!release.draft || release.assets.some((asset) => asset.name === name)) {
                send(422, {}); return;
            }
            const asset = { id: state.nextId++, name, state: 'uploaded', size: bytes.length };
            state.assets[asset.id] = bytes.toString('base64');
            release.assets.push(asset);
            send(201, asset);
        } else send(405, {});
    } else if (req.method === 'GET' && /^\/releases\/assets\/\d+$/.test(path)) {
        const asset = state.assets[path.split('/')[3]];
        send(asset ? 200 : 404, asset ? Buffer.from(asset, 'base64') : Buffer.alloc(0), true);
    } else send(404, {});
});

server.listen(0, '127.0.0.1', () => {
    fs.writeFileSync(`${root}/port`, String(server.address().port));
});
