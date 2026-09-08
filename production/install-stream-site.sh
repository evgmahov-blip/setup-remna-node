#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
WEBROOT="${WEBROOT:-/var/www/html}"
STATE_FILE="$APP_DIR/.selfsteal-site"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BUNDLED_STREAM_DIR="${BUNDLED_STREAM_DIR:-$REPO_ROOT/assets/stream-site}"
STREAM_SITE_ARCHIVE="${STREAM_SITE_ARCHIVE:-}"
STREAM_SITE_ARCHIVE_URL="${STREAM_SITE_ARCHIVE_URL:-}"
STREAM_SITE_SHA256="${STREAM_SITE_SHA256:-}"
SELFSTEAL_SITE="${SELFSTEAL_SITE:-}"
REPO="${REMNANODE_REPO:-evgmahov-blip/setup-remna-node}"
REPO_REF="${REMNANODE_REPO_REF:-custom}"
STREAM_REPO_INDEX_URL="https://raw.githubusercontent.com/${REPO}/${REPO_REF}/assets/stream-site/index.html"

RADIO_REPO="Balbuto/radio-stub-site"
RADIO_COMMIT="276908d5fed3faaadfb3a331ab7acad18824a9b9"
RADIO_INDEX_URL="https://raw.githubusercontent.com/${RADIO_REPO}/${RADIO_COMMIT}/index.html"
RADIO_ADMIN_URL="https://raw.githubusercontent.com/${RADIO_REPO}/${RADIO_COMMIT}/admin.html"

log(){ printf '%s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запустите от root"; }

fix_permissions(){
  chmod 755 /var /var/www "$WEBROOT" 2>/dev/null || true
  find "$WEBROOT" -type d -exec chmod 755 {} +
  find "$WEBROOT" -type f -exec chmod 644 {} +
}

clear_webroot(){
  mkdir -p "$WEBROOT"
  find "$WEBROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

verify_sha256(){
  local file="$1" expected="$2" label="$3"
  [[ -n "$expected" ]] || return 0
  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || fail "$label: SHA256 не совпал: $actual"
}

install_from_directory(){
  local src="$1"
  [[ -s "$src/index.html" ]] || fail "В $src нет index.html"
  clear_webroot
  cp -a "$src"/. "$WEBROOT"/
  fix_permissions
  log "STREAM SelfSteal установлен из versioned assets: $src"
}

install_from_archive(){
  local archive="$1" tmpd idx
  [[ -f "$archive" ]] || fail "Архив не найден: $archive"
  verify_sha256 "$archive" "$STREAM_SITE_SHA256" "stream archive"
  tmpd="$(mktemp -d)"
  tar -xf "$archive" -C "$tmpd" || { rm -rf "$tmpd"; fail "Не удалось распаковать архив"; }
  idx="$(find "$tmpd" -type f -name index.html -print -quit)"
  [[ -n "$idx" ]] || { rm -rf "$tmpd"; fail "В архиве нет index.html"; }
  clear_webroot
  cp -a "$(dirname "$idx")"/. "$WEBROOT"/
  rm -rf "$tmpd"
  fix_permissions
  log "STREAM SelfSteal установлен из архива"
}

install_from_archive_url(){
  local tmp
  tmp="$(mktemp)"
  curl -fsSL --proto '=https' --tls-max 1.2 --connect-timeout 10 --max-time 90 --retry 2 \
    "$STREAM_SITE_ARCHIVE_URL" -o "$tmp" || { rm -f "$tmp"; fail "Не удалось скачать STREAM_SITE_ARCHIVE_URL"; }
  install_from_archive "$tmp"
  rm -f "$tmp"
}

install_stream_from_repo(){
  local tmpd
  tmpd="$(mktemp -d)"
  curl -fsSL --proto '=https' --tls-max 1.2 --connect-timeout 10 --max-time 60 --retry 2 \
    "$STREAM_REPO_INDEX_URL" -o "$tmpd/index.html" || {
      rm -rf "$tmpd"
      fail "Не удалось скачать versioned STREAM asset из ${REPO}@${REPO_REF}"
    }
  [[ -s "$tmpd/index.html" ]] || { rm -rf "$tmpd"; fail "STREAM index.html пуст"; }
  clear_webroot
  install -m 0644 "$tmpd/index.html" "$WEBROOT/index.html"
  rm -rf "$tmpd"
  fix_permissions
  log "STREAM SelfSteal установлен из GitHub asset: ${REPO}@${REPO_REF}"
}

install_stream_site(){
  local source=""
  if [[ -s "$BUNDLED_STREAM_DIR/index.html" ]]; then
    install_from_directory "$BUNDLED_STREAM_DIR"
    source="bundled:${BUNDLED_STREAM_DIR}"
  elif [[ -n "$STREAM_SITE_ARCHIVE" ]]; then
    install_from_archive "$STREAM_SITE_ARCHIVE"
    source="archive:${STREAM_SITE_ARCHIVE}"
  elif [[ -n "$STREAM_SITE_ARCHIVE_URL" ]]; then
    install_from_archive_url
    source="archive-url:${STREAM_SITE_ARCHIVE_URL}"
  else
    install_stream_from_repo
    source="github:${REPO}@${REPO_REF}:assets/stream-site/index.html"
  fi
  mkdir -p "$APP_DIR"
  cat > "$STATE_FILE" <<EOF
TYPE=stream
SOURCE=$source
EOF
  chmod 600 "$STATE_FILE"
}

random_admin_slug(){ printf 'manage-%s' "$(openssl rand -hex 12)"; }

install_radio_site(){
  local tmpd admin_slug admin_name
  tmpd="$(mktemp -d)"
  curl -fsSL --proto '=https' --tls-max 1.2 --connect-timeout 10 --max-time 60 --retry 2 \
    "$RADIO_INDEX_URL" -o "$tmpd/index.html" || { rm -rf "$tmpd"; fail "Не удалось скачать RADIO index.html"; }
  curl -fsSL --proto '=https' --tls-max 1.2 --connect-timeout 10 --max-time 60 --retry 2 \
    "$RADIO_ADMIN_URL" -o "$tmpd/admin.html" || { rm -rf "$tmpd"; fail "Не удалось скачать RADIO admin.html"; }

  sed -i '/<div class="toggle-bar">/,/<\/div>/d' "$tmpd/index.html"
  admin_slug="$(random_admin_slug)"
  admin_name="${admin_slug}.html"

  clear_webroot
  install -m 0644 "$tmpd/index.html" "$WEBROOT/index.html"
  install -m 0644 "$tmpd/admin.html" "$WEBROOT/$admin_name"
  rm -rf "$tmpd"
  fix_permissions

  mkdir -p "$APP_DIR"
  cat > "$STATE_FILE" <<EOF
TYPE=radio
SOURCE_REPO=$RADIO_REPO
SOURCE_COMMIT=$RADIO_COMMIT
ADMIN_PATH=/$admin_name
EOF
  chmod 600 "$STATE_FILE"
  log "RADIO SelfSteal установлен из pinned commit $RADIO_COMMIT"
  log "Скрытый путь управления: /$admin_name"
}

choose_site(){
  local choice="${SELFSTEAL_SITE:-}"
  case "$choice" in
    stream|1) printf 'stream\n'; return 0 ;;
    radio|2) printf 'radio\n'; return 0 ;;
  esac
  printf '\nВыберите SelfSteal-сайт:\n' >&2
  printf '  1) STREAM — versioned asset из evgmahov-blip/setup-remna-node\n' >&2
  printf '  2) RADIO  — Balbuto/radio-stub-site со скрытым URL управления\n' >&2
  printf 'Выбор [1]: ' >&2
  read -r choice
  choice=${choice:-1}
  case "$choice" in
    1) printf 'stream\n' ;;
    2) printf 'radio\n' ;;
    *) fail "Неизвестный вариант: $choice" ;;
  esac
}

show_result(){
  local domain="" ap=""
  [[ -r "$APP_DIR/.node_domain" ]] && domain="$(tr -d '[:space:]' < "$APP_DIR/.node_domain")"
  echo "WEBROOT=$WEBROOT"
  [[ -r "$STATE_FILE" ]] && cat "$STATE_FILE"
  if [[ -r "$STATE_FILE" ]] && grep -q '^TYPE=radio$' "$STATE_FILE"; then
    ap="$(sed -n 's/^ADMIN_PATH=//p' "$STATE_FILE")"
    [[ -n "$domain" && -n "$ap" ]] && echo "RADIO_ADMIN_URL=https://${domain}${ap}"
  fi
}

main(){
  echo '#################### НАЧАЛО ВЫВОДА: SELFSTEAL SITE ####################'
  require_root
  command -v curl >/dev/null 2>&1 || fail "curl не найден"
  command -v openssl >/dev/null 2>&1 || fail "openssl не найден"
  case "$(choose_site)" in
    stream) install_stream_site ;;
    radio) install_radio_site ;;
    *) fail "Не удалось определить тип сайта" ;;
  esac
  [[ -s "$WEBROOT/index.html" ]] || fail "После установки отсутствует $WEBROOT/index.html"
  show_result
  echo '#################### КОНЕЦ ВЫВОДА: SELFSTEAL SITE ####################'
}

main "$@"
