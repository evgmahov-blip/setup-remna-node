#!/usr/bin/env bash
# ==============================================================================
# Remnanode Production Installer v2.0
# Public TCP/443: nginx SNI frontend + independent SelfSteal
# Primary proxy: VLESS + XHTTP + REALITY -> internal TCP/10443
# Optional: Hysteria2 -> UDP/443
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

node_domain(){ cat "$APP_DIR/.node_domain" 2>/dev/null || true; }
reality_sni(){ cat "$APP_DIR/.reality_sni" 2>/dev/null || true; }
profile_exists(){ [[ -s "$APP_DIR/config-profile.json" ]]; }
hysteria_state(){ cat "$APP_DIR/.hysteria2-enabled" 2>/dev/null || echo 0; }

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

show_profile_state(){
  printf '  Домен:            %s\n' "$(node_domain)"
  printf '  SelfSteal:        %s\n' "$(sed -n 's/^TYPE=//p' "$APP_DIR/.selfsteal-site" 2>/dev/null || echo 'не настроен')"
  if profile_exists; then
    printf '  Локальный JSON:   СОЗДАН (это еще не означает, что он назначен ноде в панели)\n'
  else
    printf '  Локальный JSON:   НЕ СОЗДАН\n'
  fi
  printf '  XHTTP path:       %s\n' "$(cat "$APP_DIR/.xhttp_path" 2>/dev/null || echo 'еще не создан')"
  printf '  REALITY SNI:      %s\n' "$(reality_sni)"
  if [[ "$(hysteria_state)" == 1 ]]; then printf '  Hysteria2:        ВКЛЮЧЕНА\n'; else printf '  Hysteria2:        выключена\n'; fi
}

run_profile_generator(){
  local mode="$1"
  ensure_bundle
  # Сначала гарантируем независимый публичный сайт на TCP/443.
  # Xray после этого должен слушать внутренний 127.0.0.1:10443 из сгенерированного профиля.
  bash "$PRODUCTION_DIR/configure-selfsteal-nginx.sh"
  ENABLE_HYSTERIA2="$mode" bash "$PRODUCTION_DIR/generate-remnawave-profile.sh"
}

run_profile_manager(){
  clear; ensure_bundle
  [[ -f "$APP_DIR/docker-compose.yml" ]] || { fail "Нода еще не установлена"; pause_prompt; return; }

  printf '%b=== ТРАНСПОРТЫ И REMNAWAVE CONFIG PROFILE ===%b\n\n' "$C" "$N"
  show_profile_state
  printf '\nЧто здесь происходит:\n'
  printf '  - скрипт генерирует ПОЛНЫЙ серверный Config Profile;\n'
  printf '  - JSON из пункта 1/2 копируешь целиком в Management -> Config Profiles;\n'
  printf '  - после этого назначаешь профиль ноде;\n'
  printf '  - затем создаешь Host по готовым значениям из пункта 3;\n'
  printf '  - External XRAY_JSON не заменяется: для него генерируется отдельный injectHosts-фрагмент.\n\n'

  printf '  1) СГЕНЕРИРОВАТЬ И СРАЗУ ВЫВЕСТИ JSON ДЛЯ COPY-PASTE (Hysteria2 оставить как сейчас)\n'
  printf '  2) СГЕНЕРИРОВАТЬ И ВЫВЕСТИ JSON + заново выбрать Hysteria2\n'
  printf '  3) Показать точные значения Host для Remnawave\n'
  printf '  4) Повторно вывести полный Config Profile JSON\n'
  printf '  5) Показать injectHosts-фрагмент для существующего External XRAY_JSON\n'
  printf '  6) Проверить сайт и REALITY-маршрут\n'
  printf '  0) Назад\n\nВыбор [0]: '
  local choice; read -r choice; choice=${choice:-0}
  case "$choice" in
    1) run_profile_generator keep ;;
    2) run_profile_generator ask ;;
    3) [[ -r "$APP_DIR/remnawave-ready.txt" ]] && cat "$APP_DIR/remnawave-ready.txt" || warn "Сначала выбери пункт 1 или 2" ;;
    4) [[ -r "$APP_DIR/config-profile.json" ]] && { echo '#################### НАЧАЛО ВЫВОДА: COPY-PASTE REMNAWAVE CONFIG PROFILE ####################'; cat "$APP_DIR/config-profile.json"; echo '#################### КОНЕЦ ВЫВОДА: COPY-PASTE REMNAWAVE CONFIG PROFILE ####################'; } || warn "Сначала выбери пункт 1 или 2" ;;
    5) [[ -r "$APP_DIR/external-json-inject-snippet.json" ]] && cat "$APP_DIR/external-json-inject-snippet.json" || warn "Сначала выбери пункт 1 или 2" ;;
    6) run_selfsteal_test ;;
    0) return ;;
    *) warn "Неизвестный пункт" ;;
  esac
  pause_prompt
}

run_selfsteal_manager(){
  clear; ensure_bundle
  [[ -f "$APP_DIR/docker-compose.yml" ]] || { fail "Нода еще не установлена"; pause_prompt; return; }
  printf '%b=== SELFSTEAL SITE ===%b\n' "$C" "$N"
  [[ -r "$APP_DIR/.selfsteal-site" ]] && { printf 'Текущая конфигурация:\n'; sed 's/^/  /' "$APP_DIR/.selfsteal-site"; }
  printf '\nПубличный сайт всегда должен открываться по https://%s/ независимо от Config Profile.\n' "$(node_domain)"
  printf '\n  1) STREAM — versioned сайт из этого репозитория\n'
  printf '  2) RADIO — radio-stub-site + скрытый URL управления\n'
  printf '  3) Показать URL управления RADIO\n'
  printf '  4) Проверить публичный и локальный SelfSteal\n'
  printf '  0) Назад\nВыбор [0]: '
  local choice; read -r choice; choice=${choice:-0}
  case "$choice" in
    1) SELFSTEAL_SITE=stream REMNANODE_REPO="$REPO" REMNANODE_REPO_REF="$REPO_REF" bash "$PRODUCTION_DIR/install-stream-site.sh"; bash "$PRODUCTION_DIR/configure-selfsteal-nginx.sh" ;;
    2) SELFSTEAL_SITE=radio REMNANODE_REPO="$REPO" REMNANODE_REPO_REF="$REPO_REF" bash "$PRODUCTION_DIR/install-stream-site.sh"; bash "$PRODUCTION_DIR/configure-selfsteal-nginx.sh" ;;
    3) show_radio_admin ;;
    4) run_selfsteal_test ;;
    0) return ;;
    *) warn "Неизвестный пункт" ;;
  esac
  pause_prompt
}

show_radio_admin(){
  local state="$APP_DIR/.selfsteal-site" domain path
  [[ -r "$state" ]] || { warn "SelfSteal еще не настроен"; return 0; }
  if ! grep -q '^TYPE=radio$' "$state"; then warn "Сейчас выбран не RADIO"; return 0; fi
  domain="$(node_domain)"
  path="$(sed -n 's/^ADMIN_PATH=//p' "$state")"
  [[ -n "$domain" && -n "$path" ]] || { warn "Не удалось определить URL"; return 0; }
  printf 'RADIO management: %bhttps://%s%s%b\n' "$C" "$domain" "$path" "$N"
}

run_selfsteal_test(){
  local domain sni local_code public_code reality_code owner443
  domain="$(node_domain)"
  sni="$(reality_sni)"
  [[ -n "$domain" ]] || { warn "Домен ноды не найден"; return 0; }

  echo '#################### НАЧАЛО ВЫВОДА: SELFSTEAL TEST ####################'
  owner443="$(ss -lntp 2>/dev/null | awk '$4 ~ /:443$/ {print; exit}')"
  printf 'TCP/443 owner: %s\n' "${owner443:-не найден}"

  local_code="$(curl -ksS --tls-max 1.2 --resolve "$domain:8443:127.0.0.1" -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "https://$domain:8443/" 2>/dev/null || true)"
  if [[ "$local_code" =~ ^[23][0-9][0-9]$ ]]; then ok "локальный backend 127.0.0.1:8443 -> HTTP $local_code"; else warn "локальный backend -> ${local_code:-000}"; fi

  public_code="$(curl -ksS --tls-max 1.2 --resolve "$domain:443:127.0.0.1" -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "https://$domain/" 2>/dev/null || true)"
  if [[ "$public_code" =~ ^[23][0-9][0-9]$ ]]; then
    ok "ПУБЛИЧНЫЙ SelfSteal https://$domain/ -> HTTP $public_code (не зависит от Remnawave profile)"
  else
    warn "Публичный SelfSteal не работает: HTTP ${public_code:-000}"
  fi

  if [[ -n "$sni" ]]; then
    reality_code="$(curl -ksS --tls-max 1.2 --resolve "$sni:443:127.0.0.1" -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "https://$sni/" 2>/dev/null || true)"
    if [[ "$reality_code" =~ ^[23][0-9][0-9]$ ]]; then
      ok "REALITY SNI route $sni -> Xray -> fallback HTTP $reality_code"
    else
      warn "REALITY SNI route пока не подтвержден (${reality_code:-000}). После назначения нового профиля rw-core должен слушать 127.0.0.1:10443."
    fi
  fi
  echo '#################### КОНЕЦ ВЫВОДА: SELFSTEAL TEST ####################'
}

show_status(){
  clear
  echo '#################### НАЧАЛО ВЫВОДА: NODE STATUS ####################'
  printf 'Domain: %s\n' "$(node_domain)"
  printf 'Local Config Profile: '; if profile_exists; then echo 'CREATED (назначение в панели отдельно)'; else echo 'NOT CREATED'; fi
  printf 'Hysteria2: '; if [[ "$(hysteria_state)" == 1 ]]; then echo 'ENABLED'; else echo 'DISABLED'; fi
  printf '\nContainers:\n'; docker ps --filter name=remnanode --filter name=remnawave-nginx --format '  {{.Names}}\t{{.Status}}' 2>/dev/null || true
  printf '\nListeners:\n'; ss -lntup 2>/dev/null | grep -E '(:443[[:space:]]|:10443[[:space:]]|:8443[[:space:]]|:2222[[:space:]])' | sed 's/^/  /' || true
  printf '\nCert mount in remnanode:\n'; docker exec remnanode sh -c 'test -s /etc/xray/certs/fullchain.pem && test -s /etc/xray/certs/privkey.pem && echo "  OK /etc/xray/certs"' 2>/dev/null || warn "Сертификаты внутри remnanode не подтверждены"
  [[ -r "$APP_DIR/.selfsteal-site" ]] && { printf '\nSelfSteal:\n'; sed 's/^/  /' "$APP_DIR/.selfsteal-site"; }
  [[ -r "$APP_DIR/config-profile-public.txt" ]] && { printf '\nProfile summary:\n'; sed 's/^/  /' "$APP_DIR/config-profile-public.txt"; }
  printf '\n'; run_selfsteal_test
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
    printf '%b  REMNANODE PRODUCTION · SELFSTEAL + XHTTP/REALITY%b\n' "$C" "$N"
    printf '%b============================================================%b\n' "$C" "$N"
    if [[ -f "$APP_DIR/docker-compose.yml" ]]; then printf 'Нода: %bустановлена%b\n' "$G" "$N"; else printf 'Нода: %bне установлена%b\n' "$Y" "$N"; fi
    if [[ -f "$APP_DIR/docker-compose.yml" ]]; then
      printf 'Локальный профиль: '; if profile_exists; then printf '%bсоздан%b\n' "$G" "$N"; else printf '%bНЕ создан%b\n' "$Y" "$N"; fi
      printf 'SelfSteal: %s\n' "$(sed -n 's/^TYPE=//p' "$APP_DIR/.selfsteal-site" 2>/dev/null || echo 'не настроен')"
      printf 'Public site: https://%s/\n' "$(node_domain)"
    fi
    printf '\n  1) Полная установка / переустановка production-ноды\n'
    printf '  2) Сгенерировать COPY-PASTE Config Profile + Host + External JSON данные\n'
    printf '  3) SelfSteal сайт: STREAM / RADIO + публичная проверка\n'
    printf '  4) Полная диагностика ноды\n'
    printf '  5) Legacy-инструменты: Telemt и старые сервисные функции\n'
    printf '  9) Полностью удалить старый Remna/Proxy-стек\n'
    printf '  0) Выход\n\nВыбор [0]: '
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
