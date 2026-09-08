#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
WEBROOT="${WEBROOT:-/var/www/mstream}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BUNDLED_SITE_DIR="${BUNDLED_SITE_DIR:-$REPO_ROOT/assets/stream-site}"
STREAM_SITE_ARCHIVE="${STREAM_SITE_ARCHIVE:-}"
STREAM_SITE_ARCHIVE_URL="${STREAM_SITE_ARCHIVE_URL:-}"
STREAM_SITE_SHA256="${STREAM_SITE_SHA256:-}"
ALLOW_LEGACY_STREAM_FETCH="${ALLOW_LEGACY_STREAM_FETCH:-0}"
LEGACY_STREAM_SITE_URL="${LEGACY_STREAM_SITE_URL:-https://rustream.remna.space}"

log(){ printf '%s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }

require_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запустите от root"
}

fix_permissions(){
  chmod 755 /var /var/www "$WEBROOT" 2>/dev/null || true
  find "$WEBROOT" -type d -exec chmod 755 {} +
  find "$WEBROOT" -type f -exec chmod 644 {} +
}

clear_webroot(){
  mkdir -p "$WEBROOT"
  find "$WEBROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

install_from_directory(){
  local src="$1"
  [[ -s "$src/index.html" ]] || fail "В $src нет index.html"
  clear_webroot
  cp -a "$src"/. "$WEBROOT"/
  fix_permissions
  log "Стрим-сайт установлен из versioned assets: $src"
}

verify_archive(){
  local archive="$1"
  [[ -n "$STREAM_SITE_SHA256" ]] || return 0
  local actual
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$actual" == "$STREAM_SITE_SHA256" ]] || fail "SHA256 архива не совпал: $actual"
}

install_from_archive(){
  local archive="$1" tmpd idx
  [[ -f "$archive" ]] || fail "Архив не найден: $archive"
  verify_archive "$archive"
  tmpd="$(mktemp -d)"
  tar -xf "$archive" -C "$tmpd" || { rm -rf "$tmpd"; fail "Не удалось распаковать архив"; }
  idx="$(find "$tmpd" -type f -name index.html -print -quit)"
  [[ -n "$idx" ]] || { rm -rf "$tmpd"; fail "В архиве нет index.html"; }
  clear_webroot
  cp -a "$(dirname "$idx")"/. "$WEBROOT"/
  rm -rf "$tmpd"
  fix_permissions
  log "Стрим-сайт установлен из архива: $archive"
}

install_from_archive_url(){
  local tmp
  tmp="$(mktemp)"
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 90 --retry 2 \
    "$STREAM_SITE_ARCHIVE_URL" -o "$tmp" || { rm -f "$tmp"; fail "Не удалось скачать STREAM_SITE_ARCHIVE_URL"; }
  install_from_archive "$tmp"
  rm -f "$tmp"
}

legacy_fetch(){
  [[ "$ALLOW_LEGACY_STREAM_FETCH" == 1 ]] || fail "Versioned stream-site assets пока не найдены. Legacy fetch отключен."
  local tmpd idx
  tmpd="$(mktemp -d)"
  wget -q --timeout=20 --tries=2 --page-requisites --convert-links --adjust-extension \
    --no-host-directories --directory-prefix="$tmpd" "$LEGACY_STREAM_SITE_URL" || true
  idx="$(find "$tmpd" -type f -name 'index.html*' -print -quit)"
  [[ -n "$idx" && -s "$idx" ]] || { rm -rf "$tmpd"; fail "Не удалось получить legacy stream-site"; }
  clear_webroot
  cp -a "$(dirname "$idx")"/. "$WEBROOT"/
  [[ -f "$WEBROOT/index.html" ]] || mv "$WEBROOT/$(basename "$idx")" "$WEBROOT/index.html"
  rm -rf "$tmpd"
  fix_permissions
  log "Стрим-сайт установлен через LEGACY fetch. Рекомендуется один раз зафиксировать snapshot в GitHub assets."
}

main(){
  echo '#################### НАЧАЛО ВЫВОДА: STREAM SITE ####################'
  require_root

  if [[ -s "$BUNDLED_SITE_DIR/index.html" ]]; then
    install_from_directory "$BUNDLED_SITE_DIR"
  elif [[ -n "$STREAM_SITE_ARCHIVE" ]]; then
    install_from_archive "$STREAM_SITE_ARCHIVE"
  elif [[ -n "$STREAM_SITE_ARCHIVE_URL" ]]; then
    install_from_archive_url
  else
    legacy_fetch
  fi

  [[ -s "$WEBROOT/index.html" ]] || fail "После установки отсутствует $WEBROOT/index.html"
  echo "WEBROOT=$WEBROOT"
  echo '#################### КОНЕЦ ВЫВОДА: STREAM SITE ####################'
}

main "$@"
