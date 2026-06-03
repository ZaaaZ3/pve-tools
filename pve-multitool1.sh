#!/usr/bin/env bash
# pve-multitool v2 — учебный стенд Proxmox VE (okeit.edu)
# Репозитории, ISO-хранилище (NFS/CIFS), преподы+студенты с корректными правами,
# изолированная SDN-зона и фаервол с защитой от локаута.
#
# Запуск:   ./pve-multitool.sh            (интерактивное меню)
#           ./pve-multitool.sh --help     (флаги для неинтерактивного режима)
set -uo pipefail   # без -e: меню должно переживать ошибки отдельных действий

# ----------------------------------------------------------------------------
# Дефолты (всё переопределяется флагами или в диалоге)
# ----------------------------------------------------------------------------
REALM="pve"
DOMAIN="okeit.edu"
DNS_SERVERS="10.56.1.1 10.56.1.2"

TEACHERS_GROUP="Teachers"
STUDENTS_GROUP="students"
STUDENTS_POOL="students"
STUDENTS_ROLE="StudentsLab"

STUDENT_PREFIX="student"
STUDENT_COUNT=15
STUDENT_PASS_LEN=14

# SDN
SDN_ZONE="lab"               # имя изолированной зоны
SDN_VNET="labnet0"           # стартовый VNet в ней
LAB_SUBNET="172.16.50.0/24"  # подсеть лаборатории (НЕ пересекай с локалкой колледжа!)
LAB_GATEWAY="172.16.50.1"    # шлюз = сам хост (NAT-гейт)
LAB_DHCP_START="172.16.50.50"
LAB_DHCP_END="172.16.50.200"
LAB_DNS="1.1.1.1"            # публичный DNS студентам (чтобы локалку резать целиком)

# Фаервол: какие сети считаем "защищёнными" (студентам туда нельзя)
LOCAL_NETS="10.56.0.0/16 10.0.0.0/8 192.168.0.0/16 172.16.0.0/12"  # коридор колледжа+RFC1918
# (lab-подсеть исключается из блокировки автоматически)
# management IPSET — кому разрешён доступ к GUI/SSH хоста (чтобы не словить локаут)
MGMT_IPS=""                   # доп. админские IP; авто-детект ниже добавит свои

# ISO-хранилище (бэкап-сервер). Заполняется флагами/в диалоге.
ISO_TYPE="nfs"            # nfs | cifs
ISO_ID="iso-backup"
ISO_SERVER=""
ISO_EXPORT="/export/iso" # для nfs — путь экспорта; для cifs — share
ISO_CONTENT="iso,vztmpl"
ISO_CIFS_USER=""
ISO_CIFS_PASS=""

# Режимы
DRY_RUN=0
ASSUME_YES=0
NO_COLOR=0
ALLOW_INTERNET=1         # 1 = инет через NAT (локалка всё равно режется FORWARD-правилом); --no-internet = полная изоляция

LOG_FILE="/var/log/pve-multitool.log"
TS="$(date +%F_%H%M%S)"

# ----------------------------------------------------------------------------
# Утилиты вывода / выполнения
# ----------------------------------------------------------------------------
init_color() {
  if [[ $NO_COLOR -eq 1 || ! -t 1 ]]; then
    C_RST="" C_RED="" C_GRN="" C_YEL="" C_BLU="" C_DIM=""
  else
    C_RST=$'\e[0m'; C_RED=$'\e[31m'; C_GRN=$'\e[32m'
    C_YEL=$'\e[33m'; C_BLU=$'\e[36m'; C_DIM=$'\e[2m'
  fi
}
_log_raw(){ echo "[$(date +%T)] $*" >>"$LOG_FILE" 2>/dev/null || true; }
log(){  echo "${C_BLU}[*]${C_RST} $*" >&2; _log_raw "[*] $*"; }
ok(){   echo "${C_GRN}[+]${C_RST} $*" >&2; _log_raw "[+] $*"; }
warn(){ echo "${C_YEL}[!]${C_RST} $*" >&2; _log_raw "[!] $*"; }
die(){  echo "${C_RED}[ERROR]${C_RST} $*" >&2; _log_raw "[ERROR] $*"; exit 1; }

have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ $EUID -eq 0 ]] || die "Запусти от root"; }

# run — единая точка выполнения мутирующих команд (учитывает --dry-run)
run(){
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "${C_DIM}[dry-run]${C_RST} $*" >&2
    return 0
  fi
  "$@"
}
# write_file — запись файла с учётом dry-run; stdin -> файл
write_file(){
  local path="$1"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "${C_DIM}[dry-run] write -> $path${C_RST}" >&2
    cat >/dev/null
    return 0
  fi
  cat >"$path"
}
confirm(){
  local q="$1"
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local a; read -r -p "$q [y/N]: " a
  [[ "$a" =~ ^[yYдД]$ ]]
}
validate_localpart(){ [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ ]]; }

# ----------------------------------------------------------------------------
# Авто-детект окружения
# ----------------------------------------------------------------------------
detect_codename(){ source /etc/os-release; echo "${VERSION_CODENAME:-}"; }
detect_pve_major(){
  if have pveversion; then
    pveversion 2>/dev/null | sed -n 's#.*pve-manager/\([0-9]\+\).*#\1#p' | head -n1
  fi
}
detect_keyring(){
  local k
  for k in /usr/share/keyrings/proxmox-archive-keyring.gpg \
           /usr/share/keyrings/proxmox-release-*.gpg; do
    [[ -e "$k" ]] && { echo "$k"; return 0; }
  done
  echo ""
}
detect_mgmt_ip(){
  # основной IP хоста — чтобы добавить в management и не словить локаут
  ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1
}
detect_ssh_client(){
  # если зашли по SSH — добавим источник в management
  [[ -n "${SSH_CLIENT:-}" ]] && echo "${SSH_CLIENT%% *}"
}

# ============================================================================
# МОДУЛЬ 1: Репозитории
# ============================================================================
backup_apt(){
  local bak="/root/pve-apt-backup-$TS"
  run mkdir -p "$bak"
  run cp -a /etc/apt/sources.list "$bak/" 2>/dev/null || true
  run cp -a /etc/apt/sources.list.d "$bak/" 2>/dev/null || true
  echo "$bak"
}
disable_list_file(){ [[ -f "$1" ]] && run sed -i -E 's/^[[:space:]]*deb[[:space:]]+/# deb /' "$1"; }
disable_sources_file(){
  local f="$1"; [[ -f "$f" ]] || return 0
  if grep -qiE '^[[:space:]]*Enabled[[:space:]]*:' "$f"; then
    run sed -i -E 's/^[[:space:]]*Enabled[[:space:]]*:.*/Enabled: no/I' "$f"
  else
    if [[ $DRY_RUN -eq 1 ]]; then echo "[dry-run] append Enabled: no -> $f" >&2
    else printf "\nEnabled: no\n" >>"$f"; fi
  fi
}
switch_repos_and_update(){
  local bak; bak="$(backup_apt)"; log "Бэкап APT: $bak"
  local changed=0 f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
    [[ -e "$f" ]] || continue
    if grep -q "enterprise\.proxmox\.com" "$f" 2>/dev/null; then
      [[ "$f" == *.sources ]] && disable_sources_file "$f" || disable_list_file "$f"
      changed=1
    fi
  done
  [[ $changed -eq 1 ]] && ok "Enterprise-репозитории отключены" || log "Enterprise не найден/уже отключён"

  local codename major keyring
  codename="$(detect_codename)"; [[ -n "$codename" ]] || die "Не определил codename Debian"
  major="$(detect_pve_major)"
  keyring="$(detect_keyring)"
  log "Debian: $codename | PVE major: ${major:-?} | keyring: ${keyring:-нет}"

  if [[ "${major:-0}" -ge 9 ]]; then
    # PVE 9 / Debian 13: формат deb822
    local sb=""; [[ -n "$keyring" ]] && sb=$'\nSigned-By: '"$keyring"
    write_file /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $codename
Components: pve-no-subscription$sb
EOF
    ok "Добавлен pve-no-subscription (.sources, $codename)"
  else
    write_file /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve $codename pve-no-subscription
EOF
    ok "Добавлен pve-no-subscription (.list, $codename)"
  fi

  if run apt-get update; then ok "apt update OK"; else warn "apt update вернул ошибку — проверь сеть до download.proxmox.com"; fi
}

# Глушилка nag-окна "No valid subscription" (best-effort, может слететь после обновления toolkit)
remove_subscription_nag(){
  local js="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
  [[ -f "$js" ]] || { warn "Не найден $js — пропуск"; return 0; }
  run cp -a "$js" "${js}.bak-$TS"
  # типовой патч: не показывать диалог при status != active
  run sed -i "s/\.data\.status\.toLowerCase() !== 'active'/.data.status.toLowerCase() !== 'active_NOPE'/g" "$js" \
    && ok "nag-окно подавлено (бэкап: ${js}.bak-$TS). Очисти кэш браузера." \
    || warn "Не удалось пропатчить — формат файла мог измениться в этой версии"
  run systemctl restart pveproxy 2>/dev/null || true
}

# ============================================================================
# МОДУЛЬ 2: ISO-хранилище с бэкап-сервера (NFS/CIFS)
# ============================================================================
storage_exists(){ pvesm status 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$1"; }

attach_iso_storage(){
  have pvesm || die "Нет pvesm"
  [[ -n "$ISO_SERVER" ]] || { read -r -p "IP/хост бэкап-сервера с ISO: " ISO_SERVER; }
  [[ -n "$ISO_SERVER" ]] || die "Сервер ISO не задан"

  if storage_exists "$ISO_ID"; then
    warn "Хранилище '$ISO_ID' уже существует — пропуск (удали вручную для пересоздания)"
    return 0
  fi

  case "$ISO_TYPE" in
    nfs)
      [[ -n "$ISO_EXPORT" ]] || { read -r -p "NFS export (напр. /export/iso): " ISO_EXPORT; }
      log "Подключаю NFS $ISO_SERVER:$ISO_EXPORT как '$ISO_ID' (content: $ISO_CONTENT)"
      run pvesm add nfs "$ISO_ID" \
        --server "$ISO_SERVER" --export "$ISO_EXPORT" \
        --content "$ISO_CONTENT" --options vers=3 \
        && ok "NFS ISO-хранилище подключено" \
        || die "Не удалось подключить NFS (проверь export и сеть)"
      ;;
    cifs)
      [[ -n "$ISO_EXPORT" ]] || { read -r -p "CIFS share (имя шары): " ISO_EXPORT; }
      [[ -n "$ISO_CIFS_USER" ]] || { read -r -p "CIFS логин: " ISO_CIFS_USER; }
      [[ -n "$ISO_CIFS_PASS" ]] || { read -rsp "CIFS пароль: " ISO_CIFS_PASS; echo >&2; }
      log "Подключаю CIFS //$ISO_SERVER/$ISO_EXPORT как '$ISO_ID'"
      run pvesm add cifs "$ISO_ID" \
        --server "$ISO_SERVER" --share "$ISO_EXPORT" \
        --username "$ISO_CIFS_USER" --password "$ISO_CIFS_PASS" \
        --content "$ISO_CONTENT" \
        && ok "CIFS ISO-хранилище подключено" \
        || die "Не удалось подключить CIFS"
      ;;
    *) die "Неизвестный ISO_TYPE: $ISO_TYPE (nfs|cifs)";;
  esac
  log "Заливать ISO смогут только преподы/админы (у студентов нет Datastore.AllocateTemplate)"
}

# ============================================================================
# МОДУЛЬ 3: Роли / группы / пул / пользователи / ACL
# ============================================================================
# Роль студента: всё для VM + создание VNet, НО без правки хранилищ/датацентра/юзеров
ensure_students_role(){
  local role="$STUDENTS_ROLE" tmp="__privcheck_$$"
  local want=(
    Pool.Audit
    Datastore.Audit Datastore.AllocateSpace
    VM.Audit VM.Allocate VM.Clone VM.Console VM.PowerMgmt VM.Backup VM.Snapshot
    VM.Config.Options VM.Config.CPU VM.Config.Memory VM.Config.Disk
    VM.Config.Network VM.Config.CDROM VM.Config.Cloudinit VM.Config.HWType
    VM.GuestAgent.Audit VM.GuestAgent.FileRead VM.GuestAgent.FileSystem VM.GuestAgent.PowerMgmt
    Mapping.Audit Mapping.Use
    SDN.Audit SDN.Use SDN.Allocate
  )
  # НАМЕРЕННО НЕ включаем: Datastore.Allocate (правка хранилищ),
  # Datastore.AllocateTemplate (заливка/удаление ISO), Sys.* / Realm.* / Permissions.*
  local ok_p=() dropped=() p
  for p in "${want[@]}"; do
    pveum role delete "$tmp" >/dev/null 2>&1 || true
    if [[ $DRY_RUN -eq 1 ]]; then ok_p+=("$p"); continue; fi
    if pveum role add "$tmp" -privs "$p" >/dev/null 2>&1; then ok_p+=("$p"); else dropped+=("$p"); fi
  done
  pveum role delete "$tmp" >/dev/null 2>&1 || true
  ((${#ok_p[@]}>0)) || die "Не собрал привилегии для $role"

  if pveum role list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$role"; then
    run pveum role delete "$role" >/dev/null 2>&1 || true
  fi
  run pveum role add "$role" -privs "$(IFS=','; echo "${ok_p[*]}")" >/dev/null
  ok "Роль $role создана/обновлена (привилегий: ${#ok_p[@]})"
  ((${#dropped[@]}>0)) && { warn "Пропущены отсутствующие в этой версии PVE:"; printf '    - %s\n' "${dropped[@]}" >&2; }
}

group_exists(){ pveum group list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$1"; }
ensure_group(){
  local g="$1"
  group_exists "$g" && { log "Группа $g уже есть"; return 0; }
  run pveum group add "$g" >/dev/null && ok "Создана группа $g"
}
ensure_pool(){
  local pool="$1"; have pvesh || die "Нет pvesh"
  if pvesh get /pools 2>/dev/null | grep -q "\"poolid\" *: *\"$pool\""; then log "Пул $pool уже есть"; return 0; fi
  run pvesh create /pools --poolid "$pool" >/dev/null && ok "Создан пул $pool"
}
acl_group(){ # path group role [propagate]
  run pveum aclmod "$1" -group "$2" -role "$3" -propagate "${4:-1}" >/dev/null \
    && log "ACL: $1 -> group $2 / role $3"
}
gen_pass(){ tr -dc 'A-Za-z2-9!@#%+=' </dev/urandom | head -c "$STUDENT_PASS_LEN"; echo; }

ensure_user(){ # userid pass group
  local uid="$1" pass="$2" grp="$3"
  if pveum user list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$uid"; then
    run pveum user modify "$uid" --password "$pass" >/dev/null
  else
    run pveum user add "$uid" --password "$pass" >/dev/null
  fi
  run pveum user modify "$uid" --group "$grp" >/dev/null
}

setup_access_model(){
  echo "=== Пользователи / группы / права ===" >&2

  # --- препод ---
  local tlogin tpass
  read -r -p "Логин преподавателя (латиница/цифры/._-): " tlogin
  validate_localpart "$tlogin" || die "Логин: только латиница/цифры и . _ -"
  while :; do
    read -rsp "Пароль преподавателя (мин.8): " tpass; echo >&2
    local p2; read -rsp "Повтори: " p2; echo >&2
    [[ "$tpass" == "$p2" && ${#tpass} -ge 8 ]] && break
    warn "Не совпадает или короткий"
  done

  ensure_group "$TEACHERS_GROUP"
  ensure_group "$STUDENTS_GROUP"
  ensure_pool  "$STUDENTS_POOL"
  ensure_students_role

  # Препод — полный админ (включая Shell хоста: Administrator содержит Sys.Console)
  acl_group "/" "$TEACHERS_GROUP" "Administrator" 1
  # Студенты — роль с / (чтобы UI не давал 403), но без опасных привилегий
  acl_group "/" "$STUDENTS_GROUP" "$STUDENTS_ROLE" 1
  # Доступ к созданию VNet — точечно на зону студентов (создавать зоны они не смогут)
  if pvesh get /cluster/sdn/zones 2>/dev/null | grep -q "\"$SDN_ZONE\""; then
    acl_group "/sdn/zones/$SDN_ZONE" "$STUDENTS_GROUP" "$STUDENTS_ROLE" 1
  else
    warn "SDN-зона '$SDN_ZONE' ещё не создана — сделай пункт SDN, потом права на зону применятся"
  fi

  ensure_user "${tlogin}@${REALM}" "$tpass" "$TEACHERS_GROUP"
  ok "Преподаватель: ${tlogin}@${REALM} (полные права + Shell хоста)"

  # --- студенты пачкой + CSV ---
  local csv="/root/students-${TS}.csv"
  [[ $DRY_RUN -eq 1 ]] || echo "user,password" >"$csv"
  local i uid pass
  for ((i=1; i<=STUDENT_COUNT; i++)); do
    uid="${STUDENT_PREFIX}${i}@${REALM}"
    pass="$(gen_pass)"
    ensure_user "$uid" "$pass" "$STUDENTS_GROUP"
    [[ $DRY_RUN -eq 1 ]] || echo "${uid},${pass}" >>"$csv"
  done
  ok "Создано студентов: $STUDENT_COUNT (${STUDENT_PREFIX}1..${STUDENT_PREFIX}${STUDENT_COUNT})"
  [[ $DRY_RUN -eq 1 ]] || ok "Пароли выгружены: $csv (chmod 600)"
  [[ $DRY_RUN -eq 1 ]] || chmod 600 "$csv"
}

# ============================================================================
# МОДУЛЬ 4: Изолированная SDN-зона + VNet + подсеть (NAT для инета, своя L2)
# ============================================================================
setup_sdn_isolated(){
  have pvesh || die "Нет pvesh"

  # зона: simple + ipam pve + автоматический DHCP (dnsmasq)
  if pvesh get /cluster/sdn/zones 2>/dev/null | grep -q "\"$SDN_ZONE\""; then
    log "Зона $SDN_ZONE уже есть"
  else
    log "Создаю Simple-зону '$SDN_ZONE' (ipam pve, авто-DHCP)"
    run pvesh create /cluster/sdn/zones --type simple --zone "$SDN_ZONE" \
        --ipam pve --dhcp dnsmasq >/dev/null \
      && ok "Зона $SDN_ZONE создана" \
      || warn "Не удалось создать зону (возможно нет пакета SDN/dnsmasq)"
  fi

  # vnet
  if pvesh get /cluster/sdn/vnets 2>/dev/null | grep -q "\"$SDN_VNET\""; then
    log "VNet $SDN_VNET уже есть"
  else
    run pvesh create /cluster/sdn/vnets --vnet "$SDN_VNET" --zone "$SDN_ZONE" >/dev/null \
      && ok "VNet $SDN_VNET создан в зоне $SDN_ZONE"
  fi

  # подсеть: gateway + (snat если инет) + dhcp-range + публичный DNS
  if pvesh get "/cluster/sdn/vnets/$SDN_VNET/subnets" 2>/dev/null | grep -q "$LAB_SUBNET"; then
    log "Подсеть $LAB_SUBNET уже есть"
  else
    local snat_opt=()
    [[ $ALLOW_INTERNET -eq 1 ]] && snat_opt=(--snat 1)
    log "Создаю подсеть $LAB_SUBNET (gw $LAB_GATEWAY, dhcp $LAB_DHCP_START-$LAB_DHCP_END, dns $LAB_DNS)"
    run pvesh create "/cluster/sdn/vnets/$SDN_VNET/subnets" \
        --subnet "$LAB_SUBNET" --type subnet --gateway "$LAB_GATEWAY" "${snat_opt[@]}" \
        --dhcp-range "start-address=$LAB_DHCP_START,end-address=$LAB_DHCP_END" >/dev/null \
      && ok "Подсеть создана" \
      || warn "Подсеть не создалась — проверь, что IPAM включён"
    # публичный DNS для VNet (чтобы можно было резать локалку целиком)
    set_lab_dns
  fi

  run pvesh set /cluster/sdn >/dev/null 2>&1 || true   # apply pending
  ok "SDN применён."
  if [[ $ALLOW_INTERNET -eq 1 ]]; then
    ok "Студенты -> VM на '$SDN_VNET', IP по DHCP, интернет через NAT."
    warn "ВАЖНО: SNAT даёт путь и в локалку! Обязательно сделай пункт 'Фаервол' —"
    warn "       он ставит host-правило FORWARD: lab-подсеть -> локалка = DROP (студент не снимет)."
  else
    ok "Полная изоляция: своя L2, без NAT — наружу пути нет вообще."
  fi
  warn "Широковещалка (rogue DHCP/AD/ARP) заперта на L2 этой подсети и в колледжскую сеть не уйдёт."
  warn "Остаточный риск: при VM.Config.Network студент может вручную выбрать vmbr0. Жёстко — VLAN на свиче."
}

# Публичный DNS для подсети через ключ dhcp-dns-server в subnets.cfg (если не задан pvesh-параметром)
set_lab_dns(){
  local cfg="/etc/pve/sdn/subnets.cfg"
  [[ -n "$LAB_DNS" ]] || return 0
  [[ $DRY_RUN -eq 1 ]] && { echo "[dry-run] dhcp-dns-server $LAB_DNS -> $cfg" >&2; return 0; }
  [[ -f "$cfg" ]] || return 0
  if ! grep -q "dhcp-dns-server" "$cfg"; then
    # добавляем ключ в блок нашей подсети (имя блока: <zone>-<subnet-с-дефисами>)
    awk -v dns="$LAB_DNS" '
      /^subnet:/{print; inblk=1; next}
      inblk && /^$/ && !done {print "\tdhcp-dns-server " dns; done=1; inblk=0; print; next}
      {print}
      END{if(inblk && !done) print "\tdhcp-dns-server " dns}
    ' "$cfg" > "${cfg}.new" && mv "${cfg}.new" "$cfg" \
      && ok "DNS для VNet выставлен: $LAB_DNS"
  fi
}

# ============================================================================
# МОДУЛЬ 4b: Host-enforced изоляция L3 (FORWARD: lab -> локалка = DROP)
# ============================================================================
install_lab_isolation(){
  local script="/usr/local/sbin/pve-lab-isolation.sh"
  local unit="/etc/systemd/system/pve-lab-isolation.service"
  log "Ставлю host-правило изоляции (студент его не снимет, нет доступа к хосту)"

  write_file "$script" <<EOF
#!/usr/bin/env bash
# Авто-сгенерировано pve-multitool. FORWARD: lab-подсеть -> локалка = DROP, остальное (инет) разрешено.
set -u
SUBNET="$LAB_SUBNET"
LOCAL_NETS="$LOCAL_NETS"
CH="PVE_LAB_ISO"
iptables -N "\$CH" 2>/dev/null || iptables -F "\$CH"
for n in \$LOCAL_NETS; do
  [[ "\$n" == "\$SUBNET" ]] && continue
  iptables -A "\$CH" -s "\$SUBNET" -d "\$n" -j DROP
done
iptables -A "\$CH" -j RETURN
iptables -C FORWARD -j "\$CH" 2>/dev/null || iptables -I FORWARD 1 -j "\$CH"
EOF
  run chmod +x "$script"

  write_file "$unit" <<EOF
[Unit]
Description=PVE lab L3 isolation (block lab subnet -> LAN)
After=pve-firewall.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$script

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable --now pve-lab-isolation.service >/dev/null 2>&1 \
    && ok "Изоляция L3 активна и переживёт перезагрузку" \
    || warn "Не удалось включить службу изоляции — проверь systemctl status pve-lab-isolation"
  log "Проверить: iptables -L FORWARD -n | grep PVE_LAB_ISO"
}

# ============================================================================
# МОДУЛЬ 5: Фаервол (защита локалки + анти-локаут)
# ============================================================================
setup_firewall(){
  local cfw="/etc/pve/firewall/cluster.fw"
  run mkdir -p /etc/pve/firewall

  # собрать management IP: основной IP хоста + SSH-источник + заданные вручную
  local mgmt; mgmt="$(detect_mgmt_ip)"
  local ssh_src; ssh_src="$(detect_ssh_client)"
  local mgmt_list=()
  [[ -n "$mgmt" ]]    && mgmt_list+=("$mgmt/32")
  [[ -n "$ssh_src" ]] && mgmt_list+=("$ssh_src/32")
  local x; for x in $MGMT_IPS; do mgmt_list+=("$x"); done
  for x in $DNS_SERVERS; do mgmt_list+=("$x/32"); done
  # дедуп
  mapfile -t mgmt_list < <(printf '%s\n' "${mgmt_list[@]}" | awk 'NF&&!s[$0]++')

  echo >&2
  warn "Сейчас включится фаервол ДАТАЦЕНТРА. Доступ к GUI/SSH хоста сохранится только для:"
  printf '    %s\n' "${mgmt_list[@]}" >&2
  warn "Если твоего IP тут нет — добавь через --mgmt-ips, иначе словишь локаут!"
  confirm "Продолжить и записать $cfw?" || { warn "Фаервол пропущен"; return 0; }

  if [[ -f "$cfw" ]]; then run cp -a "$cfw" "${cfw}.bak-$TS"; log "Бэкап: ${cfw}.bak-$TS"; fi

  # сформировать строки IPSET
  local mgmt_block="" net_block=""
  for x in "${mgmt_list[@]}"; do mgmt_block+="${x}"$'\n'; done

  # правило интернета для группы изоляции
  local internet_rule=""
  [[ $ALLOW_INTERNET -eq 1 ]] && internet_rule="OUT ACCEPT -log nolog # остальное (интернет) разрешено"

  # local-nets IPSET (исключаем lab-подсеть, чтобы не резать саму лабу)
  for x in $LOCAL_NETS; do
    [[ "$x" == "$LAB_SUBNET" ]] && continue
    net_block+="${x}"$'\n'
  done

  write_file "$cfw" <<EOF
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[IPSET management] # доступ к GUI(8006)/SSH(22) хоста — анти-локаут
$(printf '%s' "$mgmt_block")
[IPSET lab-net] # подсеть лаборатории (внутри — общаться можно)
$LAB_SUBNET
[IPSET local-nets] # защищённые сети колледжа (студентам туда нельзя)
$(printf '%s' "$net_block")
[group student-isolation] # навесь на студенческие VM (или ставится скриптом, см. пункт 8)
OUT ACCEPT -dest +lab-net -log nolog # внутри лаборатории — можно
OUT DROP -dest +local-nets -log nolog # сеть колледжа — нельзя
$internet_rule
EOF
  ok "cluster.fw записан, фаервол включён (policy_in: DROP, management разрешён)"
  run pve-firewall compile >/dev/null 2>&1 || true
  run systemctl restart pve-firewall 2>/dev/null || true
  echo >&2
  log "Группа 'student-isolation' создана. Применить ко всем студенческим VM: пункт меню 8."
  log "Связка: L2-изоляция (VNet) + host-FORWARD (lab->локалка DROP) + NAT (инет). Фаервол VM — третий рубеж."
  [[ $ALLOW_INTERNET -eq 0 ]] && log "Интернет студентам закрыт (полная изоляция). Включить: --allow-internet"

  # host-правило FORWARD (студент не снимет) — реальная гарантия "в локалку нельзя"
  if [[ $ALLOW_INTERNET -eq 1 ]]; then
    install_lab_isolation
  fi
}

# Применить security group + анти-спуф опции ко всем VM из пула студентов
# Включает фаервол на VM и на её NIC. Ставит dhcp:1 (клиент, не сервер), radv:0, ipfilter:1, macfilter:1.
harden_student_vms(){
  have pvesh || die "Нет pvesh"
  local members vmid count=0
  members="$(pvesh get "/pools/$STUDENTS_POOL" --output-format json 2>/dev/null \
            | grep -oE '"vmid" *: *[0-9]+' | grep -oE '[0-9]+')"
  [[ -n "$members" ]] || { warn "В пуле '$STUDENTS_POOL' нет VM — нечего применять"; return 0; }

  for vmid in $members; do
    local fwf="/etc/pve/firewall/${vmid}.fw"
    # включить фаервол на всех net-интерфейсах VM
    local netcfg; netcfg="$(qm config "$vmid" 2>/dev/null | grep -oE '^net[0-9]+:' | tr -d ':')"
    local n
    for n in $netcfg; do
      local line; line="$(qm config "$vmid" | sed -n "s/^$n: //p")"
      if [[ "$line" != *firewall=1* ]]; then
        run qm set "$vmid" --"$n" "${line%,*}",firewall=1 >/dev/null 2>&1 \
          || run qm set "$vmid" --"$n" "$line,firewall=1" >/dev/null 2>&1 || true
      fi
    done
    # опции VM-фаервола + подключить security group
    write_file "$fwf" <<EOF
[OPTIONS]
enable: 1
dhcp: 1
radv: 0
ipfilter: 1
macfilter: 1
policy_in: ACCEPT
policy_out: ACCEPT

[RULES]
GROUP student-isolation
EOF
    ((count++))
  done
  run pve-firewall compile >/dev/null 2>&1 || true
  ok "Применено к $count студенческим VM (фаервол+группа+анти-спуф)"
  log "Новым VM применяй повторным запуском этого пункта (для уже созданных машин)."
}

# ============================================================================
# Меню / CLI
# ============================================================================
do_all(){
  switch_repos_and_update
  attach_iso_storage
  setup_sdn_isolated
  setup_access_model
  setup_firewall
}

usage(){
  cat <<EOF
pve-multitool v2 — учебный стенд Proxmox

Использование: $0 [команда] [флаги]

Команды (без команды -> интерактивное меню):
  repos              бесплатные репозитории + apt update
  nag                подавить окно "No valid subscription"
  iso                подключить ISO-хранилище (NFS/CIFS)
  access             преподы + студенты + права
  sdn                изолированная SDN-зона + VNet
  firewall           фаервол (анти-локаут + изоляция локалки)
  harden             навесить фаервол-группу+анти-спуф на студенческие VM
  all                всё подряд

Флаги:
  --students N           число студентов (по умолч. $STUDENT_COUNT)
  --student-prefix P     префикс логина (по умолч. $STUDENT_PREFIX)
  --iso-type nfs|cifs    тип ISO-хранилища (по умолч. $ISO_TYPE)
  --iso-server HOST      IP/хост бэкап-сервера
  --iso-export PATH      NFS export или CIFS share
  --sdn-zone NAME        имя изолированной зоны (по умолч. $SDN_ZONE)
  --sdn-vnet NAME        имя VNet (по умолч. $SDN_VNET)
  --lab-subnet CIDR      подсеть лаборатории (по умолч. $LAB_SUBNET)
  --lab-gateway IP       шлюз/NAT-гейт лабы (по умолч. $LAB_GATEWAY)
  --lab-dns IP           DNS для студентов (по умолч. $LAB_DNS)
  --local-nets "CIDR..." защищённые сети (по умолч. коридор колледжа + RFC1918)
  --mgmt-ips "IP/32..."  доп. админские IP для анти-локаута
  --allow-internet       инет через NAT + блок локалки (ПО УМОЛЧАНИЮ включено)
  --no-internet          полная изоляция, без NAT
  --dry-run              ничего не менять, только показать
  --yes                  не спрашивать подтверждений
  --no-color             без цвета
  -h, --help             эта справка
EOF
}

main_menu(){
  while true; do
    echo
    echo "========== PVE MultiTool v2 =========="
    echo " 1) Репозитории + apt update"
    echo " 2) Подключить ISO-хранилище (NFS/CIFS)"
    echo " 3) Изолированная SDN-зона + VNet"
    echo " 4) Преподы + студенты + права"
    echo " 5) Фаервол (анти-локаут + изоляция)"
    echo " 6) Подавить nag-окно подписки"
    echo " 7) Сделать ВСЁ (1->2->3->4->5)"
    echo " 8) Применить фаервол-группу к студенческим VM"
    echo " 0) Выход"
    echo "======================================"
    read -r -p "Выбор: " c
    case "${c:-}" in
      1) ( switch_repos_and_update ) || warn "Шаг завершился с ошибкой";;
      2) ( attach_iso_storage )      || warn "Шаг завершился с ошибкой";;
      3) ( setup_sdn_isolated )      || warn "Шаг завершился с ошибкой";;
      4) ( setup_access_model )      || warn "Шаг завершился с ошибкой";;
      5) ( setup_firewall )          || warn "Шаг завершился с ошибкой";;
      6) ( remove_subscription_nag ) || warn "Шаг завершился с ошибкой";;
      7) ( do_all )                  || warn "Один из шагов завершился с ошибкой";;
      8) ( harden_student_vms )      || warn "Шаг завершился с ошибкой";;
      0) exit 0;;
      *) warn "Неверный выбор";;
    esac
  done
}

# ---- разбор флагов ----
CMD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    repos|nag|iso|access|sdn|firewall|all|harden) CMD="$1";;
    --students) STUDENT_COUNT="$2"; shift;;
    --student-prefix) STUDENT_PREFIX="$2"; shift;;
    --iso-type) ISO_TYPE="$2"; shift;;
    --iso-server) ISO_SERVER="$2"; shift;;
    --iso-export) ISO_EXPORT="$2"; shift;;
    --sdn-zone) SDN_ZONE="$2"; shift;;
    --sdn-vnet) SDN_VNET="$2"; shift;;
    --local-nets) LOCAL_NETS="$2"; shift;;
    --mgmt-ips) MGMT_IPS="$2"; shift;;
    --allow-internet) ALLOW_INTERNET=1;;
    --no-internet) ALLOW_INTERNET=0;;
    --lab-subnet) LAB_SUBNET="$2"; shift;;
    --lab-gateway) LAB_GATEWAY="$2"; shift;;
    --lab-dns) LAB_DNS="$2"; shift;;
    --dry-run) DRY_RUN=1;;
    --yes|-y) ASSUME_YES=1;;
    --no-color) NO_COLOR=1;;
    -h|--help) usage; exit 0;;
    *) echo "Неизвестный аргумент: $1" >&2; usage; exit 1;;
  esac
  shift
done

init_color
need_root
have pveum || die "Нет pveum — это точно нода Proxmox VE?"
_log_raw "=== запуск (cmd=${CMD:-menu}, dry=$DRY_RUN) ==="

case "$CMD" in
  repos)    switch_repos_and_update;;
  nag)      remove_subscription_nag;;
  iso)      attach_iso_storage;;
  access)   setup_access_model;;
  sdn)      setup_sdn_isolated;;
  firewall) setup_firewall;;
  harden)   harden_student_vms;;
  all)      do_all;;
  "")       main_menu;;
esac
