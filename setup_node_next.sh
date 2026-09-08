#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

MODULE_REF="${REMNANODE_REPO_REF:-1d699a3a5322e3e5ae6bf07853ae200613cec05f}"
LEGACY_COMMIT="${REMNANODE_LEGACY_COMMIT:-34aeaa99aa1a5c21fc4f9d0c976d38607d025353}"
REPO="evgmahov-blip/setup-remna-node"
MODULE_RAW="https://raw.githubusercontent.com/${REPO}/${MODULE_REF}"
LEGACY_RAW="https://raw.githubusercontent.com/${REPO}/${LEGACY_COMMIT}"
WORK_DIR="${WORK_DIR:-/opt/remnanode/next-installer}"
APP_DIR="${APP_DIR:-/opt/remnanode}"
LEGACY_SHA256="aa79bc94916d41770b18dbad2ca0890123fc64cd5ce397841ca9f92e05dc67bf"

declare -A MODULE_SHA256=(
  [production/remnawave-transport-manager.sh]="441c82fb0eb3b155986d7b84bd66aa82bb1d028b8a9c49e02f1fbac326fac2e2"
  [production/xhttp-signature-manager.sh]="dbbd1110aec2e6dd32aee204b6d0174d7fe511e1b97118570cbbea553946bd4a"
  [production/rkn-watcher-manager.sh]="a1a0be918af606048d025459b811de17e64970c70acbba0c8f4841aa053c3444"
  [production/selfsteal-site-manager.sh]="e0e9b24bf8c5cdbdf8b7714d12e69d94e6d775031802358c209a4e06c5fe75d4"
  [production/validate-generated-profile.sh]="df0edf610cd11cc0d311dd59f46fe5c263c535dbfcceeb8af90d9d25d89d0bf6"
  [production/network-tuning-manager.sh]="25ebe8434d96b5b55d248ec709e275913d9a227518b978b8bd0be7f3e0784af9"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[38;5;244m'
NC='\033[0m'

preflight(){
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    printf '%b\n' "${RED}[ОШИБКА]${NC} Запусти от root"
    return 1
  fi
  [[ "$MODULE_REF" =~ ^[0-9a-f]{40}$ ]] || { printf '%b\n' "${RED}[ОШИБКА]${NC} MODULE_REF должен быть immutable 40-символьным commit SHA"; return 1; }
  [[ "$LEGACY_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { printf '%b\n' "${RED}[ОШИБКА]${NC} LEGACY_COMMIT должен быть immutable 40-символьным commit SHA"; return 1; }
  mkdir -p "$WORK_DIR"
}

pause(){
  echo
  read -r -p 'Нажми Enter для продолжения...' _
}

status_badge(){
  local name="$1" ok="$2"
  if [[ "$ok" == "1" ]]; then
    printf '%b' "${GREEN}[ON]${NC} $name"
  else
    printf '%b' "${GRAY}[OFF]${NC} $name"
  fi
}

fetch_url(){
  local url="$1" dst="$2" label="$3" want="${4:-}" got tmp
  tmp="${dst}.part"
  rm -f "$tmp"
  if ! curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 45 "$url" -o "$tmp"; then
    rm -f "$tmp"
    printf '%b\n' "${RED}[ОШИБКА]${NC} Не удалось скачать: $url"
    return 1
  fi

  if [[ -n "$want" ]]; then
    got="$(sha256sum "$tmp" | cut -d' ' -f1)"
    if [[ "$got" != "$want" ]]; then
      rm -f "$tmp"
      printf '%b\n' "${RED}[ОШИБКА]${NC} SHA256 не совпал для $label"
      printf '%b\n' "${GRAY}  ожидали: $want${NC}"
      printf '%b\n' "${GRAY}  получили: $got${NC}"
      return 1
    fi
  fi

  if ! bash -n "$tmp"; then
    rm -f "$tmp"
    printf '%b\n' "${RED}[ОШИБКА]${NC} Синтаксис не прошёл проверку: $label"
    return 1
  fi

  chmod 0755 "$tmp"
  mv -f "$tmp" "$dst"
}

fetch_module(){
  local rel="$1" dst="$2" want="${MODULE_SHA256[$1]:-}"
  [[ -n "$want" ]] || { printf '%b\n' "${RED}[ОШИБКА]${NC} Нет эталонного SHA256 для $rel"; return 1; }
  fetch_url "${MODULE_RAW}/${rel}" "$dst" "$rel@${MODULE_REF}" "$want"
}

run_network_tuning(){
  local f="$WORK_DIR/network-tuning-manager.sh"
  fetch_module "production/network-tuning-manager.sh" "$f" || return 1
  bash "$f" apply
}

run_selfsteal_default(){
  local f="$WORK_DIR/selfsteal-site-manager.sh"
  fetch_module "production/selfsteal-site-manager.sh" "$f" || return 1
  APP_DIR="$APP_DIR" bash "$f" ensure
}

run_selfsteal_site(){
  local f="$WORK_DIR/selfsteal-site-manager.sh"
  fetch_module "production/selfsteal-site-manager.sh" "$f" || return 1
  APP_DIR="$APP_DIR" bash "$f" choose
}

run_legacy(){
  local f="$WORK_DIR/setup_node-legacy.sh" rc
  echo -e "${GREEN}[STABLE 07.07]${NC} Запускаю зафиксированную рабочую базу."
  echo -e "${GRAY}Commit: ${LEGACY_COMMIT}${NC}"
  fetch_url "${LEGACY_RAW}/setup_node.sh" "$f" "setup_node.sh@${LEGACY_COMMIT}" "$LEGACY_SHA256" || return 1
  if bash "$f"; then
    echo -e "${GREEN}[NETWORK]${NC} Применяю проверенный NEXT-профиль сети: fq + BBR по умолчанию, если BBR доступен."
    if ! run_network_tuning; then
      echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} Базовая установка завершена, но сетевой профиль прошёл не все проверки."
    fi
    if [[ -d /var/www/html && -f "$APP_DIR/docker-compose.yml" ]]; then
      echo -e "${GREEN}[SELFSTEAL]${NC} Применяю сохранённый сайт; если выбор ещё не делали — STREAM."
      run_selfsteal_default
    fi
  else
    rc=$?
    return "$rc"
  fi
}

run_transport(){
  local f="$WORK_DIR/remnawave-transport-manager.sh"
  local xhttp_sig="$WORK_DIR/xhttp-signature-manager.sh" _sig_ok
  fetch_module "production/remnawave-transport-manager.sh" "$f" || return 1
  APP_DIR="$APP_DIR" XHTTP_SIGNATURE_MODE=none bash "$f" || return 1

  if [[ "$(cat "$APP_DIR/.transport" 2>/dev/null || true)" == "xhttp" ]]; then
    fetch_module "production/xhttp-signature-manager.sh" "$xhttp_sig" || return 1
    APP_DIR="$APP_DIR" bash "$xhttp_sig" revert >/dev/null || return 1
    echo
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} XHTTP signature — общий секрет клиента и сервера."
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} Пока не подтверждено, что Remnawave переносит extra в клиент один-в-один,"
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} базовый профиль оставляем БЕЗ signature."
    read -r -p 'Применить signature сейчас? Введите SIGN (пусто = пропустить): ' _sig_ok
    if [[ "$_sig_ok" == 'SIGN' ]]; then
      APP_DIR="$APP_DIR" bash "$xhttp_sig" apply
    else
      echo -e "${GREEN}[OK]${NC} XHTTP оставлен без signature — совместимый режим для первого live-теста."
    fi
  fi
}

run_xhttp_signature(){
  local f="$WORK_DIR/xhttp-signature-manager.sh" choice
  fetch_module "production/xhttp-signature-manager.sh" "$f" || return 1
  echo
  echo -e "${CYAN}[XHTTP SIGNATURE]${NC}"
  echo '  1) Применить сохранённую signature + Host extra'
  echo '  2) Снять signature с профиля (revert)'
  echo '  3) Показать сохранённую signature'
  echo '  0) Назад'
  read -r -p 'Выбор [0]: ' choice
  case "${choice:-0}" in
    1) APP_DIR="$APP_DIR" bash "$f" apply ;;
    2) APP_DIR="$APP_DIR" bash "$f" revert ;;
    3) APP_DIR="$APP_DIR" bash "$f" show ;;
    0) return 0 ;;
    *) echo -e "${RED}[ОШИБКА]${NC} Неверный пункт"; return 1 ;;
  esac
}

run_rkn(){
  local f="$WORK_DIR/rkn-watcher-manager.sh"
  fetch_module "production/rkn-watcher-manager.sh" "$f" || return 1
  APP_DIR="$APP_DIR" bash "$f"
}

show_sni(){
  clear || true
  echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}║              REALITY SNI / CAMOUFLAGE STATUS              ║${NC}"
  echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
  printf 'Current SNI:    '
  if [[ -s "$APP_DIR/.reality_sni" ]]; then cat "$APP_DIR/.reality_sni"; else echo 'не задан'; fi
  printf 'Current target: '
  if [[ -s "$APP_DIR/.reality_target" ]]; then cat "$APP_DIR/.reality_target"; else echo 'не задан'; fi
  printf 'Pool cache:     '
  if [[ -s "$APP_DIR/reality-targets.cache" ]]; then
    echo "$(wc -l < "$APP_DIR/reality-targets.cache" | tr -d ' ') доменов"
  else
    echo 'нет'
  fi
  echo
  echo -e "${YELLOW}[ВАЖНО]${NC} Обновление списка SNI не меняет текущий рабочий SNI автоматически."
  echo -e "${YELLOW}[ВАЖНО]${NC} Смена SNI выполняется только вручную через Transport Manager."
  pause
}

show_profiles(){
  clear || true
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║                  REMNAWAVE PROFILES / HOSTS                ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
  local d="$APP_DIR/remnawave-profiles" active="" f base active_file=""
  if [[ ! -d "$d" ]]; then
    echo 'Профили ещё не генерировались.'
    pause
    return 0
  fi
  active="$(cat "$APP_DIR/.transport" 2>/dev/null || true)"
  case "$active" in
    xhttp) active_file='xhttp-reality.json' ;;
    raw) active_file='raw-reality.json' ;;
    hysteria) active_file='hysteria2-tls.json' ;;
    combined) active_file='xhttp-hysteria2.json' ;;
  esac
  while IFS= read -r f; do
    base="$(basename "$f")"
    if [[ "$base" == "$active_file" ]]; then
      echo -e "${GREEN}[АКТИВЕН]${NC} $base"
    else
      echo "          $base"
    fi
  done < <(find "$d" -maxdepth 1 -type f ! -name '.*' -print 2>/dev/null | sort)
  echo
  echo -e "${GRAY}Каталог:${NC} $d"
  pause
}

show_status(){
  clear || true
  echo -e "${WHITE}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${WHITE}║                       STATUS SUMMARY                       ║${NC}"
  echo -e "${WHITE}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo

  local node=0 nginx=0 rkn=0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode && node=1 || true
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnawave-nginx && nginx=1 || true
  [[ -x /usr/local/bin/rkn-watcher || -x /opt/rkn-watcher/rkn-watcher.sh ]] && rkn=1 || true

  printf '  '; status_badge 'Remnawave node' "$node"; echo
  printf '  '; status_badge 'SelfSteal nginx' "$nginx"; echo
  printf '  '; status_badge 'RKN Watcher' "$rkn"; echo

  echo
  printf '  %-22s %s\n' 'Stable base:' "$LEGACY_COMMIT"
  printf '  %-22s %s\n' 'Module commit:' "$MODULE_REF"
  printf '  %-22s %s\n' 'Node domain:' "$(cat "$APP_DIR/.node_domain" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Legacy protocol:' "$(cat "$APP_DIR/.protocol" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Transport profile:' "$(cat "$APP_DIR/.transport" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Reality SNI:' "$(cat "$APP_DIR/.reality_sni" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Reality target:' "$(cat "$APP_DIR/.reality_target" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'SelfSteal site:' "$(cat "$APP_DIR/.selfsteal_site" 2>/dev/null || echo 'stream (default)')"
  printf '  %-22s %s\n' 'TCP CC:' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Default qdisc:' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'XHTTP signature:' "$( [[ -s "$APP_DIR/xhttp-signature.json" ]] && echo saved || echo '-' )"
  echo
  echo -e "${BLUE}[PORTS]${NC}"
  ss -lntup 2>/dev/null | grep -E '(:443[[:space:]]|:2222[[:space:]]|:80[[:space:]])' || true
  pause
}

menu(){
  while true; do
    clear || true
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        REMNANODE NEXT — STABLE JULY CORE + NEW MODULES          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}  [NODE / СТАБИЛЬНАЯ БАЗА]${NC}"
    echo -e "   ${WHITE}1)${NC} 🚀 Установка и штатное управление нодой ${GRAY}(зафиксированный commit 07.07)${NC}"
    echo -e "   ${WHITE}2)${NC} 📊 Сводный статус ноды / портов / модулей"
    echo
    echo -e "${CYAN}  [TRANSPORT / REMNAWAVE]${NC}"
    echo -e "   ${WHITE}3)${NC} ⚡ Создать Config Profile + Host для XHTTP / RAW / Hysteria2 / XHTTP+Hysteria2"
    echo -e "   ${WHITE}4)${NC} 📁 Показать созданные профили и Host-подсказки"
    echo -e "   ${WHITE}5)${NC} 🧬 XHTTP signature — применить / снять / показать"
    echo
    echo -e "${MAGENTA}  [REALITY / SNI]${NC}"
    echo -e "   ${WHITE}6)${NC} 🎭 Показать текущий SNI / target / состояние пула"
    echo -e "   ${WHITE}7)${NC} 🌐 SelfSteal сайт — STREAM / RADIO ${GRAY}(default: STREAM)${NC}"
    echo -e "      ${GRAY}Смена SNI — только вручную внутри пункта 3, без автопереключений.${NC}"
    echo
    echo -e "${YELLOW}  [SECURITY]${NC}"
    echo -e "   ${WHITE}8)${NC} 🛡️  RKN Watcher — установка / статус / apply / удаление"
    echo
    echo -e "${BLUE}  [СТАРЫЕ ПРОВЕРЕННЫЕ ФУНКЦИИ]${NC}"
    echo -e "      ${GRAY}SSL, Telemt, Xray version, UFW, IPv6, логи, тесты — пункт 1.${NC}"
    echo
    echo -e "${RED}  [ВЫХОД]${NC}"
    echo -e "   ${WHITE}0)${NC} Закрыть меню"
    echo
    echo -e "${GRAY}────────────────────────────────────────────────────────────────────${NC}"
    read -r -p 'Выбери действие [0-8]: ' choice

    case "${choice:-0}" in
      1) run_legacy; pause ;;
      2) show_status ;;
      3) run_transport; pause ;;
      4) show_profiles ;;
      5) run_xhttp_signature; pause ;;
      6) show_sni ;;
      7) run_selfsteal_site; pause ;;
      8) run_rkn; pause ;;
      0) return 0 ;;
      *) echo -e "${RED}[ОШИБКА]${NC} Неверный пункт"; sleep 1 ;;
    esac
  done
}

main(){
  preflight || return 1
  menu
}

main "$@"