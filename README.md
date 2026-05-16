# reality-one-click-install

One-click installer for Xray REALITY (VLESS + Vision). No domain required.

## What it does

Installs Xray-core on a Linux server and configures a VLESS + Reality + Vision inbound with:
- Random or user-chosen port
- Random or user-chosen target domain (SNI)
- Auto-generated X25519 keys and UUID
- ML-DSA-65 post-quantum support (if target domain supports it)
- Firewall rules (ufw/firewalld)
- systemd service

Outputs a ready-to-import v2rayN share link and Clash Meta config.

## Usage

```bash
bash <(curl -sL https://raw.githubusercontent.com/vhp8rc7p/reality-one-click-install/master/install_reality.sh)
```

Or download and run:

```bash
wget https://raw.githubusercontent.com/vhp8rc7p/reality-one-click-install/master/install_reality.sh
bash install_reality.sh
```

## Requirements

- Linux (Debian/Ubuntu, CentOS/Rocky, Alpine)
- Root access
- curl, wget, jq, unzip (auto-installed)

## ProtonVPN exit hop

To route REALITY traffic through ProtonVPN (hide your server IP), see [proton-wg-config-generator](https://github.com/vhp8rc7p/proton-wg-config-generator) which includes `setup_proton_exit.sh` for adding a ProtonVPN exit to an existing REALITY install.
