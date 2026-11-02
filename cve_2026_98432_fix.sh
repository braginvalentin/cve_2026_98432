
#!/bin/bash
set -e

SERVICE="cve_2026_98432"
SCRIPT="/usr/local/sbin/${SERVICE}-firewall"
UNIT="/etc/systemd/system/${SERVICE}.service"
SYSCTL="/etc/sysctl.d/99-disable-mptcp.conf"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root"
    exit 1
fi

if ! command -v iptables >/dev/null 2>&1; then
    echo "ERROR: iptables is not installed"
    exit 1
fi

echo "========== SYSTEM =========="
hostnamectl
echo
uname -r
echo
iptables -V
echo

IPT_VERSION=$(iptables -V)

case "$IPT_VERSION" in
    *legacy*)
        BACKEND="legacy"
        ;;
    *nf_tables*)
        BACKEND="nf_tables"
        ;;
    *)
        echo "ERROR: Cannot determine iptables backend"
        exit 1
        ;;
esac

echo "Detected backend: $BACKEND"

echo
echo "========== INSTALL FIREWALL SCRIPT =========="

cat > "$SCRIPT" <<'EOF'
#!/bin/bash
set -e

IPT_VERSION=$(iptables -V)

case "$IPT_VERSION" in
    *legacy*)
        if command -v iptables-legacy >/dev/null 2>&1; then
            IPT="iptables-legacy"
        else
            IPT="iptables"
        fi
        ;;
    *nf_tables*)
        if command -v iptables-nft >/dev/null 2>&1; then
            IPT="iptables-nft"
        else
            IPT="iptables"
        fi
        ;;
    *)
        echo "ERROR: Unknown iptables backend"
        exit 1
        ;;
esac

RULE=(-p tcp -m u32 --u32 '0>>24&0x0f=6:15' -j DROP)

if ! "$IPT" -w 10 -t raw -C PREROUTING "${RULE[@]}" 2>/dev/null; then
    "$IPT" -w 10 -t raw -I PREROUTING 1 "${RULE[@]}"
    echo "CVE-2026-98432: firewall rule added ($IPT)"
else
    echo "CVE-2026-98432: firewall rule already exists ($IPT)"
fi
EOF

chmod 755 "$SCRIPT"

echo
echo "========== INSTALL SYSTEMD UNIT =========="

cat > "$UNIT" <<EOF
[Unit]
Description=CVE-2026-98432 Firewall Mitigation
DefaultDependencies=yes
After=local-fs.target
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=$SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=network-pre.target
EOF

echo
echo "========== DISABLE MPTCP =========="

cat > "$SYSCTL" <<'EOF'
net.mptcp.enabled = 0
EOF

if [[ -e /proc/sys/net/mptcp/enabled ]]; then
    sysctl -w net.mptcp.enabled=0
else
    echo "MPTCP sysctl is unavailable in the running kernel"
fi

echo
echo "========== ENABLE SERVICE =========="

systemctl daemon-reload
systemctl enable --now "${SERVICE}.service"

echo
echo "========== RESULT =========="

systemctl status "${SERVICE}.service" --no-pager || true

echo
echo "Firewall rules:"
case "$BACKEND" in
    legacy)
        iptables-legacy -t raw -L PREROUTING -n -v 2>/dev/null || true
        ;;
    nf_tables)
        iptables-nft -t raw -L PREROUTING -n -v 2>/dev/null || true
        ;;
esac

echo
echo "MPTCP:"
sysctl net.mptcp.enabled 2>/dev/null || true

echo
echo "Installation completed."

