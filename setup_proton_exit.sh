#!/usr/bin/env bash
set -euo pipefail

# Setup script: add a second REALITY instance that exits via ProtonVPN wireproxy
# Existing xray on port 16900 is NOT touched

WIREPROXY_CONF="/root/proton-wg-config/configs/NL-FREE79.wireproxy.conf"
WIREPROXY_BIN="/root/go/bin/wireproxy"
WIREPROXY_SOCKS_PORT=40000
XRAY_BIN="/etc/xray-reality/xray"
PROTON_CONF_DIR="/etc/xray-reality/conf-proton"

GREEN='\033[32m'
RED='\033[31m'
BLUE='\033[34m'
RESET='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*"; }
log_blue()  { echo -e "${BLUE}$*${RESET}"; }

# Step 1: Kill old wireproxy if running
log_info "Stopping old wireproxy..."
pkill -f wireproxy 2>/dev/null || true
sleep 1

# Step 2: Create wireproxy systemd service
log_info "Creating wireproxy systemd service..."
cat > /etc/systemd/system/wireproxy.service <<EOF
[Unit]
Description=wireproxy (ProtonVPN WireGuard tunnel)
After=network.target
Before=xray-proton.service

[Service]
Type=simple
ExecStart=${WIREPROXY_BIN} -c ${WIREPROXY_CONF}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wireproxy.service
systemctl start wireproxy.service

# Step 3: Wait for wireproxy tunnel
log_info "Waiting for WireGuard tunnel..."
ready=false
for i in $(seq 1 15); do
    if curl -s --socks5-hostname "127.0.0.1:${WIREPROXY_SOCKS_PORT}" \
        "https://api.ipify.org?format=json" --max-time 5 &>/dev/null; then
        ready=true
        break
    fi
    echo "  ... attempt ${i}/15"
    sleep 3
done

if ! ${ready}; then
    log_error "wireproxy tunnel failed"
    journalctl -u wireproxy --no-pager -n 10
    exit 1
fi

exit_ip=$(curl -s --socks5-hostname "127.0.0.1:${WIREPROXY_SOCKS_PORT}" \
    "https://api.ipify.org?format=json" --max-time 10 | jq -r '.ip' 2>/dev/null)
log_info "ProtonVPN exit IP: ${exit_ip}"

# Step 4: Generate new REALITY keys + UUID
log_info "Generating keys..."
key_output=$("${XRAY_BIN}" x25519)
PRIVATE_KEY=$(echo "${key_output}" | grep "Private" | awk '{print $NF}')
PUBLIC_KEY=$(echo "${key_output}" | grep -i "public\|Password" | awk '{print $NF}')
CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)
REALITY_PORT=$((RANDOM % 20001 + 10000))

# Make sure port isn't in use
while ss -tlnp | grep -q ":${REALITY_PORT} "; do
    REALITY_PORT=$((RANDOM % 20001 + 10000))
done

REALITY_SNI="www.python.org"
INTERNAL_PORT=45988

log_info "Port: ${REALITY_PORT}"
log_info "UUID: ${CLIENT_UUID}"

# Step 5: Write xray-proton config
log_info "Writing xray-proton config..."
mkdir -p "${PROTON_CONF_DIR}"

cat > "${PROTON_CONF_DIR}/00_log.json" <<'CEOF'
{
  "log": {
    "error": "/etc/xray-reality/error-proton.log",
    "loglevel": "warning"
  }
}
CEOF

cat > "${PROTON_CONF_DIR}/01_routing.json" <<'CEOF'
{
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": ["127.0.0.0/8", "::1/128"],
        "outboundTag": "direct_no_proxy"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "direct_no_proxy"
      }
    ]
  }
}
CEOF

cat > "${PROTON_CONF_DIR}/02_outbound.json" <<EOF
{
  "outbounds": [
    {
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": ${WIREPROXY_SOCKS_PORT}
          }
        ]
      },
      "tag": "z_direct_outbound"
    },
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct_no_proxy"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blackhole_out"
    }
  ]
}
EOF

cat > "${PROTON_CONF_DIR}/07_inbound.json" <<EOF
{
  "inbounds": [
    {
      "tag": "dokodemo-in-proton",
      "port": ${REALITY_PORT},
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": ${INTERNAL_PORT},
        "network": "tcp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["tls"],
        "routeOnly": true
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${INTERNAL_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${CLIENT_UUID}",
            "email": "proton-vless_reality_vision",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "fallbacks": []
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_SNI}:443",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "publicKey": "${PUBLIC_KEY}",
          "maxTimeDiff": 70000,
          "shortIds": ["", "6ba85179e30d4fc2"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ]
}
EOF

# Step 6: Create xray-proton systemd service
log_info "Creating xray-proton systemd service..."
cat > /etc/systemd/system/xray-proton.service <<EOF
[Unit]
Description=Xray Service (ProtonVPN exit)
After=network.target wireproxy.service
Requires=wireproxy.service

[Service]
User=root
ExecStart=${XRAY_BIN} run -confdir ${PROTON_CONF_DIR}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=infinity
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray-proton.service
systemctl start xray-proton.service
sleep 1

if systemctl is-active xray-proton &>/dev/null; then
    log_info "xray-proton started successfully"
else
    log_error "xray-proton failed to start"
    journalctl -u xray-proton --no-pager -n 20
    exit 1
fi

# Step 7: Open firewall
if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    ufw allow "${REALITY_PORT}"/tcp >/dev/null 2>&1
fi
if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
    firewall-cmd --zone=public --add-port="${REALITY_PORT}"/tcp --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
fi

# Step 8: Show results
public_ip=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "ip" | awk -F '=' '{print $2}')

echo
log_blue "================================================================"
log_blue "          Reality + ProtonVPN Exit — Deployment Complete"
log_blue "================================================================"
echo
log_info "Mode:        VLESS + Reality + Vision → ProtonVPN (NL)"
log_info "Exit IP:     ${exit_ip} (ProtonVPN Netherlands)"
log_info "Server:      ${public_ip}"
log_info "Port:        ${REALITY_PORT}"
log_info "UUID:        ${CLIENT_UUID}"
log_info "Flow:        xtls-rprx-vision"
log_info "Security:    reality"
log_info "SNI:         ${REALITY_SNI}"
log_info "Fingerprint: chrome"
log_info "PublicKey:   ${PUBLIC_KEY}"
log_info "ShortId:     6ba85179e30d4fc2"
echo

share_link="vless://${CLIENT_UUID}@${public_ip}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=6ba85179e30d4fc2&spx=%2F&type=tcp&headerType=none#VLESSRealityProton"

log_blue "Share link:"
echo -e "${GREEN}${share_link}${RESET}"
echo
log_blue "Existing REALITY (direct exit) on port 16900 is UNTOUCHED."
log_blue "================================================================"
