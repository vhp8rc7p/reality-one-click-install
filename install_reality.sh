#!/usr/bin/env bash

# Standalone Xray Reality Deployment Script
# Deploys VLESS + Reality + Vision (no domain required)

set -euo pipefail

INSTALL_DIR="/etc/xray-reality"
CONF_DIR="${INSTALL_DIR}/conf"
PROTON_DIR="${INSTALL_DIR}/proton"
PROTON_CONF_DIR="${INSTALL_DIR}/conf-proton"
WIREPROXY_SOCKS_PORT=40000
WIREPROXY_HTTP_PORT=40001
USE_PROTON_EXIT=false

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
RESET='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*"; }
log_blue()  { echo -e "${BLUE}$*${RESET}"; }

check_root() {
    if [[ "$(id -u)" != "0" ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_os() {
    if [[ "$(uname)" != "Linux" ]]; then
        log_error "This script only supports Linux"
        exit 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        'amd64' | 'x86_64')
            XRAY_ARCH="Xray-linux-64"
            ;;
        'armv8' | 'aarch64')
            XRAY_ARCH="Xray-linux-arm64-v8a"
            ;;
        *)
            log_error "Unsupported CPU architecture: $(uname -m)"
            exit 1
            ;;
    esac
}

detect_package_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_INSTALL="apt-get -y install"
    elif command -v yum &>/dev/null; then
        PKG_INSTALL="yum -y install"
    elif command -v apk &>/dev/null; then
        PKG_INSTALL="apk add"
    else
        log_error "No supported package manager found"
        exit 1
    fi
}

install_dependencies() {
    log_info "Installing dependencies..."
    local deps=(curl wget jq unzip)
    for dep in "${deps[@]}"; do
        if ! command -v "${dep}" &>/dev/null; then
            ${PKG_INSTALL} "${dep}"
        fi
    done
    log_info "Dependencies ready"
}

get_public_ip() {
    local ip
    ip=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "ip" | awk -F '=' '{print $2}')
    if [[ -z "${ip}" ]]; then
        ip=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "ip" | awk -F '=' '{print $2}')
    fi
    echo "${ip}"
}

install_xray() {
    log_info "Installing Xray-core..."

    if [[ -f "${INSTALL_DIR}/xray" ]]; then
        local current_version
        current_version=$("${INSTALL_DIR}/xray" --version | awk '{print $2}' | head -1)
        log_info "Xray-core already installed: v${current_version}"
        read -r -p "Reinstall/upgrade? [y/n]: " reinstall
        if [[ "${reinstall}" != "y" ]]; then
            return
        fi
        rm -f "${INSTALL_DIR}/xray"
    fi

    mkdir -p "${INSTALL_DIR}" "${CONF_DIR}"

    local version
    version=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=5" \
        | jq -r '.[] | select(.prerelease==false) | .tag_name' | head -1)

    if [[ -z "${version}" ]]; then
        log_error "Failed to fetch Xray-core version"
        exit 1
    fi
    log_info "Downloading Xray-core ${version}..."

    wget -q -P "${INSTALL_DIR}/" \
        "https://github.com/XTLS/Xray-core/releases/download/${version}/${XRAY_ARCH}.zip"

    if [[ ! -f "${INSTALL_DIR}/${XRAY_ARCH}.zip" ]]; then
        log_error "Download failed"
        exit 1
    fi

    unzip -o "${INSTALL_DIR}/${XRAY_ARCH}.zip" -d "${INSTALL_DIR}" >/dev/null
    rm -f "${INSTALL_DIR}/${XRAY_ARCH}.zip"
    chmod 755 "${INSTALL_DIR}/xray"

    # Download geodata
    local geo_version
    geo_version=$(curl -s "https://api.github.com/repos/Loyalsoldier/v2ray-rules-dat/releases?per_page=1" \
        | jq -r '.[].tag_name')
    if [[ -n "${geo_version}" ]]; then
        log_info "Downloading geodata ${geo_version}..."
        rm -f "${INSTALL_DIR}"/geo* 2>/dev/null
        wget -q -P "${INSTALL_DIR}/" \
            "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/${geo_version}/geosite.dat"
        wget -q -P "${INSTALL_DIR}/" \
            "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/${geo_version}/geoip.dat"
    fi

    log_info "Xray-core ${version} installed"
}

setup_systemd_service() {
    log_info "Setting up systemd service..."

    if [[ "${USE_PROTON_EXIT}" == "true" ]]; then
        cat > /etc/systemd/system/xray-proton.service <<EOF
[Unit]
Description=Xray Service (ProtonVPN exit)
Documentation=https://github.com/xtls
After=network.target nss-lookup.target wireproxy.service
Requires=wireproxy.service

[Service]
User=root
ExecStart=${INSTALL_DIR}/xray run -confdir ${PROTON_CONF_DIR}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=infinity
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray-proton.service
        log_info "Systemd service xray-proton configured"
    else
        cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=${INSTALL_DIR}/xray run -confdir ${CONF_DIR}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=infinity
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray.service
        log_info "Systemd service configured"
    fi
}

choose_reality_port() {
    echo
    read -r -p "Enter Reality listening port [Enter for random 10000-30000]: " REALITY_PORT
    if [[ -z "${REALITY_PORT}" ]]; then
        REALITY_PORT=$((RANDOM % 20001 + 10000))
    fi

    if ss -tlnp | grep -q ":${REALITY_PORT} "; then
        log_error "Port ${REALITY_PORT} is already in use"
        choose_reality_port
        return
    fi

    log_info "Reality port: ${REALITY_PORT}"
}

open_firewall_port() {
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "${REALITY_PORT}"/tcp >/dev/null 2>&1
        ufw allow "${REALITY_PORT}"/udp >/dev/null 2>&1
    elif command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        firewall-cmd --zone=public --add-port="${REALITY_PORT}"/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port="${REALITY_PORT}"/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

choose_target_domain() {
    local domain_list="download-installer.cdn.mozilla.net,addons.mozilla.org,s0.awsstatic.com,d1.awsstatic.com,images-na.ssl-images-amazon.com,m.media-amazon.com,player.live-video.net,one-piece.com,lol.secure.dyn.riotcdn.net,www.lovelive-anime.jp,academy.nvidia.com,dl.google.com,www.google-analytics.com,www.caltech.edu,www.python.org,vuejs.org,react.dev,www.java.com,www.oracle.com,www.mysql.com,www.mongodb.com,redis.io,cname.vercel-dns.com,www.swift.com,www.cisco.com,www.asus.com,www.samsung.com,www.amd.com,github.io"

    echo
    log_blue "============ Choose Reality Target Domain ============"
    log_warn "This is the domain Reality will impersonate (not yours)"
    log_warn "Format: domain:port (default port 443)"
    echo
    read -r -p "Enter target domain [Enter for random]: " REALITY_SERVER_NAME

    REALITY_DOMAIN_PORT=443

    if [[ -z "${REALITY_SERVER_NAME}" ]]; then
        local count
        count=$(echo "${domain_list}" | awk -F',' '{print NF}')
        local random_idx=$(( (RANDOM % count) + 1 ))
        REALITY_SERVER_NAME=$(echo "${domain_list}" | awk -F ',' -v n="${random_idx}" '{print $n}')
    fi

    if echo "${REALITY_SERVER_NAME}" | grep -q ":"; then
        REALITY_DOMAIN_PORT=$(echo "${REALITY_SERVER_NAME}" | awk -F ':' '{print $2}')
        REALITY_SERVER_NAME=$(echo "${REALITY_SERVER_NAME}" | awk -F ':' '{print $1}')
    fi

    # Check if domain is behind Cloudflare proxy
    local trace
    trace=$(curl -s "https://${REALITY_SERVER_NAME}/cdn-cgi/trace" 2>/dev/null | grep "visit_scheme=https" || true)
    if [[ -n "${trace}" ]]; then
        log_warn "This domain is behind Cloudflare proxy — others could route traffic through your server"
        read -r -p "Continue anyway? [y/n]: " cf_continue
        if [[ "${cf_continue}" != "y" ]]; then
            choose_target_domain
            return
        fi
    fi

    log_info "Target domain: ${REALITY_SERVER_NAME}:${REALITY_DOMAIN_PORT}"
}

generate_keys() {
    log_info "Generating X25519 keypair..."

    local key_output
    key_output=$("${INSTALL_DIR}/xray" x25519)
    REALITY_PRIVATE_KEY=$(echo "${key_output}" | grep "Private" | awk '{print $NF}')
    REALITY_PUBLIC_KEY=$(echo "${key_output}" | grep -i "public\|Password" | awk '{print $NF}')

    if [[ -z "${REALITY_PRIVATE_KEY}" || -z "${REALITY_PUBLIC_KEY}" ]]; then
        log_error "Key generation failed"
        exit 1
    fi

    log_info "Private Key: ${REALITY_PRIVATE_KEY}"
    log_info "Public Key:  ${REALITY_PUBLIC_KEY}"
}

generate_mldsa65() {
    MLDSA65_SEED=""
    MLDSA65_VERIFY=""

    if ! "${INSTALL_DIR}/xray" tls ping "${REALITY_SERVER_NAME}:${REALITY_DOMAIN_PORT}" 2>/dev/null | grep -q "X25519MLKEM768"; then
        log_info "Target domain does not support X25519MLKEM768 — skipping ML-DSA-65"
        return
    fi

    local length
    length=$("${INSTALL_DIR}/xray" tls ping "${REALITY_SERVER_NAME}:${REALITY_DOMAIN_PORT}" 2>/dev/null \
        | grep "Certificate chain's total length:" | awk '{print $5}' | head -1)

    if [[ -z "${length}" ]] || [[ "${length}" -le 3500 ]]; then
        log_info "Certificate chain too short for ML-DSA-65 — skipping"
        return
    fi

    log_info "Generating ML-DSA-65 keys..."
    local mldsa_output
    mldsa_output=$("${INSTALL_DIR}/xray" mldsa65)
    MLDSA65_SEED=$(echo "${mldsa_output}" | head -1 | awk '{print $2}')
    MLDSA65_VERIFY=$(echo "${mldsa_output}" | tail -1 | awk '{print $2}')
}

generate_uuid() {
    CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)
    log_info "Client UUID: ${CLIENT_UUID}"
}

# ── ProtonVPN wireproxy (WireGuard exit hop) ─────────────────────

install_wireproxy() {
    if command -v wireproxy &>/dev/null; then
        log_info "wireproxy already installed: $(which wireproxy)"
        return
    fi

    log_info "Installing wireproxy..."

    if ! command -v go &>/dev/null; then
        log_info "Installing Go..."
        local go_version="1.23.4"
        local arch
        case "$(uname -m)" in
            'amd64'|'x86_64') arch="amd64" ;;
            'aarch64'|'armv8') arch="arm64" ;;
            *) log_error "Unsupported arch for Go"; exit 1 ;;
        esac
        wget -q "https://go.dev/dl/go${go_version}.linux-${arch}.tar.gz" -O /tmp/go.tar.gz
        rm -rf /usr/local/go
        tar -C /usr/local -xzf /tmp/go.tar.gz
        rm -f /tmp/go.tar.gz
        export PATH="/usr/local/go/bin:${PATH}"
        export GOPATH="/root/go"
        export PATH="${GOPATH}/bin:${PATH}"
    fi

    export GOPROXY="https://proxy.golang.org,direct"
    go install github.com/windtf/wireproxy/cmd/wireproxy@latest

    if ! command -v wireproxy &>/dev/null; then
        local gopath="${GOPATH:-/root/go}"
        if [[ -f "${gopath}/bin/wireproxy" ]]; then
            ln -sf "${gopath}/bin/wireproxy" /usr/local/bin/wireproxy
        else
            log_error "wireproxy build failed"
            exit 1
        fi
    fi

    log_info "wireproxy installed: $(which wireproxy)"
}

install_proton_wg() {
    log_info "Setting up proton_wg..."

    mkdir -p "${PROTON_DIR}"

    # Install Python deps
    if ! command -v python3 &>/dev/null; then
        ${PKG_INSTALL} python3 python3-pip
    fi
    python3 -m pip install -q requests[socks] pynacl bcrypt 2>/dev/null || python3 -m pip install --break-system-packages -q requests[socks] pynacl bcrypt

    # Download proton_wg.py from repo
    wget -q "https://raw.githubusercontent.com/vhp8rc7p/proton-wg-config/main/proton_wg.py" \
        -O "${PROTON_DIR}/proton_wg.py"

    if [[ ! -f "${PROTON_DIR}/proton_wg.py" ]]; then
        log_error "Failed to download proton_wg.py"
        exit 1
    fi

    log_info "proton_wg.py installed to ${PROTON_DIR}/"
}

setup_proton_credentials() {
    echo
    log_blue "============ ProtonVPN Credentials ============"
    log_warn "These are used to authenticate with ProtonVPN API"
    log_warn "and generate a WireGuard config for the exit hop."
    echo
    read -r -p "ProtonVPN username (email): " PROTON_USER
    read -r -s -p "ProtonVPN password: " PROTON_PASS
    echo

    if [[ -z "${PROTON_USER}" || -z "${PROTON_PASS}" ]]; then
        log_error "Credentials cannot be empty"
        exit 1
    fi
}

choose_proton_country() {
    echo
    read -r -p "ProtonVPN exit country code [NL]: " PROTON_COUNTRY
    PROTON_COUNTRY="${PROTON_COUNTRY:-NL}"
    log_info "ProtonVPN exit country: ${PROTON_COUNTRY}"
}

generate_proton_wg_config() {
    log_info "Authenticating with ProtonVPN and generating WireGuard config..."

    cd "${PROTON_DIR}"
    python3 proton_wg.py -u "${PROTON_USER}" --password "${PROTON_PASS}" \
        -c "${PROTON_COUNTRY}" -s 0

    local wg_conf
    wg_conf=$(find "${PROTON_DIR}/configs" -name "*.conf" ! -name "*.wireproxy.conf" -type f | head -1)

    if [[ -z "${wg_conf}" ]]; then
        log_error "No WireGuard config generated"
        exit 1
    fi

    log_info "WireGuard config: ${wg_conf}"

    # Generate wireproxy config from WireGuard config
    python3 -c "
import sys
sys.path.insert(0, '${PROTON_DIR}')
from proton_wg import make_wireproxy_config
wp = make_wireproxy_config('${wg_conf}', ${WIREPROXY_SOCKS_PORT}, ${WIREPROXY_HTTP_PORT})
print(wp)
"
    log_info "wireproxy config generated"
}

setup_wireproxy_service() {
    log_info "Setting up wireproxy systemd service..."

    local wp_conf
    wp_conf=$(find "${PROTON_DIR}/configs" -name "*.wireproxy.conf" -type f | head -1)

    if [[ -z "${wp_conf}" ]]; then
        log_error "No wireproxy config found in ${PROTON_DIR}/configs/"
        exit 1
    fi

    # Stop any running wireproxy first
    pkill -f wireproxy 2>/dev/null || true
    sleep 1

    cat > /etc/systemd/system/wireproxy.service <<EOF
[Unit]
Description=wireproxy (ProtonVPN WireGuard tunnel)
After=network.target
Before=xray.service

[Service]
Type=simple
ExecStart=$(which wireproxy) -c ${wp_conf}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wireproxy.service
    systemctl start wireproxy.service

    # Wait for wireproxy tunnel to establish (WireGuard handshake takes ~6-10s)
    log_info "Waiting for WireGuard tunnel to establish..."
    local ready=false
    for i in $(seq 1 15); do
        if ! systemctl is-active wireproxy &>/dev/null; then
            log_error "wireproxy service crashed"
            journalctl -u wireproxy --no-pager -n 10
            exit 1
        fi
        if curl -s --socks5-hostname "127.0.0.1:${WIREPROXY_SOCKS_PORT}" \
            "https://api.ipify.org?format=json" --max-time 5 &>/dev/null; then
            ready=true
            break
        fi
        sleep 3
    done

    if ! ${ready}; then
        log_error "wireproxy tunnel failed to establish after 45s"
        journalctl -u wireproxy --no-pager -n 20
        exit 1
    fi

    local exit_ip
    exit_ip=$(curl -s --socks5-hostname "127.0.0.1:${WIREPROXY_SOCKS_PORT}" \
        "https://api.ipify.org?format=json" --max-time 10 | jq -r '.ip' 2>/dev/null)
    log_info "wireproxy tunnel ready — ProtonVPN exit IP: ${exit_ip}"
}

write_xray_config() {
    log_info "Writing Xray configuration..."

    local target_conf="${CONF_DIR}"
    if [[ "${USE_PROTON_EXIT}" == "true" ]]; then
        target_conf="${PROTON_CONF_DIR}"
    fi

    mkdir -p "${target_conf}"

    # Base outbound config
    cat > "${target_conf}/00_log.json" <<'EOF'
{
  "log": {
    "error": "/etc/xray-reality/error.log",
    "loglevel": "warning"
  }
}
EOF

    if [[ "${USE_PROTON_EXIT}" == "true" ]]; then
        cat > "${target_conf}/01_routing.json" <<'EOF'
{
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "direct_no_proxy"
      }
    ]
  }
}
EOF
    else
        cat > "${target_conf}/01_routing.json" <<'EOF'
{
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "z_direct_outbound"
      }
    ]
  }
}
EOF
    fi

    if [[ "${USE_PROTON_EXIT}" == "true" ]]; then
        cat > "${target_conf}/02_outbound.json" <<EOF
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
    else
        cat > "${target_conf}/02_outbound.json" <<'EOF'
{
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "z_direct_outbound"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blackhole_out"
    }
  ]
}
EOF
    fi

    # Reality inbound config — use different internal port to avoid conflict
    local internal_port=45987
    if [[ "${USE_PROTON_EXIT}" == "true" ]]; then
        internal_port=45988
    fi

    cat > "${target_conf}/07_VLESS_vision_reality_inbounds.json" <<EOF
{
  "inbounds": [
    {
      "tag": "dokodemo-in-VLESSReality",
      "port": ${REALITY_PORT},
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": ${internal_port},
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
      "port": ${internal_port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${CLIENT_UUID}",
            "email": "default-vless_reality_vision",
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
          "target": "${REALITY_SERVER_NAME}:${REALITY_DOMAIN_PORT}",
          "xver": 0,
          "serverNames": ["${REALITY_SERVER_NAME}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "publicKey": "${REALITY_PUBLIC_KEY}",
          "mldsa65Seed": "${MLDSA65_SEED}",
          "mldsa65Verify": "${MLDSA65_VERIFY}",
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
  ],
  "routing": {
    "rules": [
      {
        "inboundTag": ["dokodemo-in"],
        "domain": ["${REALITY_SERVER_NAME}"],
        "outboundTag": "z_direct_outbound"
      },
      {
        "inboundTag": ["dokodemo-in"],
        "outboundTag": "blackhole_out"
      }
    ]
  }
}
EOF

    log_info "Configuration written to ${target_conf}/"
}

start_xray() {
    local svc="xray"
    if [[ "${USE_PROTON_EXIT}" == "true" ]]; then
        svc="xray-proton"
    fi

    log_info "Starting ${svc}..."
    systemctl stop "${svc}" 2>/dev/null || true
    systemctl start "${svc}"

    sleep 1
    if systemctl is-active "${svc}" &>/dev/null; then
        log_info "${svc} started successfully"
    else
        log_error "${svc} failed to start — check logs:"
        log_error "  journalctl -u ${svc} --no-pager -n 20"
        exit 1
    fi
}

show_client_info() {
    local public_ip
    public_ip=$(get_public_ip)

    echo
    log_blue "================================================================"
    log_blue "                  Reality Deployment Complete"
    log_blue "================================================================"
    echo
    if [[ "${USE_PROTON_EXIT}" == "true" ]]; then
        local proton_ip
        proton_ip=$(curl -s --socks5-hostname "127.0.0.1:${WIREPROXY_SOCKS_PORT}" \
            "https://api.ipify.org?format=json" --max-time 10 | jq -r '.ip' 2>/dev/null)
        log_info "Mode:        VLESS + Reality + Vision → ProtonVPN (${PROTON_COUNTRY})"
        log_info "Exit IP:     ${proton_ip} (ProtonVPN, NOT server IP)"
    else
        log_info "Protocol:    VLESS + Reality + Vision"
    fi
    log_info "Server:      ${public_ip}"
    log_info "Port:        ${REALITY_PORT}"
    log_info "UUID:        ${CLIENT_UUID}"
    log_info "Flow:        xtls-rprx-vision"
    log_info "Security:    reality"
    log_info "SNI:         ${REALITY_SERVER_NAME}"
    log_info "Fingerprint: chrome"
    log_info "PublicKey:   ${REALITY_PUBLIC_KEY}"
    log_info "ShortId:     6ba85179e30d4fc2"
    if [[ -n "${MLDSA65_VERIFY}" ]]; then
        log_info "PQV:         ${MLDSA65_VERIFY}"
    fi
    echo

    local share_link="vless://${CLIENT_UUID}@${public_ip}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=6ba85179e30d4fc2&spx=%2F&type=tcp&headerType=none"
    if [[ -n "${MLDSA65_VERIFY}" ]]; then
        share_link="${share_link}&pqv=${MLDSA65_VERIFY}"
    fi
    # Remark name URL-encoded — some clients reject special chars in fragment
    local remark="VLESSReality"
    if [[ "${USE_PROTON_EXIT}" == "true" ]]; then
        remark="VLESSReality${PROTON_COUNTRY}Proton"
    fi
    share_link="${share_link}#${remark}"

    log_blue "Share link (VLESS):"
    echo -e "${GREEN}${share_link}${RESET}"
    echo

    log_blue "Clash Meta config:"
    cat <<EOF
  - name: "VLESS-Reality"
    type: vless
    server: ${public_ip}
    port: ${REALITY_PORT}
    uuid: ${CLIENT_UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SERVER_NAME}
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: 6ba85179e30d4fc2
    client-fingerprint: chrome
EOF
    echo
    log_blue "================================================================"
}

uninstall() {
    echo
    log_blue "What to uninstall?"
    log_blue "  a. Everything (xray + xray-proton + wireproxy)"
    log_blue "  b. Only ProtonVPN exit (xray-proton + wireproxy)"
    log_blue "  c. Only direct Reality (xray)"
    echo
    read -r -p "Select [a/b/c]: " unsub
    case "${unsub}" in
        a)
            log_warn "This will remove ALL Xray instances, wireproxy, and /etc/xray-reality"
            read -r -p "Continue? [y/n]: " confirm
            [[ "${confirm}" != "y" ]] && return
            systemctl stop xray 2>/dev/null || true
            systemctl disable xray 2>/dev/null || true
            systemctl stop xray-proton 2>/dev/null || true
            systemctl disable xray-proton 2>/dev/null || true
            systemctl stop wireproxy 2>/dev/null || true
            systemctl disable wireproxy 2>/dev/null || true
            rm -f /etc/systemd/system/xray.service
            rm -f /etc/systemd/system/xray-proton.service
            rm -f /etc/systemd/system/wireproxy.service
            systemctl daemon-reload
            rm -rf /etc/xray-reality
            ;;
        b)
            systemctl stop xray-proton 2>/dev/null || true
            systemctl disable xray-proton 2>/dev/null || true
            systemctl stop wireproxy 2>/dev/null || true
            systemctl disable wireproxy 2>/dev/null || true
            rm -f /etc/systemd/system/xray-proton.service
            rm -f /etc/systemd/system/wireproxy.service
            systemctl daemon-reload
            rm -rf "${PROTON_CONF_DIR}" "${PROTON_DIR}"
            ;;
        c)
            systemctl stop xray 2>/dev/null || true
            systemctl disable xray 2>/dev/null || true
            rm -f /etc/systemd/system/xray.service
            systemctl daemon-reload
            rm -rf "${CONF_DIR}"
            ;;
        *)
            log_error "Invalid selection"
            return
            ;;
    esac
    log_info "Uninstalled"
}

main() {
    echo
    log_blue "============================================"
    log_blue "   Xray Reality Standalone Installer"
    log_blue "============================================"
    echo
    log_blue "1. Install VLESS + Reality + Vision"
    log_blue "2. Install VLESS + Reality + Vision (ProtonVPN exit)"
    log_blue "3. Uninstall"
    echo
    read -r -p "Select [1/2/3]: " action

    case "${action}" in
        1)
            check_root
            check_os
            detect_arch
            detect_package_manager
            install_dependencies
            install_xray
            setup_systemd_service
            choose_reality_port
            open_firewall_port
            choose_target_domain
            generate_keys
            generate_mldsa65
            generate_uuid
            write_xray_config
            start_xray
            show_client_info
            ;;
        2)
            USE_PROTON_EXIT=true
            check_root
            check_os
            detect_arch
            detect_package_manager
            install_dependencies
            install_xray
            setup_systemd_service

            # ProtonVPN wireproxy setup
            install_wireproxy
            install_proton_wg
            setup_proton_credentials
            choose_proton_country
            generate_proton_wg_config
            setup_wireproxy_service

            # Reality setup
            choose_reality_port
            open_firewall_port
            choose_target_domain
            generate_keys
            generate_mldsa65
            generate_uuid
            write_xray_config
            start_xray
            show_client_info
            ;;
        3)
            check_root
            uninstall
            ;;
        *)
            log_error "Invalid selection"
            exit 1
            ;;
    esac
}

main "$@"
