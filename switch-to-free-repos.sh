#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

source /etc/os-release
CODENAME="${VERSION_CODENAME:-}"
[[ -n "$CODENAME" ]] || { echo "Cannot detect Debian codename"; exit 1; }

ts="$(date +%F_%H%M%S)"
bak="/root/pve-repo-backup-$ts"
mkdir -p "$bak"

cp -a /etc/apt/sources.list "$bak/" 2>/dev/null || true
cp -a /etc/apt/sources.list.d "$bak/" 2>/dev/null || true

echo "[*] Disable enterprise repos"

if [[ -f /etc/apt/sources.list.d/pve-enterprise.list ]]; then
  sed -i -E 's/^deb/# deb/g' /etc/apt/sources.list.d/pve-enterprise.list
fi

grep -Rsl "enterprise.proxmox.com" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null \
 | while read -r f; do
     sed -i -E 's/^deb/# deb/g' "$f"
   done

echo "[*] Add no-subscription repo"

cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve $CODENAME pve-no-subscription
EOF

echo "[*] apt update"
apt-get update

echo
echo "[+] Done"
echo "Backup: $bak"
