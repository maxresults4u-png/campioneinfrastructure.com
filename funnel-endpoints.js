const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const Database = require('better-sqlite3');
const db = new Database('/root/api/keys.db');

module.exports = function(app) {
  const SUBSCRIBERS_FILE = path.join(__dirname, 'data', 'subscribers.json');
  if (!fs.existsSync(path.join(__dirname, 'data'))) fs.mkdirSync(path.join(__dirname, 'data'), { recursive: true });

  function readJSON(f) { try { if (fs.existsSync(f)) return JSON.parse(fs.readFileSync(f, 'utf8')); } catch(e) {} return []; }
  function writeJSON(f, d) { fs.writeFileSync(f, JSON.stringify(d, null, 2), 'utf8'); }
  function genKey() { return 'ci_' + crypto.randomBytes(16).toString('hex'); }

  app.post('/api/v1/subscribe', (req, res) => {
    const { email, source } = req.body || {};
    if (!email || !email.includes('@')) return res.status(400).json({ error: 'Valid email required' });
    const subs = readJSON(SUBSCRIBERS_FILE);
    if (subs.find(s => s.email.toLowerCase() === email.toLowerCase())) return res.json({ success: true, message: 'Already subscribed' });
    subs.push({ email: email.toLowerCase(), source: source || 'unknown', subscribedAt: new Date().toISOString() });
    writeJSON(SUBSCRIBERS_FILE, subs);
    console.log('[SUBSCRIBE] ' + email);
    res.json({ success: true, message: 'Subscribed successfully' });
  });

  app.post('/api/v1/generate-key', (req, res) => {
    const { name, email, source } = req.body || {};
    if (!name) return res.status(400).json({ error: 'Name required' });
    if (!email || !email.includes('@')) return res.status(400).json({ error: 'Valid email required' });
    const existing = db.prepare('SELECT * FROM api_keys WHERE email = ? AND active = 1').get(email.toLowerCase());
    if (existing) return res.json({ apiKey: existing.key, message: 'Existing key returned', existing: true });
    const apiKey = genKey();
    db.prepare('INSERT INTO api_keys (key, email, name, company, tier, active) VALUES (?, ?, ?, ?, ?, ?)').run(apiKey, email.toLowerCase(), name, source || '', 'free', 1);
    console.log('[KEY] ' + name + ' ' + apiKey);
    res.json({ apiKey, message: 'API key generated', existing: false });
  });

  app.get('/api/v1/stats', (req, res) => {
    const keyCount = db.prepare('SELECT COUNT(*) as c FROM api_keys WHERE active = 1').get();
    const subs = readJSON(SUBSCRIBERS_FILE);
    res.json({ totalKeys: keyCount.c, totalSubscribers: subs.length, chains: 8, uptime: '99.9' });
  });

  console.log('[FUNNEL] Endpoints loaded (SQLite mode)');
};
