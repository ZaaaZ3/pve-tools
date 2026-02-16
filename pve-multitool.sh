#!/usr/bin/env bash
set -euo pipefail

REALM="pve"
TEACHERS_GROUP="Teachers"
STUDENTS_GROUP="students"
STUDENTS_ROLE="StudentsLab"
STUDENTS_POOL="students"

DEFAULT_STUDENT_USER="user"
DEFAULT_STUDENT_PASS="P@ssw0rd"

die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "Запусти от root"; }
have(){ command -v "$1" >/dev/null 2>&1; }

detect_codename() {
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

disable_list_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  sed -i -E 's/^[[:space:]]*deb[[:space:]]+/# deb /' "$f"
}

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
    echo "[*] Enterprise репозитории отключены." >&2
  else
    echo "[*] Enterprise репозитории не найдены (или уже отключены)." >&2
  fi
}

enable_no_subscription_repo() {
  local codename
  codename="$(detect_codename)"
  cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve $codename pve-no-subscription
EOF
  echo "[*] Добавлен pve-no-subscription ($codename)." >&2
}

switch_repos_and_update() {
  local bak
  bak="$(backup_apt)"
  echo "[*] Бэкап APT: $bak" >&2
  disable_enterprise_repos
  enable_no_subscription_repo
  echo "[*] apt-get update..." >&2
  apt-get update
  echo "[+] Репозитории переключены и обновлены." >&2
}

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

# ---------- Storage selection ----------
list_storages() {
  have pvesm || die "Нет pvesm (это точно Proxmox VE?)"
  if have timeout; then
    timeout 5s pvesm status 2>/tmp/pvesm_status.err \
      | awk 'NR>1{print $1}' | sort -u
  else
    pvesm status 2>/tmp/pvesm_status.err | awk 'NR>1{print $1}' | sort -u
  fi
}

choose_storages_interactive() {
  local storages=() i choice selected=()

  mapfile -t storages < <(list_storages || true)
  if ((${#storages[@]} == 0)); then
    echo "[!] Автообнаружение storage не удалось. Перехожу на ручной ввод." >&2
    if [[ -s /tmp/pvesm_status.err ]]; then
      echo "    Ошибка pvesm:" >&2
      sed 's/^/      /' /tmp/pvesm_status.err | tail -n 20 >&2
    fi
    return 1
  fi

  echo "Доступные storage:" >&2
  for i in "${!storages[@]}"; do
    printf "  %2d) %s\n" $((i+1)) "${storages[$i]}" >&2
  done
  echo "Выбери storage через запятую (пример: 1,3) или 'a' = все:" >&2
  read -r choice

  if [[ "$choice" =~ ^[aA]$ ]]; then
    printf "%s\n" "${storages[@]}"
    return 0
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
  echo "  1) Автообнаружение + выбрать из списка" >&2
  echo "  2) Указать вручную (через пробел или запятую)" >&2
  read -r -p "Выбор [1-2]: " mode

  case "${mode:-}" in
    1)
      if ! choose_storages_interactive; then
        read -r -p "Введи storage IDs (пример: local local-lvm) или через запятую: " s
        s="${s//,/ }"
        for x in $s; do [[ -n "$x" ]] && echo "$x"; done | awk '!seen[$0]++'
      fi
      ;;
    2)
      read -r -p "Введи storage IDs (пример: local local-lvm) или через запятую: " s
      s="${s//,/ }"
      for x in $s; do [[ -n "$x" ]] && echo "$x"; done | awk '!seen[$0]++'
      ;;
    *)
      die "Неверный выбор storage режима"
      ;;
  esac
}

# ---------- Access setup ----------
group_exists() {
  local g="$1"
  pveum group list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$g"
}

ensure_group() {
  local g="$1"
  if group_exists "$g"; then
    echo "[*] Группа $g уже существует" >&2
    return 0
  fi
  pveum group add "$g" >/dev/null
  echo "[*] Создана группа $g" >&2
}

ensure_pool() {
  local pool="$1"
  if have pvesh; then
    if pvesh get /pools 2>/dev/null | grep -q "\"poolid\" *: *\"$pool\""; then
      echo "[*] Пул $pool уже существует" >&2
      return 0
    fi
    pvesh create /pools --poolid "$pool" >/dev/null
    echo "[*] Создан пул $pool" >&2
  else
    echo "[!] pvesh не найден — пул пропущен." >&2
  fi
}

ensure_role_students() {
  local role="$1"
  local tmprole="__privcheck_tmp__$$"

  # Набор привилегий (без VM.Monitor)
  local want_privs=(
    "VM.Audit"
    "VM.Allocate"
    "VM.Clone"
    "VM.Console"
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

  local ok=() dropped=()
  local p

  # Проверяем каждую привилегию "на реальность" через временную роль
  for p in "${want_privs[@]}"; do
    # удалим tmprole если вдруг осталась
    pveum role delete "$tmprole" >/dev/null 2>&1 || true

    if pveum role add "$tmprole" -privs "$p" >/dev/null 2>&1; then
      ok+=("$p")
    else
      dropped+=("$p")
    fi
  done

  # чистим tmprole
  pveum role delete "$tmprole" >/dev/null 2>&1 || true

  ((${#ok[@]} > 0)) || die "Не удалось подобрать ни одной валидной привилегии для роли $role"

  if ((${#dropped[@]} > 0)); then
    echo "[!] Эти привилегии отсутствуют в твоей версии PVE и будут пропущены:" >&2
    printf "    - %s\n" "${dropped[@]}" >&2
  fi

  # пересоздаём целевую роль
  if pveum role list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$role"; then
    pveum role delete "$role" >/dev/null 2>&1 || true
  fi

  pveum role add "$role" -privs "$(IFS=','; echo "${ok[*]}")" >/dev/null
  echo "[*] Роль $role создана/обновлена (privs: ${#ok[@]})" >&2
}

set_acl_group() {
  local path="$1" group="$2" role="$3" propagate="${4:-1}"
  if [[ "$propagate" == "1" ]]; then
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
  # Set primary group (simple)
  pveum user modify "$userid" --group "$group" >/dev/null
  echo "[*] User: $userid in group $group" >&2
}

setup_access_model() {
  echo "=== Настройка пользователей/групп/прав ===" >&2

  read -r -p "Логин учителя (без @realm, пример: teacher1): " tlogin
  [[ -n "${tlogin:-}" ]] || die "Логин учителя пустой"
  local tpass
  tpass="$(read_secret_twice_min8 "Пароль учителя")"

  echo "Настроим доступ студентов к storage (для дисков/шаблонов)." >&2
  mapfile -t storages < <(get_storages)
  ((${#storages[@]} > 0)) || die "Список storage пуст"
  echo "[*] Выбраны storage: ${storages[*]}" >&2

  ensure_group "$TEACHERS_GROUP"
  ensure_group "$STUDENTS_GROUP"
  ensure_pool "$STUDENTS_POOL"
  ensure_role_students "$STUDENTS_ROLE"

  # ACLs
  set_acl_group "/" "$TEACHERS_GROUP" "Administrator" 1
  set_acl_group "/pool/$STUDENTS_POOL" "$STUDENTS_GROUP" "$STUDENTS_ROLE" 1
  for st in "${storages[@]}"; do
    set_acl_group "/storage/$st" "$STUDENTS_GROUP" "$STUDENTS_ROLE" 1
  done

  # Users
  ensure_user_pve "${tlogin}@${REALM}" "$tpass" "$TEACHERS_GROUP"
  ensure_user_pve "${DEFAULT_STUDENT_USER}@${REALM}" "$DEFAULT_STUDENT_PASS" "$STUDENTS_GROUP"

  echo "[+] Готово. Учитель: ${tlogin}@${REALM} | Студент: ${DEFAULT_STUDENT_USER}@${REALM}" >&2
}

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
