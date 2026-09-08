#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
WWW_DIR="${WWW_DIR:-/var/www/html}"
STATE_FILE="$APP_DIR/.selfsteal_site"
RADIO_ADMIN_FILE="$APP_DIR/.selfsteal_radio_admin"

STREAM_REF="ec5ffa5c26e57c6f6b2060bbf6743d3921c05500"
STREAM_URL="https://raw.githubusercontent.com/evgmahov-blip/setup-remna-node/${STREAM_REF}/selfsteal/stream/index.html"
RADIO_REF="276908d5fed3faaadfb3a331ab7acad18824a9b9"
RADIO_BASE="https://raw.githubusercontent.com/Balbuto/radio-stub-site/${RADIO_REF}"

log(){ printf '%s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }

require_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { fail 'Запусти от root'; return 1; }
}

fetch_static(){
  local url="$1" dst="$2" tmp
  tmp="${dst}.part"
  rm -f "$tmp"
  if ! curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 45 "$url" -o "$tmp"; then
    rm -f "$tmp"
    fail "Не удалось скачать $url"
    return 1
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; fail "Пустой файл: $url"; return 1; }
  mv -f "$tmp" "$dst"
}

prepare_www(){
  mkdir -p "$APP_DIR" "$WWW_DIR"
  find "$WWW_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

restart_nginx(){
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnawave-nginx; then
    docker restart remnawave-nginx >/dev/null
    log '[OK] remnawave-nginx перезапущен'
  fi
}

deploy_stream(){
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  fetch_static "$STREAM_URL" "$tmpdir/index.html"
  grep -Eqi '<!doctype|<html' "$tmpdir/index.html" || { fail 'STREAM index.html не похож на HTML'; return 1; }
  prepare_www
  install -m 0644 "$tmpdir/index.html" "$WWW_DIR/index.html"
  printf 'stream\n' > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  rm -f "$RADIO_ADMIN_FILE"
  restart_nginx
  log "[OK] SelfSteal сайт: STREAM (pinned $STREAM_REF)"
}

deploy_radio(){
  local tmpdir admin_name domain
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  fetch_static "$RADIO_BASE/index.html" "$tmpdir/index.html"
  fetch_static "$RADIO_BASE/admin.html" "$tmpdir/admin.html"
  grep -Eqi '<!doctype|<html' "$tmpdir/index.html" || { fail 'RADIO index.html не похож на HTML'; return 1; }
  grep -Eqi '<!doctype|<html' "$tmpdir/admin.html" || { fail 'RADIO admin.html не похож на HTML'; return 1; }

  if [[ -r "$RADIO_ADMIN_FILE" ]]; then
    admin_name="$(tr -d '\r\n' < "$RADIO_ADMIN_FILE")"
  else
    admin_name="manage-$(openssl rand -hex 12).html"
  fi
  [[ "$admin_name" =~ ^manage-[0-9a-f]{24}\.html$ ]] || admin_name="manage-$(openssl rand -hex 12).html"

  sed '/<div class="toggle-bar">/,/<\/div>/d' "$tmpdir/index.html" > "$tmpdir/index.public.html"

  prepare_www
  install -m 0644 "$tmpdir/index.public.html" "$WWW_DIR/index.html"
  install -m 0644 "$tmpdir/admin.html" "$WWW_DIR/$admin_name"
  printf 'radio\n' > "$STATE_FILE"
  printf '%s\n' "$admin_name" > "$RADIO_ADMIN_FILE"
  chmod 600 "$STATE_FILE" "$RADIO_ADMIN_FILE"
  restart_nginx

  domain="$(cat "$APP_DIR/.node_domain" 2>/dev/null || hostname -f 2>/dev/null || hostname)"
  log "[OK] SelfSteal сайт: RADIO (pinned $RADIO_REF)"
  log "[INFO] Скрытая админка: https://${domain}/${admin_name}"
}

ensure_site(){
  local selected='stream'
  [[ -r "$STATE_FILE" ]] && selected="$(tr -d '\r\n' < "$STATE_FILE")"
  case "$selected" in
    stream) deploy_stream ;;
    radio) deploy_radio ;;
    *)
      log "[WARN] Неизвестное сохранённое значение '$selected'; ставлю STREAM по умолчанию"
      deploy_stream
      ;;
  esac
}

choose_site(){
  local current choice
  current="$(cat "$STATE_FILE" 2>/dev/null || echo stream)"
  echo
  echo 'SELFSTEAL SITE:'
  echo "  Текущий: $current"
  echo '  1) STREAM — мой стрим-сайт (по умолчанию)'
  echo '  2) RADIO — радио с отдельной скрытой админкой'
  echo '  0) Назад'
  read -r -p 'Выбор [1]: ' choice
  case "${choice:-1}" in
    1) deploy_stream ;;
    2) deploy_radio ;;
    0) return 0 ;;
    *) fail 'Неверный выбор'; return 1 ;;
  esac
}

show_status(){
  local selected admin domain
  selected="$(cat "$STATE_FILE" 2>/dev/null || echo 'не выбран (default=stream)')"
  echo "SelfSteal site: $selected"
  if [[ "$selected" == 'radio' && -r "$RADIO_ADMIN_FILE" ]]; then
    admin="$(tr -d '\r\n' < "$RADIO_ADMIN_FILE")"
    domain="$(cat "$APP_DIR/.node_domain" 2>/dev/null || hostname -f 2>/dev/null || hostname)"
    echo "Radio admin: https://${domain}/${admin}"
  fi
}

main(){
  require_root || return 1
  case "${1:-ensure}" in
    ensure) ensure_site ;;
    choose) choose_site ;;
    stream) deploy_stream ;;
    radio) deploy_radio ;;
    status) show_status ;;
    *) fail 'Допустимо: ensure | choose | stream | radio | status'; return 1 ;;
  esac
}

main "$@"
