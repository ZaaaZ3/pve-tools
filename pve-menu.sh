#!/usr/bin/env bash
set -euo pipefail

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти от root"
    exit 1
  fi
}

detect_codename() {
  source /etc/os-release
  if [[ -z "${VERSION_CODENAME:-}" ]]; then
    echo "Не удалось определить Debian codename (VERSION_CODENAME)"
    exit 1
  fi
  echo "$VERSION_CODENAME"
}

backup_apt_lists() {
  local ts bak
  ts="$(date +%F_%H%M%S)"
  bak="/root/pve-apt-backup-$ts"
  mkdir -p "$bak"
  cp -a /etc/apt/sources.list "$bak/" 2>/dev/null || true
  cp -a /etc/apt/sources.list.d "$bak/" 2>/dev/null || true
  echo "$bak"
}

switch_repos_to_free() {
  local codename bak
  codename="$(detect_codename)"
  bak="$(backup_apt_lists)"
  echo "[*] Бэкап репозиториев: $bak"

  # Комментируем enterprise в отдельном файле
  if [[ -f /etc/apt/sources.list.d/pve-enterprise.list ]]; then
    sed -i -E 's/^[[:space:]]*deb([[:space:]].*)/# deb\1/g' /etc/apt/sources.list.d/pve-enterprise.list
    echo "[*] Отключён: /etc/apt/sources.list.d/pve-enterprise.list"
  fi

  # Комментируем любые enterprise строки где угодно
  if grep -Rqs "enterprise\.proxmox\.com" /etc/apt/sources.list /etc/apt/sources.list.d; then
    grep -Rsl "enterprise\.proxmox\.com" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null \
      | while read -r f; do
          sed -i -E 's/^[[:space:]]*deb([[:space:]].*enterprise\.proxmox\.com)/# deb\1/g' "$f"
        done
    echo "[*] Enterprise строки закомментированы."
  fi

  # Добавляем pve-no-subscription
  cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve $codename pve-no-subscription
EOF
  echo "[*] Добавлен: /etc/apt/sources.list.d/pve-no-subscription.list"

  echo "[*] apt update..."
  apt-get update
  echo "[+] Готово."
}

create_user_sdv() {
  local user="sdv"
  local realm="pam"
  local pass="123"

  # Проверка: не существует ли уже
  if pveum user list | awk '{print $1}' | grep -qx "${user}@${realm}"; then
    echo "[*] Пользователь ${user}@${realm} уже существует — обновляю пароль."
  else
    echo "[*] Создаю пользователя: ${user}@${realm}"
    # comment можно убрать/изменить
    pveum user add "${user}@${realm}" --comment "Created by pve-menu"
  fi

  echo "[*] Устанавливаю пароль..."
  printf "%s\n%s\n" "$pass" "$pass" | pveum passwd "${user}@${realm}"

  echo "[+] Готово: ${user}@${realm} пароль: ${pass}"
  echo "    (Realm pam означает системную учётку PVE, это нормально для стендов.)"
}

main_menu() {
  need_root

  while true; do
    echo
    echo "===== Proxmox quick menu ====="
    echo "1) Включить бесплатный репозиторий (no-subscription) и отключить enterprise"
    echo "2) Создать пользователя sdv@pam с паролем 123"
    echo "3) Выход"
    echo "=============================="
    read -r -p "Выбор [1-3]: " choice

    case "$choice" in
      1) switch_repos_to_free ;;
      2) create_user_sdv ;;
      3) exit 0 ;;
      *) echo "Неверный выбор" ;;
    esac
  done
}

main_menu
