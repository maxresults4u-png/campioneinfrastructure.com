#!/usr/bin/env python3
"""
Campione Infrastructure — Horizon API Key Management Server
Port: 9998
"""

from flask import Flask, request, jsonify, redirect, render_template_string
import stripe
import sqlite3
import secrets
import os
from datetime import datetime

app = Flask(__name__)

# ── Config (set via environment variables) ──────────────────────────────────
stripe.api_key          = os.environ.get("STRIPE_SECRET_KEY", "")
STRIPE_WEBHOOK_SECRET   = os.environ.get("STRIPE_WEBHOOK_SECRET", "")
STRIPE_PRICE_ID         = os.environ.get("STRIPE_PRICE_ID", "")   # $99/mo recurring
ADMIN_TOKEN             = os.environ.get("ADMIN_TOKEN", "changeme")
DOMAIN                  = "https://horizon.campioneinfrastructure.com"
DB_PATH                 = "/root/horizon-api/keys.db"
RATE_LIMIT_RPM          = 30   # requests per minute per key (enforced by nginx)

# ── Database ─────────────────────────────────────────────────────────────────
def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    conn = get_db()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS api_keys (
            id                      INTEGER PRIMARY KEY AUTOINCREMENT,
            key                     TEXT UNIQUE NOT NULL,
            email                   TEXT NOT NULL,
            stripe_customer_id      TEXT,
            stripe_subscription_id  TEXT,
            created_at              TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            active                  INTEGER DEFAULT 1,
            note                    TEXT
        )
    """)
    conn.commit()
    conn.close()

def generate_key():
    return "ci_" + secrets.token_urlsafe(32)

# ── nginx auth_request endpoint ──────────────────────────────────────────────
@app.route("/validate")
def validate():
    api_key = request.headers.get("X-API-Key") or request.args.get("key", "")
    if not api_key:
        return jsonify(error="Missing API key"), 401
    conn = get_db()
    row = conn.execute(
        "SELECT active FROM api_keys WHERE key = ?", (api_key,)
    ).fetchone()
    conn.close()
    if row and row["active"] == 1:
        return "", 200
    return jsonify(error="Invalid or inactive API key"), 401

# ── Stripe Checkout ───────────────────────────────────────────────────────────
@app.route("/create-checkout-session", methods=["POST"])
def create_checkout():
    try:
        session = stripe.checkout.Session.create(
            payment_method_types=["card"],
            line_items=[{"price": STRIPE_PRICE_ID, "quantity": 1}],
            mode="subscription",
            success_url=DOMAIN + "/portal/success?session_id={CHECKOUT_SESSION_ID}",
            cancel_url=DOMAIN + "/portal",
        )
        return redirect(session.url, code=303)
    except Exception as e:
        return jsonify(error=str(e)), 400

# ── Stripe Webhook ────────────────────────────────────────────────────────────
@app.route("/stripe-webhook", methods=["POST"])
def stripe_webhook():
    payload    = request.get_data()
    sig_header = request.headers.get("Stripe-Signature", "")
    try:
        event = stripe.Webhook.construct_event(
            payload, sig_header, STRIPE_WEBHOOK_SECRET
        )
    except Exception as e:
        return jsonify(error=str(e)), 400

    if event["type"] == "checkout.session.completed":
        session  = event["data"]["object"]
        email    = session["customer_details"]["email"]
        cust_id  = session.get("customer")
        sub_id   = session.get("subscription")
        key      = generate_key()
        conn = get_db()
        conn.execute(
            "INSERT INTO api_keys (key, email, stripe_customer_id, stripe_subscription_id) "
            "VALUES (?, ?, ?, ?)",
            (key, email, cust_id, sub_id),
        )
        conn.commit()
        conn.close()

    elif event["type"] == "customer.subscription.deleted":
        sub_id = event["data"]["object"]["id"]
        conn = get_db()
        conn.execute(
            "UPDATE api_keys SET active = 0 WHERE stripe_subscription_id = ?", (sub_id,)
        )
        conn.commit()
        conn.close()

    return jsonify(success=True)

# ── Success page (shows API key after payment) ────────────────────────────────
@app.route("/portal/success")
def portal_success():
    session_id = request.args.get("session_id", "")
    if not session_id:
        return redirect(DOMAIN + "/portal")
    try:
        session = stripe.checkout.Session.retrieve(session_id)
        email   = session["customer_details"]["email"]
        conn    = get_db()
        row     = conn.execute(
            "SELECT key FROM api_keys WHERE email = ? AND active = 1 "
            "ORDER BY created_at DESC LIMIT 1",
            (email,),
        ).fetchone()
        conn.close()
        api_key = row["key"] if row else "Still generating — check back in 30 seconds."
        return render_template_string(SUCCESS_HTML, email=email, api_key=api_key)
    except Exception as e:
        return f"Error retrieving your key: {e}", 500

# ── Self-serve portal landing page ────────────────────────────────────────────
@app.route("/portal")
def portal():
    return render_template_string(PORTAL_HTML)

# ── Admin endpoints ───────────────────────────────────────────────────────────
def require_admin():
    token = request.headers.get("X-Admin-Token", "")
    return token == ADMIN_TOKEN

@app.route("/admin/keys")
def admin_list_keys():
    if not require_admin():
        return jsonify(error="Unauthorized"), 401
    conn = get_db()
    rows = conn.execute(
        "SELECT id, key, email, created_at, active, note FROM api_keys ORDER BY created_at DESC"
    ).fetchall()
    conn.close()
    return jsonify([dict(r) for r in rows])

@app.route("/admin/generate", methods=["POST"])
def admin_generate():
    """Manually generate a key (free trial, gift, etc.)"""
    if not require_admin():
        return jsonify(error="Unauthorized"), 401
    data  = request.get_json(force=True)
    email = data.get("email", "manual")
    note  = data.get("note", "manual")
    key   = generate_key()
    conn  = get_db()
    conn.execute(
        "INSERT INTO api_keys (key, email, note) VALUES (?, ?, ?)", (key, email, note)
    )
    conn.commit()
    conn.close()
    return jsonify(key=key, email=email)

@app.route("/admin/revoke", methods=["POST"])
def admin_revoke():
    if not require_admin():
        return jsonify(error="Unauthorized"), 401
    data = request.get_json(force=True)
    key  = data.get("key", "")
    conn = get_db()
    conn.execute("UPDATE api_keys SET active = 0 WHERE key = ?", (key,))
    conn.commit()
    conn.close()
    return jsonify(revoked=key)

# ── HTML templates ─────────────────────────────────────────────────────────────
PORTAL_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Stellar Horizon API — Campione Infrastructure</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
           background: #0a0e1a; color: #e2e8f0; min-height: 100vh;
           display: flex; align-items: center; justify-content: center; padding: 2rem; }
    .card { background: #111827; border: 1px solid #1e2d45; border-radius: 16px;
            max-width: 520px; width: 100%; padding: 3rem 2.5rem; text-align: center; }
    .badge { display: inline-block; background: #0f2d1a; color: #4ade80;
             border: 1px solid #166534; border-radius: 20px; font-size: 12px;
             padding: 4px 14px; margin-bottom: 1.5rem; letter-spacing: .04em; }
    h1 { font-size: 1.9rem; font-weight: 700; color: #f1f5f9; margin-bottom: .75rem; }
    .sub { color: #94a3b8; font-size: .95rem; line-height: 1.6; margin-bottom: 2rem; }
    .price { font-size: 3rem; font-weight: 800; color: #38bdf8; margin-bottom: .25rem; }
    .price span { font-size: 1rem; font-weight: 400; color: #64748b; }
    .features { text-align: left; margin: 1.5rem 0 2rem; }
    .feat { display: flex; align-items: center; gap: .75rem; padding: .5rem 0;
            border-bottom: 1px solid #1e2d45; font-size: .9rem; color: #cbd5e1; }
    .feat:last-child { border-bottom: none; }
    .check { color: #4ade80; font-weight: 700; flex-shrink: 0; }
    .btn { display: block; width: 100%; background: #0ea5e9; color: #fff;
           border: none; border-radius: 10px; font-size: 1rem; font-weight: 600;
           padding: 1rem; cursor: pointer; transition: background .2s; text-decoration: none; }
    .btn:hover { background: #0284c7; }
    .note { color: #475569; font-size: .8rem; margin-top: 1rem; }
  </style>
</head>
<body>
  <div class="card">
    <div class="badge">LIVE — Stellar Mainnet</div>
    <h1>Stellar Horizon API</h1>
    <p class="sub">Production-grade Horizon API access on Miami infrastructure.
       Low-latency, 99.9% uptime SLA, instant key delivery.</p>
    <div class="price">$99<span>/month</span></div>
    <div class="features">
      <div class="feat"><span class="check">✓</span> Full Horizon v25.0.0 API access</div>
      <div class="feat"><span class="check">✓</span> 30 requests/minute rate limit</div>
      <div class="feat"><span class="check">✓</span> Miami server — &lt;10ms latency</div>
      <div class="feat"><span class="check">✓</span> API key delivered instantly</div>
      <div class="feat"><span class="check">✓</span> 99.9% uptime SLA</div>
      <div class="feat"><span class="check">✓</span> Cancel anytime</div>
    </div>
    <form action="/create-checkout-session" method="POST">
      <button class="btn" type="submit">Subscribe — Get Instant Access</button>
    </form>
    <p class="note">Secured by Stripe. Your key arrives on the next screen.</p>
  </div>
</body>
</html>"""

SUCCESS_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Your API Key — Campione Infrastructure</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
           background: #0a0e1a; color: #e2e8f0; min-height: 100vh;
           display: flex; align-items: center; justify-content: center; padding: 2rem; }
    .card { background: #111827; border: 1px solid #1e2d45; border-radius: 16px;
            max-width: 560px; width: 100%; padding: 3rem 2.5rem; text-align: center; }
    .icon { font-size: 3rem; margin-bottom: 1rem; }
    h1 { font-size: 1.7rem; font-weight: 700; color: #f1f5f9; margin-bottom: .5rem; }
    .email { color: #94a3b8; font-size: .9rem; margin-bottom: 2rem; }
    .key-box { background: #0d1117; border: 2px solid #0ea5e9; border-radius: 10px;
               padding: 1.25rem 1.5rem; margin-bottom: 1rem; }
    .key-label { font-size: .75rem; text-transform: uppercase; letter-spacing: .08em;
                 color: #0ea5e9; margin-bottom: .5rem; }
    .key-value { font-family: 'Courier New', monospace; font-size: .85rem;
                 color: #38bdf8; word-break: break-all; line-height: 1.5; }
    .copy-btn { background: #0ea5e9; color: #fff; border: none; border-radius: 8px;
                padding: .6rem 1.5rem; font-size: .85rem; font-weight: 600;
                cursor: pointer; margin-bottom: 2rem; transition: background .2s; }
    .copy-btn:hover { background: #0284c7; }
    .warn { background: #1c1408; border: 1px solid #92400e; border-radius: 8px;
            padding: 1rem 1.25rem; text-align: left; margin-bottom: 2rem; }
    .warn-title { color: #f59e0b; font-weight: 600; font-size: .875rem; margin-bottom: .4rem; }
    .warn-text { color: #d97706; font-size: .825rem; line-height: 1.5; }
    .usage { text-align: left; }
    .usage h3 { font-size: .9rem; color: #94a3b8; margin-bottom: .75rem; }
    pre { background: #0d1117; border: 1px solid #1e2d45; border-radius: 8px;
          padding: 1rem; font-size: .78rem; color: #7dd3fc; overflow-x: auto;
          line-height: 1.6; }
    .link { color: #0ea5e9; text-decoration: none; font-size: .85rem; }
    .link:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">🎉</div>
    <h1>You're live on Stellar Horizon</h1>
    <p class="email">Subscribed as {{ email }}</p>
    <div class="key-box">
      <div class="key-label">Your API Key</div>
      <div class="key-value" id="api-key">{{ api_key }}</div>
    </div>
    <button class="copy-btn" onclick="copyKey()">Copy API Key</button>
    <div class="warn">
      <div class="warn-title">⚠ Save this key now</div>
      <div class="warn-text">This is the only time we display your key in full.
        Store it in a password manager or secure vault.</div>
    </div>
    <div class="usage">
      <h3>How to use your key</h3>
      <pre>curl -H "X-API-Key: YOUR_KEY" \\
     https://horizon.campioneinfrastructure.com/accounts/GADDRESS</pre>
    </div>
    <br>
    <a class="link" href="https://campioneinfrastructure.com">← Back to Campione Infrastructure</a>
  </div>
  <script>
    function copyKey() {
      const key = document.getElementById('api-key').innerText;
      navigator.clipboard.writeText(key).then(() => {
        const btn = document.querySelector('.copy-btn');
        btn.textContent = 'Copied!';
        setTimeout(() => btn.textContent = 'Copy API Key', 2000);
      });
    }
  </script>
</body>
</html>"""

# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    init_db()
    print("[+] Campione Horizon Key Manager starting on port 9998")
    app.run(host="127.0.0.1", port=9998)
