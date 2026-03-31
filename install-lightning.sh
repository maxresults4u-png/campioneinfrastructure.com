#!/bin/bash
# ============================================================
# Campione Infrastructure — Lightning Network (LND) Install
# Run when Bitcoin sync hits 0.99+
# Server: 45.77.113.67 — Ubuntu 22.04
# ============================================================
set -e

echo ""
echo "  ============================================"
echo "   CAMPIONE INFRASTRUCTURE"
echo "   Lightning Network Node Installation"
echo "  ============================================"
echo ""

# ── Verify Bitcoin is ready ─────────────────────────────────
echo "[1/8] Checking Bitcoin sync status..."
SYNC=$(bitcoin-cli getblockchaininfo | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['verificationprogress'])")
echo "Bitcoin sync: $SYNC"
if python3 -c "import sys; sys.exit(0 if float('$SYNC') >= 0.99 else 1)"; then
  echo "✓ Bitcoin ready for Lightning"
else
  echo "✗ Bitcoin not ready yet (need 0.99+). Current: $SYNC"
  echo "Re-run this script when sync is complete."
  exit 1
fi

# ── Install Go (required for LND) ───────────────────────────
echo ""
echo "[2/8] Installing Go..."
cd /tmp
wget -q https://go.dev/dl/go1.21.6.linux-amd64.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf go1.21.6.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
echo 'export PATH=$PATH:/usr/local/go/bin' >> /root/.bashrc
echo "✓ Go installed: $(go version)"

# ── Download and build LND ───────────────────────────────────
echo ""
echo "[3/8] Downloading and building LND v0.18.0..."
cd /root
git clone https://github.com/lightningnetwork/lnd.git
cd lnd
git checkout v0.18.0-beta
make install tags="autopilotrpc signrpc walletrpc chainrpc invoicesrpc routerrpc watchtowerrpc"
echo "✓ LND built: $(lnd --version)"

# ── Create LND config ────────────────────────────────────────
echo ""
echo "[4/8] Configuring LND..."
mkdir -p /root/.lnd

cat > /root/.lnd/lnd.conf << 'LNDCONF'
[Application Options]
alias=Campione-Infrastructure
color=#2563eb
listen=0.0.0.0:9735
externalip=45.77.113.67:9735
maxpendingchannels=10
minchansize=20000
maxchansize=16777215
accept-keysend=true
accept-amp=true
gc-canceled-invoices-on-startup=true
gc-canceled-invoices-on-the-fly=true

[Bitcoin]
bitcoin.active=1
bitcoin.mainnet=1
bitcoin.node=bitcoind

[Bitcoind]
bitcoind.rpchost=localhost
bitcoind.rpcuser=bitcoin
bitcoind.rpcpass=campione2026
bitcoind.zmqpubrawblock=tcp://127.0.0.1:28332
bitcoind.zmqpubrawtx=tcp://127.0.0.1:28333

[tor]
tor.active=false

[autopilot]
autopilot.active=1
autopilot.maxchannels=5
autopilot.allocation=0.6
autopilot.minchansize=20000
autopilot.maxchansize=500000
autopilot.private=false
autopilot.minconfs=1
LNDCONF

echo "✓ LND config created"

# ── Update Bitcoin config for ZMQ ───────────────────────────
echo ""
echo "[5/8] Updating Bitcoin config for Lightning ZMQ..."
cat >> /root/.bitcoin/bitcoin.conf << 'BTCCONF'

# Lightning Network ZMQ
zmqpubrawblock=tcp://127.0.0.1:28332
zmqpubrawtx=tcp://127.0.0.1:28333
txindex=1
BTCCONF

systemctl restart bitcoind
sleep 10
echo "✓ Bitcoin config updated"

# ── Create systemd service ───────────────────────────────────
echo ""
echo "[6/8] Creating LND systemd service..."
cat > /etc/systemd/system/lnd.service << 'SERVICE'
[Unit]
Description=Campione Infrastructure — Lightning Network Daemon
After=bitcoind.service
Requires=bitcoind.service

[Service]
Type=simple
User=root
ExecStart=/root/go/bin/lnd
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable lnd
echo "✓ LND service created"

# ── Open firewall port ───────────────────────────────────────
echo ""
echo "[7/8] Opening firewall port 9735..."
ufw allow 9735/tcp
echo "✓ Port 9735 open"

# ── Start LND ───────────────────────────────────────────────
echo ""
echo "[8/8] Starting LND..."
systemctl start lnd
sleep 5
systemctl status lnd --no-pager

echo ""
echo "  ============================================"
echo "   LND INSTALLED SUCCESSFULLY"
echo "  ============================================"
echo ""
echo "  NEXT STEPS:"
echo ""
echo "  1. Create wallet (SAVE YOUR SEED PHRASE):"
echo "     lncli create"
echo ""
echo "  2. Get your node pubkey:"
echo "     lncli getinfo"
echo ""
echo "  3. Get a deposit address for BTC:"
echo "     lncli newaddress p2wkh"
echo ""
echo "  4. After funding, open channels to major nodes:"
echo "     lncli connect 03864ef025fde8fb587d989186ce6a4a186895ee44a926bfc370e2c366597a3f8f@34.239.230.56:9735"
echo "     lncli openchannel --node_key 03864ef025fde8fb587d989186ce6a4a186895ee44a926bfc370e2c366597a3f8f --local_amt 200000"
echo ""
echo "  5. Check channel status:"
echo "     lncli listchannels"
echo ""
echo "  6. Monitor routing fees earned:"
echo "     lncli feereport"
echo ""
echo "  Portal: https://campioneinfrastructure.com"
echo "  ============================================"
