#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELFSTEAL_SITE="${SELFSTEAL_SITE:-}"
ENABLE_HYSTERIA2="${ENABLE_HYSTERIA2:-ask}"

log(){ printf '%s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запустите от root"; }
require_node(){ [[ -f "$APP_DIR/docker-compose.yml" ]] || fail "Сначала выполните основную установку Remnanode"; }

run_step(){
  local name="$1"; shift
  log ""
  log "=== $name ==="
  "$@"
}

main(){
  echo '#################### НАЧАЛО ВЫВОДА: PRODUCTION PROFILE ####################'
  require_root
  require_node

  run_step "Выбор и установка SelfSteal" env SELFSTEAL_SITE="$SELFSTEAL_SITE" bash "$SCRIPT_DIR/install-stream-site.sh"
  run_step "Настройка SelfSteal backend TLS1.2" bash "$SCRIPT_DIR/configure-selfsteal-nginx.sh"
  run_step "Генерация Remnawave Config Profile" env ENABLE_HYSTERIA2="$ENABLE_HYSTERIA2" bash "$SCRIPT_DIR/generate-remnawave-profile.sh"

  log ""
  log "Готово. Основной транспорт: XHTTP + REALITY на TCP/443."
  log "Hysteria2, если выбрана, работает на UDP/443 и использует сертификаты из $APP_DIR/certs."
  log "Профиль: $APP_DIR/config-profile.json"
  log "Краткая сводка: $APP_DIR/config-profile-public.txt"
  [[ -r "$APP_DIR/.selfsteal-site" ]] && { log "SelfSteal:"; sed 's/^/  /' "$APP_DIR/.selfsteal-site"; }
  echo '#################### КОНЕЦ ВЫВОДА: PRODUCTION PROFILE ####################'
}

main "$@"
