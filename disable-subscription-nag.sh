#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
DIV="${JS}.distrib"

if [[ ! -f "$JS" ]]; then
  echo "Не найден $JS (установлен ли proxmox-widget-toolkit?)"
  exit 1
fi

# 1) Делает divert (чтобы апдейты пакета не перезатирали наш JS)
if ! dpkg-divert --list "$JS" >/dev/null 2>&1; then
  echo "[*] dpkg-divert add: $JS -> $DIV"
  dpkg-divert --add --rename --divert "$DIV" "$JS"
else
  echo "[*] dpkg-divert уже настроен для $JS"
fi

# Если по какой-то причине distrib не появился — страхуемся
if [[ ! -f "$DIV" ]]; then
  echo "[!] Не найден $DIV, копирую текущий $JS как базу"
  cp -a "$JS" "$DIV"
fi

# 2) Берём оригинал, патчим, кладём обратно как рабочий JS
tmp="$(mktemp)"
cp -a "$DIV" "$tmp"

# Патч 1: убрать popup "No valid subscription"
# Идея: условие проверки статуса делаем всегда false (DoNotAsk), как описывают гайды.
perl -0777 -i -pe "s/(res\\.data\\.status\\.toLowerCase\\(\\)\\s*)!==\\s*'active'/\${1}==\\s*'DoNotAsk'/g" "$tmp"
perl -0777 -i -pe "s/(res\\.data\\.status\\.toLowerCase\\(\\)\\s*)!=\\s*'active'/\${1}==\\s*'DoNotAsk'/g" "$tmp"

# Патч 2 (best-effort): убрать баннер/сообщение про no-subscription repo в UI (если он встречается)
# В разных версиях текст может отличаться, поэтому просто “глушим” некоторые строки.
perl -0777 -i -pe "s/No valid subscription/ /g; s/no-subscription/ /ig" "$tmp"

install -m 0644 "$tmp" "$JS"
rm -f "$tmp"

echo "[*] Restart pveproxy"
systemctl restart pveproxy

echo "[+] Готово. Если в браузере всё ещё показывается — обнови страницу с очисткой кэша (Ctrl+F5)."
