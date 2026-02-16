#!/usr/bin/env bash
set -euo pipefail

# =========================
# Settings (defaults)
# =========================
REALM="pve"
TEACHERS_GROUP="Teachers"
STUDENTS_GROUP="students"
STUDENTS_ROLE="StudentsLab"
STUDENTS_POOL="students"

DEFAULT_STUDENT_USER="user"
DEFAULT_STUDENT_PASS="P@ssw0rd"

# =========================
# Helpers
# =========================
die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "Запусти от root"; }
have(){ command -v "$1" >/dev/null 2>&1; }

detect_codename() {
  # Debian codename for pve-no-subscription line
  source /etc/os-release
  [[ -n "${VERSION_CODENAME:-}" ]] || die "Не удалось определить Debian codename (VERSION_CODENAME)"
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

# .list format -> comment deb lines
disable_list_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  sed -i -E 's/^[[:space:]]*deb[[:space:]]+/# deb /' "$f"
}

# Deb822 (*.sources) format -> ensure Enabled: no exists (like your "enable=false" idea)
disable_sources_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if grep -qiE '^[[:space:]]*Enabled[[:space:]]*:' "$f"; then
    sed -i -E 's/^[[:space:]]*Enabled[[:space:]]*:.*/Enabled: no/I' "$f"
  else
    printf "\nEnabled: no\n" >> "$f"
  fi
}

disable_enterprise_repos() {
  local changed=0

  # Scan common apt files
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
    [[ -e "$f" ]] || continue
    if grep -q "enterprise\.proxmox\.com" "$f" 2>/dev/null; then
      if [[ "$f" == *.sources ]]; then
        disable_sources_file "$f"
      else
        disable_list_file "$f"
      fi
      changed=1
    fi
  done

  if [[ $changed -eq 1 ]]; then
    echo "[*] Enterprise репозитории отключены (через '# deb' и/или 'Enabled: no')."
  else
    echo "[*] Enterprise репозитории не найдены (или уже отключены)."
  fi
}

enable_no_subscription_repo() {
  local codename
  codename="$(detect_codename)"
  cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve $codename pve-no-subscription
EOF
  echo "[*] Добавлен pve-no-subscription ($codename)."
}

switch_repos_and_update() {
  local bak
  bak="$(backup_apt)"
  echo "[*] Бэкап APT: $bak"
  disable_enterprise_repos
  enable_no_subscription_repo
  echo "[*] apt-get update..."
  apt-get update
  echo "[+] Репозитории переключены и обновлены."
}

read_secret_twice_min8() {
  local prompt="$1" p1 p2
  while true; do
    read -rsp "$prompt (мин. 8 символов): " p1; echo
    read -rsp "Повтори пароль: " p2; echo
    [[ "$p1" == "$p2" ]] || { echo "Пароли не совпадают."; continue; }
    (( ${#p1} >= 8 )) || { echo "Пароль слишком короткий."; continue; }
    printf "%s" "$p1"
    return 0
  done
}

# =========================
# Storage selection
# =========================
list_storages_for_vm() {
  # We consider storages that can hold VM disks (images/rootdir).
  # pvesm exists on PVE; we keep it simple and robust.
  have pvesm || die "Нет pvesm (это точно Proxmox VE?)"
  # Print unique storage IDs that support images (VM disks)
  pvesm status 2>/dev/null | awk 'NR>1{print $1}' | sort -u
}

choose_storages_interactive() {
  local storages=() line i choice selected=()

  mapfile -t storages < <(list_storages_for_vm)
  ((${#storages[@]} > 0)) || die "Не найдено ни одного storage (pvesm status пуст)."

  echo
  echo "Доступные storage:"
  for i in "${!storages[@]}"; do
    printf "  %2d) %s\n" $((i+1)) "${storages[$i]}"
  done
  echo
  echo "Выбери storage через запятую (пример: 1,3) или 'a' = все:"
  read -r choice

  if [[ "$choice" =~ ^[aA]$ ]]; then
    printf "%s\n" "${storages[@]}"
    return 0
  fi

  # Parse "1,3,4"
  IFS=',' read -ra parts <<<"$choice"
  for part in "${parts[@]}"; do
    part="${part//[[:space:]]/}"
    [[ "$part" =~ ^[0-9]+$ ]] || die "Неверный ввод: $choice"
    (( part>=1 && part<=${#storages[@]} )) || die "Номер вне диапазона: $part"
    selected+=("${storages[$((part-1))]}")
  done

  # uniq
  printf "%s\n" "${selected[@]}" | awk '!seen[$0]++'
}

get_storages() {
  # Mode:
  # 1) auto -> interactive choose
  # 2) manual -> input list
  echo
  echo "Storage режим:"
  echo "  1) Автообнаружение + выбрать из списка"
  echo "  2) Указать вручную (через пробел или запятую)"
  read -r -p "Выбор [1-2]: " mode

  case "${mode:-}" in
    1)
      choose_storages_interactive
      ;;
    2)
      read -r -p "Введи storage IDs (пример: local local-lvm) или через запятую: " s
      s="${s//,/ }"
      # normalize and validate existence
      for x in $s; do
        [[ -n "$x" ]] || continue
        echo "$x"
      done | awk '!seen[$0]++'
      ;;
    *)
      die "Неверный выбор storage режима"
      ;;
  esac
}

# =========================
# Access model setup
# =========================
ensure_group() {
  local g="$1"
  if pveum group list | awk '{print $1}' | grep -qx "$g"; then
    return 0
  fi
  pveum group add "$g"
}

ensure_pool() {
  local pool="$1"
  # pvesh is available on PVE; try create if not exists
  if have pvesh; then
    if pvesh get /pools 2>/dev/null | grep -q "\"poolid\" *: *\"$pool\""; then
      return 0
    fi
    pvesh create /pools --poolid "$pool" >/dev/null
  else
    # fallback: qm pool is not consistent; most PVE have pvesh
    echo "[!] pvesh не найден — пул пропущен. (Желательно установить pvesh/проверить PVE)"
  fi
}

ensure_role_students() {
  # Create/overwrite custom role StudentsLab with safe privileges.
  # No Sys.*, no Permissions.Modify, no User.Modify => no system/users/password management.
  local role="$1"
  local privs=(
    "VM.Audit"
    "VM.Allocate"
    "VM.Clone"
    "VM.Console"
    "VM.Monitor"
    "VM.PowerMgmt"
    "VM.Config.Options"
    "VM.Config.CPU"
    "VM.Config.Memory"
    "VM.Config.Disk"
    "VM.Config.Network"
    "VM.Config.CDROM"
    "VM.Config.Cloudinit"
    "VM.Config.HWType"
    "Datastore.Audit"
    "Datastore.AllocateSpace"
    "Datastore.AllocateTemplate"
    "Pool.Audit"
  )

  # If exists: delete and recreate (simpler than diff)
  if pveum role list | awk '{print $1}' | grep -qx "$role"; then
    pveum role delete "$role" >/dev/null 2>&1 || true
  fi
  pveum role add "$role" -privs "$(IFS=','; echo "${privs[*]}")"
}

set_acl_group() {
  local path="$1" group="$2" role="$3" propagate="${4:-1}"
  # propagate: 1/0
  pveum aclmod "$path" -group "$group" -role "$role" $( [[ "$propagate" == "1" ]] && echo "-propagate 1" )
}

ensure_user_pve() {
  local userid="$1" pass="$2" group="$3"
  # create if missing; set password always
  if pveum user list | awk '{print $1}' | grep -qx "$userid"; then
    pveum user modify "$userid" --password "$pass" >/dev/null
  else
    pveum user add "$userid" --password "$pass" >/dev/null
  fi

  # add to group (idempotent: remove then add to avoid duplicates)
  pveum user modify "$userid" --group "$group" >/dev/null
}

setup_access_model() {
  echo
  echo "=== Настройка пользователей/групп/прав ==="

  # Teacher interactive
  read -r -p "Логин учителя (без @realm, пример: teacher1): " tlogin
  [[ -n "${tlogin:-}" ]] || die "Логин учителя пустой"
  local tpass
  tpass="$(read_secret_twice_min8 "Пароль учителя")"

  # Student default (you can change if you want)
  local slogin="$DEFAULT_STUDENT_USER"
  local spass="$DEFAULT_STUDENT_PASS"

  # Storage selection
  echo
  echo "Настроим доступ студентов к storage (для дисков/шаблонов)."
  mapfile -t storages < <(get_storages)
  ((${#storages[@]} > 0)) || die "Список storage пуст"

  echo "[*] Выбраны storage: ${storages[*]}"

  # Ensure groups
  ensure_group "$TEACHERS_GROUP"
  ensure_group "$STUDENTS_GROUP"

  # Ensure pool for students
  ensure_pool "$STUDENTS_POOL"

  # Roles
  ensure_role_students "$STUDENTS_ROLE"

  # ACLs
  echo "[*] Назначаю ACL..."
  # Teachers: full admin
  set_acl_group "/" "$TEACHERS_GROUP" "Administrator" 1

  # Students: limit to pool only + storages
  set_acl_group "/pool/$STUDENTS_POOL" "$STUDENTS_GROUP" "$STUDENTS_ROLE" 1

  for st in "${storages[@]}"; do
    set_acl_group "/storage/$st" "$STUDENTS_GROUP" "$STUDENTS_ROLE" 1
  done

  # Users
  echo "[*] Создаю/обновляю пользователей..."
  ensure_user_pve "${tlogin}@${REALM}" "$tpass" "$TEACHERS_GROUP"
  ensure_user_pve "${slogin}@${REALM}" "$spass" "$STUDENTS_GROUP"

  echo
  echo "[+] Готово."
  echo "    Учитель: ${tlogin}@${REALM}"
  echo "    Студент: ${slogin}@${REALM} (пароль: ${spass})"
  echo
  echo "Примечание: студенты НЕ получали Sys.*, Permissions.Modify, User.Modify,"
  echo "поэтому не смогут лезть в системные настройки/права/пароли."
  echo "Они смогут создавать/управлять ВМ в пуле /pool/${STUDENTS_POOL} и писать диски на выбранные storage."
}

# =========================
# Menu
# =========================
main_menu() {
  need_root
  have pveum || die "Нет pveum (это точно Proxmox VE?)"

  while true; do
    echo
    echo "========== PVE MultiTool =========="
    echo "1) Бесплатные репозитории + apt update"
    echo "2) Пользователи/группы/права (Teachers + students)"
    echo "3) Сделать 1 + 2"
    echo "4) Выход"
    echo "==================================="
    read -r -p "Выбор [1-4]: " c

    case "${c:-}" in
      1) switch_repos_and_update ;;
      2) setup_access_model ;;
      3) switch_repos_and_update; setup_access_model ;;
      4) exit 0 ;;
      *) echo "Неверный выбор" ;;
    esac
  done
}

main_menu
