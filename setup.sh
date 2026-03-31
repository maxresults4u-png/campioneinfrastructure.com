#!/bin/bash
# ============================================================
# Campione Infrastructure — Horizon API Key System Setup
# Run once on the Miami server as root
# ============================================================
set -e

echo "=== [1/7] Installing dependencies ==="
apt-get update -qq
apt-get install -y python3-pip python3-flask certbot python3-certbot-nginx nginx

pip3 install flask stripe --break-system-packages

echo "=== [2/7] Creating app directory ==="
mkdir -p /root/horizon-api
cp /tmp/app.py /root/horizon-api/app.py
chmod 700 /root/horizon-api
chmod 600 /root/horizon-api/app.py

echo "=== [3/7] Installing nginx config ==="
cp /tmp/nginx-horizon.conf /etc/nginx/sites-available/horizon
ln -sf /etc/nginx/sites-available/horizon /etc/nginx/sites-enabled/horizon
nginx -t && echo "nginx config OK"

echo "=== [4/7] Getting SSL certificate ==="
certbot --nginx -d horizon.campioneinfrastructure.com \
  --non-interactive --agree-tos -m kenneth@campioneinfrastructure.com
echo "SSL certificate installed"

echo "=== [5/7] Installing systemd service ==="
cp /tmp/horizon-keys.service /etc/systemd/system/horizon-keys.service
echo ""
echo "  *** IMPORTANT: Edit the secrets in the service file before starting ***"
echo "  nano /etc/systemd/system/horizon-keys.service"
echo "  Set: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PRICE_ID, ADMIN_TOKEN"
echo ""
read -p "Press ENTER once you've edited the service file..."

echo "=== [6/7] Starting services ==="
systemctl daemon-reload
systemctl enable horizon-keys
systemctl start horizon-keys
systemctl reload nginx

echo "=== [7/7] Opening firewall port (already should be open) ==="
ufw allow 443/tcp
ufw allow 80/tcp

echo ""
echo "============================================================"
echo "  SETUP COMPLETE"
echo "============================================================"
echo "  Portal:   https://horizon.campioneinfrastructure.com/portal"
echo "  Validate: https://horizon.campioneinfrastructure.com/_auth"
echo "  Webhook:  https://horizon.campioneinfrastructure.com/stripe-webhook"
echo ""
echo "  Test API key validation:"
echo "  curl -H 'X-API-Key: ci_test' https://horizon.campioneinfrastructure.com/accounts/GADDRESS"
echo ""
echo "  Generate a manual key (replace YOUR_ADMIN_TOKEN):"
echo "  curl -X POST http://localhost:9998/admin/generate \\"
echo "    -H 'X-Admin-Token: YOUR_ADMIN_TOKEN' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"email\":\"test@example.com\",\"note\":\"free trial\"}'"
echo "============================================================"
