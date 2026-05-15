#!/usr/bin/env bash
# Refresh ProtonVPN WireGuard session and reload wireproxy
# Run this when the exit IP reverts to your VPS IP (session/key expired)

set -euo pipefail

PROTON_DIR="/root/proton-wg-config"
WIREPROXY_CONF="${PROTON_DIR}/configs/NL-FREE79.wireproxy.conf"
WIREPROXY_SOCKS_PORT=40000
WIREPROXY_HTTP_PORT=40001
PROTON_USER="vhp8rc7p@gmail.com"
PROTON_COUNTRY="${1:-NL}"

GREEN='\033[32m'
RED='\033[31m'
BLUE='\033[34m'
RESET='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*"; }
log_blue()  { echo -e "${BLUE}$*${RESET}"; }

log_blue "=== Refreshing ProtonVPN WireGuard session ==="
echo

# Show before
log_info "Before refresh:"
before_ip=$(curl -s --socks5-hostname "127.0.0.1:${WIREPROXY_SOCKS_PORT}" \
    --max-time 5 https://api.ipify.org 2>/dev/null || echo "unreachable")
echo "  Exit IP via wireproxy: ${before_ip}"
echo

cd "${PROTON_DIR}"
source venv/bin/activate

# Step 1: Generate new WireGuard config (uses cached session, else prompts)
log_info "Generating new WireGuard config (country: ${PROTON_COUNTRY})..."
python proton_wg.py -u "${PROTON_USER}" -c "${PROTON_COUNTRY}" -s 0

# Step 2: Find the newly created .conf
new_wg=$(ls -t configs/*.conf 2>/dev/null | grep -v wireproxy | head -1)
if [[ -z "${new_wg}" ]]; then
    log_error "No new WireGuard config found"
    exit 1
fi
log_info "New WG config: ${new_wg}"

# Step 3: Generate wireproxy config, pinning to the same expected filename
log_info "Building wireproxy config at ${WIREPROXY_CONF}..."
python -c "
from proton_wg import make_wireproxy_config
import shutil
wp = make_wireproxy_config('${new_wg}', ${WIREPROXY_SOCKS_PORT}, ${WIREPROXY_HTTP_PORT})
# Move/rename to the stable path the systemd service points at
shutil.move(wp, '${WIREPROXY_CONF}')
print('Wireproxy config written to: ${WIREPROXY_CONF}')
"

# Step 4: Restart wireproxy
log_info "Restarting wireproxy.service..."
systemctl restart wireproxy.service

# Step 5: Wait for tunnel
log_info "Waiting for WireGuard handshake..."
ready=false
for i in $(seq 1 15); do
    if curl -s --socks5-hostname "127.0.0.1:${WIREPROXY_SOCKS_PORT}" \
        --max-time 5 https://api.ipify.org &>/dev/null; then
        ready=true
        break
    fi
    echo "  ... attempt ${i}/15"
    sleep 3
done

if ! ${ready}; then
    log_error "wireproxy tunnel failed to come up"
    journalctl -u wireproxy --no-pager -n 20
    exit 1
fi

# Step 6: Verify exit IP
after_ip=$(curl -s --socks5-hostname "127.0.0.1:${WIREPROXY_SOCKS_PORT}" \
    --max-time 10 https://api.ipify.org)
echo
log_blue "=== Refresh complete ==="
echo "  Before: ${before_ip}"
echo "  After:  ${after_ip}"
if [[ "${after_ip}" == "$(curl -s --max-time 5 https://api.ipify.org)" ]]; then
    log_error "Exit IP equals server IP — tunnel NOT working!"
    exit 1
fi
log_info "wireproxy is healthy. xray-proton will keep using it automatically."
