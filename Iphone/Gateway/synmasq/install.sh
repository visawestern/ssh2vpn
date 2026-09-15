#!/bin/sh
# Installs the SYN masquerader on the VPS. Needs root. Idempotent.
# Usage: sudo ./install.sh
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
DST=/opt/synmasq

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root (sudo ./install.sh)" >&2
  exit 1
fi

apt-get update -qq
apt-get install -y -qq libnetfilter-queue-dev python3-venv iptables > /dev/null

mkdir -p "$DST"
cp "$SRC/synmasq.py" "$DST/"
[ ! -d "$DST/venv" ] && python3 -m venv "$DST/venv"
"$DST/venv/bin/pip" install --quiet NetfilterQueue

cp "$SRC/synmasq.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now synmasq.service
sleep 1
systemctl is-active --quiet synmasq.service && echo "synmasq ACTIVE" || {
  echo "FAILED to start:"; journalctl -u synmasq.service --no-pager -n 20; exit 1; }

echo "--- self-check: unit tests + offline detector proof ---"
"$DST/venv/bin/python" "$SRC/test_synmasq.py" 2>&1 | tail -3
echo "--- mangle taps ---"
iptables -t mangle -L OUTPUT -n | grep -i nfqueue || true
ip6tables -t mangle -L OUTPUT -n | grep -i nfqueue || true
echo "done. Verify from an iPhone via VPN: https://proxydetect.live/tcpip.html"
echo "expect: TCP/IP Detected OS = iOS, 'Matches User-Agent'."
