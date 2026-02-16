#!/usr/bin/env bash
set -euo pipefail

REALM="pve"

TEACHERS_GROUP="Teachers"
STUDENTS_GROUP="students"
STUDENTS_POOL="students"
STUDENTS_ROLE="StudentsLab"

DEFAULT_STUDENT_USER="user"
DEFAULT_STUDENT_PASS="P@ssw0rd"

die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "Запусти от root"; }
have(){ command -v "$1" >/dev/null 2>&1; }

validate_userid_localpart() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ ]]
}

# ---------- repos ----------
detect_codename(){ source /etc/os-release; [[ -n "${VERSION_CODENAME:-}" ]] || die "No VERSION_CODENAME"; echo "$VERSION_CODENAME"; }

backup_apt() {
  local ts bak
  ts="$(date +%F_%H%M%S)"
  bak="/root/pve-apt-backup-$ts"
  mkdir -p "$bak"
  cp -a /etc/apt/sources.list "$bak/" 2>/dev/null || true
  cp -a /etc/apt/sources.list.d "$bak/" 2>/dev/null || true
  echo "$bak"
}

disable_list_file(){ [[ -f "$1" ]] && sed -i -E 's/^[[:space:]]*deb[[:space:]]+/# deb /' "$1"; }

disable_sources_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if grep -qiE '^[[:space:]]*Enabled[[:space:]]*:' "$f"; then
    sed -i -E 's/^[[:space:]]*Enabled[[:space:]]*:.*/Enabled: no/I' "$f"
  else
    printf "\nEnabled: no\n" >> "$f"
  fi
}

switch_repos_and_update() {
  local bak; bak="$(backup_apt)"
  echo "[*] Бэкап APT: $bak" >&2

  local changed=0
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
    [[ -e "$f" ]] || continue
    if grep -q "enterprise\.proxmox\.com" "$f" 2>/dev/null; then
      [[ "$f" == *.sources ]] && disable_sources_file "$f" || disable_list_file "$f"
      changed=1
    fi
  done
  [[ $changed -eq 1 ]] && echo "[*] Enterprise отключён" >&2 || echo "[*] Enterprise не найден/уже отключён" >&2

  local codename; codename="$(detect_codename)"
  cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve $codename pve-no-subscription
EOF
  echo "[*] Добавлен pve-no-subscription ($codename)" >&2
  apt-get update
  echo "[+] apt update OK" >&2
}

# ---------- password ----------
read_secret_twice_min8() {
  local prompt="$1" p1 p2
  while true; do
    read -rsp "$prompt (мин. 8 символов): " p1; echo >&2
    read -rsp "Повтори пароль: " p2; echo >&2
    [[ "$p1" == "$p2" ]] || { echo "Пароли не совпадают." >&2; continue; }
    (( ${#p1} >= 8 )) || { echo "Пароль слишком короткий." >&2; continue; }
    printf "%s" "$p1"
    return 0
  done
}

# ---------- storage ----------
list_storages_images() {
  have pvesm || die "Нет pvesm"
  if have timeout; then
    timeout 5s pvesm status --content images 2>/tmp/pvesm_status.err | awk 'NR>1{print $1}' | sort -u
  else
    pvesm status --content images 2>/tmp/pvesm_status.err | awk 'NR>1{print $1}' | sort -u
  fi
}

storage_exists_any() {
  local sid="$1"
  pvesm status 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$sid"
}

choose_storages_interactive() {
  local storages=() i choice selected=()
  mapfile -t storages < <(list_storages_images || true)
  ((${#storages[@]} > 0)) || return 1

  echo "Доступные storage (images):" >&2
  for i in "${!storages[@]}"; do printf "  %2d) %s\n" $((i+1)) "${storages[$i]}" >&2; done
  echo "Выбери через запятую или 'a' = все:" >&2
  read -r choice

  if [[ "$choice" =~ ^[aA]$ ]]; then
    printf "%s\n" "${storages[@]}"; return 0
  fi

  IFS=',' read -ra parts <<<"$choice"
  for part in "${parts[@]}"; do
    part="${part//[[:space:]]/}"
    [[ "$part" =~ ^[0-9]+$ ]] || die "Неверный ввод: $choice"
    (( part>=1 && part<=${#storages[@]} )) || die "Номер вне диапазона: $part"
    selected+=("${storages[$((part-1))]}")
  done
  printf "%s\n" "${selected[@]}" | awk '!seen[$0]++'
}

get_storages() {
  echo "Storage режим:" >&2
  echo "  1) Автообнаружение (images) + выбрать" >&2
  echo "  2) Ввести вручную" >&2
  read -r -p "Выбор [1-2]: " mode

  case "${mode:-}" in
    1)
      if ! choose_storages_interactive; then
        echo "[!] Автообнаружение не удалось. Введи вручную (пример: local-lvm)" >&2
        read -r -p "Storage IDs: " s
        s="${s//,/ }"
        for x in $s; do [[ -n "$x" ]] && echo "$x"; done | awk '!seen[$0]++'
      fi
      ;;
    2)
      read -r -p "Storage IDs (пример: local-lvm local): " s
      s="${s//,/ }"
      for x in $s; do [[ -n "$x" ]] && echo "$x"; done | awk '!seen[$0]++'
      ;;
    *) die "Неверный выбор" ;;
  esac
}

# ---------- role (auto-validate privs) ----------
ensure_students_role_custom_auto() {
  local role="$STUDENTS_ROLE"
  local tmprole="__privcheck_tmp__$$"

  # полный набор нужных прав, валидатор сам выкинет отсутствующие
  local want_privs=(
    "Pool.Audit"

    "Datastore.Audit"
    "Datastore.Allocate"
    "Datastore.AllocateSpace"
    "Datastore.AllocateTemplate"

    "VM.Audit"
    "VM.Allocate"
    "VM.Clone"
    "VM.Console"
    "VM.PowerMgmt"
    "VM.Backup"
    "VM.Snapshot"

    "VM.Config.Options"
    "VM.Config.CPU"
    "VM.Config.Memory"
    "VM.Config.Disk"
    "VM.Config.Network"
    "VM.Config.CDROM"
    "VM.Config.Cloudinit"
    "VM.Config.HWType"

    "VM.GuestAgent.Audit"
    "VM.GuestAgent.FileRead"
    "VM.GuestAgent.FileSystem"
    "VM.GuestAgent.PowerMgmt"

    "Mapping.Audit"
    "Mapping.Use"

    "SDN.Audit"
    "SDN.Use"
    # "SDN.Allocate"   # раскомментируй, если студентам надо создавать SDN
  )

  local ok=() dropped=() p
  for p in "${want_privs[@]}"; do
    pveum role delete "$tmprole" >/dev/null 2>&1 || true
    if pveum role add "$tmprole" -privs "$p" >/dev/null 2>&1; then
      ok+=("$p")
    else
      dropped+=("$p")
    fi
  done
  pveum role delete "$tmprole" >/dev/null 2>&1 || true
  ((${#ok[@]} > 0)) || die "Не удалось собрать привилегии для $role"

  # пересоздаём StudentsLab
  if pveum role list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$role"; then
    pveum role delete "$role" >/dev/null 2>&1 || true
  fi
  pveum role add "$role" -privs "$(IFS=','; echo "${ok[*]}")" >/dev/null

  echo "[*] Роль $role создана/обновлена (privs: ${#ok[@]})" >&2
  if ((${#dropped[@]} > 0)); then
    echo "[!] Пропущены отсутствующие привилегии:" >&2
    printf "    - %s\n" "${dropped[@]}" >&2
  fi
}

# ---------- groups/pool/acl/users ----------
group_exists(){ pveum group list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$1"; }

ensure_group() {
  local g="$1"
  if group_exists "$g"; then echo "[*] Группа $g уже существует" >&2; return 0; fi
  pveum group add "$g" >/dev/null
  echo "[*] Создана группа $g" >&2
}

ensure_pool() {
  local pool="$1"
  have pvesh || die "Нет pvesh"
  if pvesh get /pools 2>/dev/null | grep -q "\"poolid\" *: *\"$pool\""; then
    echo "[*] Пул $pool уже существует" >&2; return 0
  fi
  pvesh create /pools --poolid "$pool" >/dev/null
  echo "[*] Создан пул $pool" >&2
}

acl_group() {
  local path="$1" group="$2" role="$3" prop="${4:-1}"
  if [[ "$prop" == "1" ]]; then
    pveum aclmod "$path" -group "$group" -role "$role" -propagate 1 >/dev/null
  else
    pveum aclmod "$path" -group "$group" -role "$role" >/dev/null
  fi
  echo "[*] ACL: $path -> group $group role $role" >&2
}

ensure_user_pve() {
  local userid="$1" pass="$2" group="$3"
  if pveum user list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$userid"; then
    pveum user modify "$userid" --password "$pass" >/dev/null
  else
    pveum user add "$userid" --password "$pass" >/dev/null
  fi
  pveum user modify "$userid" --group "$group" >/dev/null
  echo "[*] User: $userid in group $group" >&2
}

setup_access_model() {
  echo "=== Настройка пользователей/групп/прав ===" >&2

  read -r -p "Логин учителя (латиница/цифры/._-): " tlogin
  [[ -n "${tlogin:-}" ]] || die "Логин учителя пустой"
  validate_userid_localpart "$tlogin" || die "Логин только латиница/цифры и . _ -"

  local tpass; tpass="$(read_secret_twice_min8 "Пароль учителя")"

  echo "Настроим storage для дисков ВМ (images):" >&2
  mapfile -t storages < <(get_storages)
  ((${#storages[@]} > 0)) || die "Список storage пуст"

  # auto add 'local' if exists for ISO selection
  if storage_exists_any "local"; then
    if ! printf "%s\n" "${storages[@]}" | grep -qx "local"; then
      storages+=("local")
      echo "[*] Добавил storage 'local' автоматически (для ISO)." >&2
    fi
  fi
  mapfile -t storages < <(printf "%s\n" "${storages[@]}" | awk '!seen[$0]++')
  echo "[*] Выбраны storage: ${storages[*]}" >&2

  ensure_group "$TEACHERS_GROUP"
  ensure_group "$STUDENTS_GROUP"
  ensure_pool "$STUDENTS_POOL"

  ensure_students_role_custom_auto

  # --- ACL Teachers (full admin) ---
  acl_group "/" "$TEACHERS_GROUP" "Administrator" 1

  # --- ACL Students ---
  # 1) Чтобы UI не давал 403 на нодах/обзоре (read-only)
  acl_group "/" "$STUDENTS_GROUP" "PVEAuditor" 1

  # 2) Чтобы выбирать vmbr/mappings и SDN в мастере
  acl_group "/" "$STUDENTS_GROUP" "PVEMappingUser" 1
  acl_group "/" "$STUDENTS_GROUP" "PVESDNUser" 1

  # 3) Чтобы создавать ВМ в пуле и добавлять их в пул (Pool.Allocate)
  acl_group "/pool/$STUDENTS_POOL" "$STUDENTS_GROUP" "PVEPoolAdmin" 1

  # 4) Основные права студентов на пул
  acl_group "/pool/$STUDENTS_POOL" "$STUDENTS_GROUP" "$STUDENTS_ROLE" 1

  # 5) Права на storage
  for st in "${storages[@]}"; do
    acl_group "/storage/$st" "$STUDENTS_GROUP" "$STUDENTS_ROLE" 1
  done

  # Users
  ensure_user_pve "${tlogin}@${REALM}" "$tpass" "$TEACHERS_GROUP"
  ensure_user_pve "${DEFAULT_STUDENT_USER}@${REALM}" "$DEFAULT_STUDENT_PASS" "$STUDENTS_GROUP"

  echo "[+] Готово." >&2
  echo "    Учитель: ${tlogin}@${REALM}" >&2
  echo "    Студент: ${DEFAULT_STUDENT_USER}@${REALM} (пароль: ${DEFAULT_STUDENT_PASS})" >&2
}

# ---------- menu ----------
main_menu() {
  need_root
  have pveum || die "Нет pveum"
  while true; do
    echo
    echo "========== PVE MultiTool =========="
    echo "1) Бесплатные репозитории + apt update"
    echo "2) Users/Groups/ACL (Teachers+students) + create VM without 403"
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
