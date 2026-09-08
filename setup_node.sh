#!/usr/bin/env bash
# ==============================================================================
# Remnanode Production Installer v2.0
# Primary: VLESS + XHTTP + REALITY / TCP 443
# Optional: Hysteria2 / UDP 443
# SelfSteal: STREAM or RADIO
# ==============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf '\033[31m[ERROR]\033[0m Запустите скрипт от root.\n' >&2
  return 1 2>/dev/null || false
fi

REPO="evgmahov-blip/setup-remna-node"
REPO_REF="${REMNANODE_REPO_REF:-feature/transport443-mux}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REPO_REF}"
SCRIPT_URL="${RAW_BASE}/setup_node.sh"
APP_DIR="${APP_DIR:-/opt/remnanode}"
INSTALLER_DIR="${APP_DIR}/installer"
PRODUCTION_DIR="${INSTALLER_DIR}/production"
LEGACY_DIR="${INSTALLER_DIR}/legacy"
ASSET_DIR="${INSTALLER_DIR}/assets/stream-site"
LOCAL_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'; C=$'\033[36m'; N=$'\033[0m'
[[ -t 1 ]] || { R=''; G=''; Y=''; B=''; C=''; N=''; }

log(){ printf '%b[*]%b %s\n' "$B" "$N" "$*"; }
ok(){ printf '%b[OK]%b %s\n' "$G" "$N" "$*"; }
warn(){ printf '%b[!]%b %s\n' "$Y" "$N" "$*"; }
fail(){ printf '%b[ERROR]%b %s\n' "$R" "$N" "$*" >&2; return 1; }

pause_prompt(){ printf '\nНажмите Enter, чтобы вернуться в меню...'; read -r _ || true; }
curl_tls12(){ curl -fsSL --proto '=https' --tls-max 1.2 --connect-timeout 10 --max-time 90 --retry 2 "$@"; }

register_globally(){
  install -d -m 0755 /usr/local/bin
  if [[ -f "${BASH_SOURCE[0]}" && "${BASH_SOURCE[0]}" != /dev/fd/* && "${BASH_SOURCE[0]}" != /proc/*/fd/* ]]; then
    install -m 0755 "${BASH_SOURCE[0]}" /usr/local/bin/remnanode
  else
    curl_tls12 "$SCRIPT_URL" -o /usr/local/bin/remnanode || return 0
    chmod 0755 /usr/local/bin/remnanode
  fi
}

bundle_file(){
  local rel="$1" dst="$2" mode="${3:-0755}"
  if [[ -s "$LOCAL_ROOT/$rel" ]]; then
    install -D -m "$mode" "$LOCAL_ROOT/$rel" "$dst"
    return 0
  fi
  install -d -m 0755 "$(dirname "$dst")"
  curl_tls12 "$RAW_BASE/$rel" -o "$dst" || fail "Не удалось получить $rel"
  chmod "$mode" "$dst"
}

ensure_bundle(){
  install -d -m 0700 "$INSTALLER_DIR" "$PRODUCTION_DIR" "$LEGACY_DIR"
  bundle_file production/reset-node.sh "$PRODUCTION_DIR/reset-node.sh"
  bundle_file production/setup-base-node.sh "$PRODUCTION_DIR/setup-base-node.sh"
  bundle_file production/install-production.sh "$PRODUCTION_DIR/install-production.sh"
  bundle_file production/install-stream-site.sh "$PRODUCTION_DIR/install-stream-site.sh"
  bundle_file production/configure-selfsteal-nginx.sh "$PRODUCTION_DIR/configure-selfsteal-nginx.sh"
  bundle_file production/generate-remnawave-profile.sh "$PRODUCTION_DIR/generate-remnawave-profile.sh"
  bundle_file assets/stream-site/index.html "$ASSET_DIR/index.html" 0644

  local f
  for f in "$PRODUCTION_DIR"/*.sh; do bash -n "$f" || fail "Ошибка синтаксиса: $f"; done
}

ensure_legacy(){
  bundle_file legacy/setup_node_legacy.sh "$LEGACY_DIR/setup_node_legacy.sh"
  bash -n "$LEGACY_DIR/setup_node_legacy.sh" || fail "Legacy installer поврежден"
}

run_full_install(){
  clear
  echo '#################### НАЧАЛО ВЫВОДА: FULL PRODUCTION INSTALL ####################'
  ensure_bundle
  RESET_MODE=auto bash "$PRODUCTION_DIR/reset-node.sh"
  ensure_bundle
  bash "$PRODUCTION_DIR/setup-base-node.sh"
  REMNANODE_REPO="$REPO" REMNANODE_REPO_REF="$REPO_REF" bash "$PRODUCTION_DIR/install-production.sh"
  register_globally || true
  echo '#################### КОНЕЦ ВЫВОДА: FULL PRODUCTION INSTALL ####################'
  pause_prompt
}

run_zero_reset(){
  clear
  echo '#################### НАЧАЛО ВЫВОДА: MANUAL ZERO RESET ####################'
  ensure_bundle
  printf '%bВНИМАНИЕ:%b будут удалены только распознанные компоненты старого Remna/Xray/Telemt/proxy-стека.\n' "$Y" "$N"
  printf 'SSH, Docker как платформа и посторонние контейнеры не удаляются. UFW целиком не сбрасывается.\n\n'
  RESET_MODE=force bash "$PRODUCTION_DIR/reset-node.sh"
  echo '#################### КОНЕЦ ВЫВОДА: MANUAL ZERO RESET ####################'
  pause_prompt
}

run_profile_manager(){
  clear; ensure_bundle
  [[ -f "$APP_DIR/docker-compose.yml" ]] || { fail "Нода еще не установлена"; pause_prompt; return; }
  printf '%bRemnawave Config Profile%b\n' "$C" "$N"
  printf '  1) Перегенерировать профиль, сохранив текущий выбор Hysteria2\n'
  printf '  2) Перегенерировать профиль и заново спросить про Hysteria2\n'
  printf '  3) Показать краткую сводку\n'
  printf '  4) Показать полный JSON Config Profile\n'
  printf '  0) Назад\n'
  printf 'Выбор [0]: '
  local choice; read -r choice; choice=${choice:-0}
  case "$choice" in
    1) ENABLE_HYSTERIA2=keep bash "$PRODUCTION_DIR/generate-remnawave-profile.sh" ;;
    2) ENABLE_HYSTERIA2=ask bash "$PRODUCTION_DIR/generate-remnawave-profile.sh" ;;
    3) [[ -r "$APP_DIR/config-profile-public.txt" ]] && cat "$APP_DIR/config-profile-public.txt" || warn "Сводка еще не создана" ;;
    4) [[ -r "$APP_DIR/config-profile.json" ]] && cat "$APP_DIR/config-profile.json" || warn "Профиль еще не создан" ;;
    0) return ;;
    *) warn "Неизвестный пункт" ;;
  esac
  pause_prompt
}

run_selfsteal_manager(){
  clear; ensure_bundle
  [[ -f "$APP_DIR/docker-compose.yml" ]] || { fail "Нода еще не установлена"; pause_prompt; return; }
  printf '%bSelfSteal%b\n' "$C" "$N"
  [[ -r "$APP_DIR/.selfsteal-site" ]] && { printf 'Текущая конфигурация:\n'; sed 's/^/  /' "$APP_DIR/.selfsteal-site"; }
  printf '\n  1) STREAM\n  2) RADIO\n  3) Показать URL управления RADIO\n  0) Назад\nВыбор [0]: '
  local choice; read -r choice; choice=${choice:-0}
  case "$choice" in
    1) SELFSTEAL_SITE=stream REMNANODE_REPO="$REPO" REMNANODE_REPO_REF="$REPO_REF" bash "$PRODUCTION_DIR/install-stream-site.sh"; bash "$PRODUCTION_DIR/configure-selfsteal-nginx.sh" ;;
    2) SELFSTEAL_SITE=radio REMNANODE_REPO="$REPO" REMNANODE_REPO_REF="$REPO_REF" bash "$PRODUCTION_DIR/install-stream-site.sh"; bash "$PRODUCTION_DIR/configure-selfsteal-nginx.sh" ;;
    3) show_radio_admin ;;
    0) return ;;
    *) warn "Неизвестный пункт" ;;
  esac
  pause_prompt
}

show_radio_admin(){
  local state="$APP_DIR/.selfsteal-site" domain path
  [[ -r "$state" ]] || { warn "SelfSteal еще не настроен"; return 0; }
  if ! grep -q '^TYPE=radio$' "$state"; then warn "Сейчас выбран не RADIO"; return 0; fi
  domain="$(cat "$APP_DIR/.node_domain" 2>/dev/null || true)"
  path="$(sed -n 's/^ADMIN_PATH=//p' "$state")"
  [[ -n "$domain" && -n "$path" ]] || { warn "Не удалось определить URL"; return 0; }
  printf 'RADIO management: %bhttps://%s%s%b\n' "$C" "$domain" "$path" "$N"
}

show_status(){
  clear
  echo '#################### НАЧАЛО ВЫВОДА: NODE STATUS ####################'
  printf 'Containers:\n'; docker ps --filter name=remnanode --filter name=remnawave-nginx --format '  {{.Names}}\t{{.Status}}' 2>/dev/null || true
  printf '\nListeners:\n'; ss -lntup 2>/dev/null | grep -E '(:443[[:space:]]|:8443[[:space:]]|:2222[[:space:]])' | sed 's/^/  /' || true
  printf '\nTLS SelfSteal:\n'
  if [[ -r "$APP_DIR/.node_domain" ]]; then local domain; domain="$(cat "$APP_DIR/.node_domain")"; printf '' | openssl s_client -connect 127.0.0.1:8443 -servername "$domain" -tls1_2 2>/dev/null | awk '/Protocol  :|Cipher    :|Verify return code:/{print "  "$0}' || true; fi
  printf '\nCert mount in remnanode:\n'; docker exec remnanode sh -c 'test -s /etc/xray/certs/fullchain.pem && test -s /etc/xray/certs/privkey.pem && echo "  OK /etc/xray/certs"' 2>/dev/null || warn "Сертификаты внутри remnanode не подтверждены"
  [[ -r "$APP_DIR/config-profile-public.txt" ]] && { printf '\nProfile:\n'; sed 's/^/  /' "$APP_DIR/config-profile-public.txt"; }
  echo '#################### КОНЕЦ ВЫВОДА: NODE STATUS ####################'
  pause_prompt
}

run_legacy_tools(){
  clear
  warn "Это старое меню v1.7.2. Не запускайте в нем 'Первоначальную настройку' поверх production-ноды."
  warn "Оно оставлено только для Telemt, диагностики и старых сервисных функций."
  printf 'Продолжить? [y/N]: '
  local answer; read -r answer
  case "${answer:-N}" in [Yy]*) ensure_legacy; bash "$LEGACY_DIR/setup_node_legacy.sh" ;; *) return ;; esac
}

main_menu(){
  while true; do
    clear
    printf '%b============================================================%b\n' "$C" "$N"
    printf '%b  REMNANODE PRODUCTION · XHTTP + REALITY · TCP/443%b\n' "$C" "$N"
    printf '%b============================================================%b\n' "$C" "$N"
    if [[ -f "$APP_DIR/docker-compose.yml" ]]; then printf 'Нода: %bустановлена%b\n' "$G" "$N"; else printf 'Нода: %bне установлена%b\n' "$Y" "$N"; fi
    printf '\n  1) Полная установка / переустановка production-схемы\n  2) Remnawave Config Profile / Hysteria2\n  3) SelfSteal: STREAM / RADIO\n  4) Статус и диагностика\n  5) Legacy-инструменты (Telemt и старые сервисные функции)\n  9) Полная очистка старого Remna/Proxy-стека до нуля\n  0) Выход\n\nВыбор [0]: '
    local choice; read -r choice; choice=${choice:-0}
    case "$choice" in 1) run_full_install ;; 2) run_profile_manager ;; 3) run_selfsteal_manager ;; 4) show_status ;; 5) run_legacy_tools ;; 9) run_zero_reset ;; 0) return 0 ;; *) warn "Неизвестный пункт"; sleep 1 ;; esac
  done
}

main(){
  command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl ca-certificates; }
  register_globally || true
  main_menu
}

main "$@"
