#!/usr/bin/env bash
set -euo pipefail

# ===== Root check =====
if [[ $EUID -ne 0 ]]; then
  echo "Запусти от root"
  exit 1
fi

detect_codename() {
  source /etc/os-release
  [[ -n "${VERSION_CODENAME:-}" ]] || { echo "Не удалось определить Debian codename"; exit 1; }
  echo "$VERSION_CODENAME"
}

backup_apt() {
  local ts bak
  ts="$(date +%F_%H%M%S)"
  bak="/root/pve-apt-backup-$ts"
  mkdir -p "$bak"
  cp -a /etc/apt/sources.list "$bak/" 2>/dev/null || true
  cp -a /etc/apt/sources.list.d "$bak/" 2>/dev/null || true
  echo "$bak"
}

# --- Disable in .list format (comment out deb lines)
disable_list_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  # comment only active deb lines
  sed -i -E 's/^[[:space:]]*deb[[:space:]]+/# deb /' "$f"
}

# --- Disable in Deb822 (.sources) format by setting Enabled: no (or appending if missing)
disable_sources_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0

  # If "Enabled:" exists anywhere, set it to no
  if grep -qiE '^[[:space:]]*Enabled[[:space:]]*:' "$f"; then
    sed -i -E 's/^[[:space:]]*Enabled[[:space:]]*:.*/Enabled: no/I' "$f"
  else
    # Append a line like you asked ("enable=false" style) at end
    # Deb822 uses "Enabled: no/yes", so we append that.
    printf "\nEnabled: no\n" >> "$f"
  fi
}

# Disable all enterprise repo definitions we can find (both formats)
disable_enterprise_repos() {
  local changed=0

  # Typical Proxmox enterprise repo files:
  for f in \
    /etc/apt/sources.list.d/pve-enterprise.list \
    /etc/apt/sources.list.d/pve-enterprise.sources \
    /etc/apt/sources.list.d/ceph.list \
    /etc/apt/sources.list.d/ceph.sources
  do
    if [[ -f "$f" ]]; then
      if [[ "$f" == *.list ]]; then
        if grep -qE '^[[:space:]]*deb[[:space:]]+https?://enterprise\.proxmox\.com|^[[:space:]]*deb[[:space:]]+https?://.*proxmox.*enterprise' "$f" 2>/dev/null \
           || grep -q "enterprise.proxmox.com" "$f" 2>/dev/null; then
          disable_list_file "$f"
          changed=1
        fi
      elif [[ "$f" == *.sources ]]; then
        if grep -qi "enterprise.proxmox.com" "$f" 2>/dev/null; then
          disable_sources_file "$f"
          changed=1
        fi
      fi
    fi
  done

  # Also scan any other apt source files for enterprise.proxmox.com
  # .list
  while IFS= read -r f; do
    disable_list_file "$f"
    changed=1
  done < <(grep -Rsl "enterprise\.proxmox\.com" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -E '\.list$' || true)

  # .sources
  while IFS= read -r f; do
    disable_sources_file "$f"
    changed=1
  done < <(grep -Rsl "enterprise\.proxmox\.com" /etc/apt/sources.list.d 2>/dev/null | grep -E '\.sources$' || true)

  if [[ $changed -eq 1 ]]; then
    echo "[*] Enterprise репозитории отключены (в т.ч. через Enabled: no где возможно)."
  else
    echo "[*] Enterprise репозитории не найдены (или уже отключены)."
  fi
}

enable_free_repo() {
  local codename
  codename="$(detect_codename)"

  cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve $codename pve-no-subscription
EOF

  echo "[*] Добавлен бесплатный репозиторий: pve-no-subscription ($codename)"
}

switch_repos_menu() {
  local bak
  bak="$(backup_apt)"
  echo "[*] Бэкап репозиториев: $bak"

  disable_enterprise_repos
  enable_free_repo

  echo "[*] apt update..."
  apt-get update
  echo "[+] Готово."
}

prompt_password() {
  local p1 p2
  while true; do
    read -rsp "Введите пароль для sdv@pve (мин. 8 символов): " p1
    echo
    read -rsp "Повторите пароль: " p2
    echo

    if [[ "$p1" != "$p2" ]]; then
      echo "Пароли не совпадают. Повтори."
      continue
    fi
    if (( ${#p1} < 8 )); then
      echo "Пароль слишком короткий (нужно минимум 8 символов)."
      continue
    fi

    printf "%s" "$p1"
    return 0
  done
}

create_user_sdv_pve() {
  local user="sdv"
  local realm="pve"
  local pass

  pass="$(prompt_password)"

  if pveum user list | awk '{print $1}' | grep -qx "${user}@${realm}"; then
    echo "[*] Пользователь ${user}@${realm} уже существует — обновляю пароль"
    pveum user modify "${user}@${realm}" --password "$pass"
  else
    echo "[*] Создаю пользователя ${user}@${realm}"
    pveum user add "${user}@${realm}" --password "$pass" --comment "Created by pve-menu"
  fi

  echo "[+] Пользователь готов: ${user}@${realm}"
}

# ===== Main menu =====
while true; do
  echo
  echo "========= Proxmox Quick Menu ========="
  echo "1) Включить бесплатный репозиторий + отключить enterprise (Enabled: no / # deb)"
  echo "2) Создать/обновить пользователя sdv@pve (пароль задаётся вручную)"
  echo "3) Выход"
  echo "======================================"
  read -rp "Выбор [1-3]: " choice

  case "${choice:-}" in
    1) switch_repos_menu ;;
    2) create_user_sdv_pve ;;
    3) exit 0 ;;
    *) echo "Неверный выбор" ;;
  esac
done
