#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
LOG_DIR="${LOG_DIR:-/var/log/remnanode}"
WEBROOT="${WEBROOT:-/var/www/html}"
MODE="${RESET_MODE:-ask}"

log(){ printf '%s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запустите от root"; }

KNOWN_CONTAINERS=(
  remnanode
  remnawave-nginx
  remnawave-caddy
  remna-node
  remna-proxy
  telemt
  telemt-panel
)

has_old_stack(){
  local found=1 name
  if command -v docker >/dev/null 2>&1; then
    for name in "${KNOWN_CONTAINERS[@]}"; do
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$name"; then found=0; fi
    done
  fi
  [[ -e "$APP_DIR" ]] && found=0
  [[ -e /opt/remna-node ]] && found=0
  [[ -e /opt/remnawave-node ]] && found=0
  [[ -e /opt/telemt ]] && found=0
  [[ -e /etc/caddy/Caddyfile ]] && grep -qiE 'remna|xray|telemt|/dev/shm/nginx.sock' /etc/caddy/Caddyfile 2>/dev/null && found=0
  return "$found"
}

show_detected(){
  echo 'Обнаружено перед очисткой:'
  if command -v docker >/dev/null 2>&1; then
    docker ps -a --format '  container: {{.Names}}  image={{.Image}}  status={{.Status}}' 2>/dev/null \
      | grep -Ei 'remna|xray|telemt|caddy|nginx' || true
  fi
  for p in "$APP_DIR" /opt/remna-node /opt/remnawave-node /opt/telemt "$LOG_DIR"; do
    [[ -e "$p" ]] && printf '  path: %s\n' "$p"
  done
  if [[ -e /etc/caddy/Caddyfile ]]; then
    if grep -qiE 'remna|xray|telemt|/dev/shm/nginx.sock' /etc/caddy/Caddyfile 2>/dev/null; then
      echo '  caddy: /etc/caddy/Caddyfile содержит Remna/Xray/Telemt-конфигурацию'
    fi
  fi
}

confirm_reset(){
  case "$MODE" in
    force|yes|1) return 0 ;;
    auto)
      has_old_stack || return 1
      printf 'Найдены остатки старой Remna/Proxy-конфигурации. Очистить их перед установкой? [Y/n]: '
      local a; read -r a
      case "${a:-Y}" in [Nn]*) return 1 ;; *) return 0 ;; esac
      ;;
    ask)
      printf 'Выполнить очистку старой Remna/Proxy-конфигурации перед установкой? [y/N]: '
      local a; read -r a
      case "${a:-N}" in [Yy]*) return 0 ;; *) return 1 ;; esac
      ;;
    *) fail "RESET_MODE должен быть ask/auto/force" ;;
  esac
}

stop_remove_known_containers(){
  command -v docker >/dev/null 2>&1 || return 0
  local name
  for name in "${KNOWN_CONTAINERS[@]}"; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$name"; then
      log "Удаляю контейнер: $name"
      docker rm -f "$name" >/dev/null 2>&1 || true
    fi
  done

  # Дополнительно удаляем только контейнеры с явно Remna/Xray/Telemt-именами.
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    log "Удаляю старый профильный контейнер: $name"
    docker rm -f "$name" >/dev/null 2>&1 || true
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Ei '(^|[-_])(remna|remnawave|xray|telemt)([-_]|$)' || true)
}

remove_old_files(){
  rm -rf "$APP_DIR" /opt/remna-node /opt/remnawave-node /opt/telemt
  rm -rf "$LOG_DIR"
  rm -f /etc/logrotate.d/remnanode
  rm -f /etc/letsencrypt/renewal-hooks/deploy/copy-remnanode-certs.sh
  rm -f /usr/local/bin/remnanode

  # WEBROOT используется этой нодой как SelfSteal. Очищаем содержимое, но не /var/www целиком.
  if [[ -d "$WEBROOT" ]]; then
    find "$WEBROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi
}

cleanup_old_caddy(){
  [[ -e /etc/caddy/Caddyfile ]] || return 0
  if grep -qiE 'remna|xray|telemt|/dev/shm/nginx.sock' /etc/caddy/Caddyfile 2>/dev/null; then
    local backup="/etc/caddy/Caddyfile.remnanode-backup.$(date +%Y%m%d-%H%M%S)"
    cp -a /etc/caddy/Caddyfile "$backup"
    warn "Старый Caddyfile сохранен: $backup"
    : > /etc/caddy/Caddyfile
    systemctl stop caddy >/dev/null 2>&1 || true
  fi
}

cleanup_ufw_profile_rules(){
  command -v ufw >/dev/null 2>&1 || return 0
  # Не сбрасываем UFW целиком, чтобы не потерять SSH/чужие правила.
  # Удаляем только правила, которые предыдущие версии этого проекта создавали по comment/spec.
  local n
  while true; do
    n="$(ufw status numbered 2>/dev/null | awk '/Remnanode|Xray Incoming|Xray Custom|Hysteria2|XHTTP Reality|HTTP \/ Certbot|HTTP Certbot|Certbot HTTP-01/ {gsub(/\[|\]/,"",$1); print $1; exit}')"
    [[ "$n" =~ ^[0-9]+$ ]] || break
    ufw --force delete "$n" >/dev/null 2>&1 || break
  done
  ufw reload >/dev/null 2>&1 || true
}

show_after(){
  echo
  echo 'После очистки:'
  if command -v docker >/dev/null 2>&1; then
    docker ps -a --format '  {{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null | grep -Ei 'remna|xray|telemt' || echo '  профильных контейнеров нет'
  fi
  [[ ! -e "$APP_DIR" ]] && echo "  $APP_DIR: удален"
  [[ ! -e /opt/remna-node ]] && echo '  /opt/remna-node: отсутствует'
  [[ ! -e /opt/remnawave-node ]] && echo '  /opt/remnawave-node: отсутствует'
}

main(){
  echo '#################### НАЧАЛО ВЫВОДА: RESET OLD NODE ####################'
  require_root
  if ! has_old_stack; then
    log 'Старая Remna/Proxy-конфигурация не обнаружена. Очистка не требуется.'
    echo '#################### КОНЕЦ ВЫВОДА: RESET OLD NODE ####################'
    return 0
  fi

  show_detected
  if ! confirm_reset; then
    log 'Очистка пропущена.'
    echo '#################### КОНЕЦ ВЫВОДА: RESET OLD NODE ####################'
    return 0
  fi

  stop_remove_known_containers
  cleanup_old_caddy
  remove_old_files
  cleanup_ufw_profile_rules
  show_after
  echo '#################### КОНЕЦ ВЫВОДА: RESET OLD NODE ####################'
}

main "$@"
