#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

BRANCH="${REMNANODE_REPO_REF:-fix/xhttp-raw-hysteria-from-july7}"
BASE_RAW="https://raw.githubusercontent.com/evgmahov-blip/setup-remna-node/${BRANCH}"
WORK_DIR="${WORK_DIR:-/opt/remnanode/next-installer}"
APP_DIR="${APP_DIR:-/opt/remnanode}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[38;5;244m'
NC='\033[0m'

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf '%b\n' "${RED}[ОШИБКА]${NC} Запусти от root"
  exit 1
fi

mkdir -p "$WORK_DIR"

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

fetch_module(){
  local rel="$1" dst="$2"
  local url="${BASE_RAW}/${rel}"
  if curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 45 "$url" -o "$dst"; then
    chmod 0755 "$dst"
    if bash -n "$dst"; then
      return 0
    fi
    printf '%b\n' "${RED}[ОШИБКА]${NC} Синтаксис не прошёл проверку: $rel"
  else
    printf '%b\n' "${RED}[ОШИБКА]${NC} Не удалось скачать: $url"
  fi
  return 1
}

run_legacy(){
  local f="$WORK_DIR/setup_node-legacy.sh"
  echo -e "${BLUE}[LEGACY]${NC} Запускаю рабочий установщик от 7 июля без изменения его архитектуры."
  fetch_module "setup_node.sh" "$f" || return 1
  REMNANODE_REPO_REF="$BRANCH" bash "$f"
}

run_transport(){
  local f="$WORK_DIR/remnawave-transport-manager.sh"
  fetch_module "production/remnawave-transport-manager.sh" "$f" || return 1
  APP_DIR="$APP_DIR" bash "$f"
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
  local d="$APP_DIR/remnawave-profiles"
  if [[ ! -d "$d" ]]; then
    echo 'Профили ещё не генерировались.'
    pause
    return 0
  fi
  find "$d" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort || true
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
  printf '  %-22s %s\n' 'Node domain:' "$(cat "$APP_DIR/.node_domain" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Legacy protocol:' "$(cat "$APP_DIR/.protocol" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Transport profile:' "$(cat "$APP_DIR/.transport" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Reality SNI:' "$(cat "$APP_DIR/.reality_sni" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Reality target:' "$(cat "$APP_DIR/.reality_target" 2>/dev/null || echo '-')"
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
    echo -e "${BLUE}  [NODE / БАЗА]${NC}"
    echo -e "   ${WHITE}1)${NC} 🚀 Установка и штатное управление нодой ${GRAY}(рабочая база 07.07)${NC}"
    echo -e "   ${WHITE}2)${NC} 📊 Сводный статус ноды / портов / модулей"
    echo
    echo -e "${CYAN}  [TRANSPORT / REMNAWAVE]${NC}"
    echo -e "   ${WHITE}3)${NC} ⚡ Создать Config Profile + Host для XHTTP / RAW / Hysteria2"
    echo -e "   ${WHITE}4)${NC} 📁 Показать созданные профили и Host-подсказки"
    echo
    echo -e "${MAGENTA}  [REALITY / SNI]${NC}"
    echo -e "   ${WHITE}5)${NC} 🎭 Показать текущий SNI / target / состояние пула"
    echo -e "      ${GRAY}Смена SNI — только вручную внутри пункта 3, без автопереключений.${NC}"
    echo
    echo -e "${YELLOW}  [SECURITY]${NC}"
    echo -e "   ${WHITE}6)${NC} 🛡️  RKN Watcher — установка / статус / apply / удаление"
    echo
    echo -e "${BLUE}  [ЧТО ОСТАЛОСЬ В СТАРОМ МЕНЮ]${NC}"
    echo -e "      ${GRAY}SelfSteal сайты, SSL, Telemt, Xray version, UFW, IPv6, логи, тесты — пункт 1.${NC}"
    echo
    echo -e "${RED}  [ВЫХОД]${NC}"
    echo -e "   ${WHITE}0)${NC} Закрыть меню"
    echo
    echo -e "${GRAY}────────────────────────────────────────────────────────────────────${NC}"
    read -r -p 'Выбери действие [0-6]: ' choice

    case "${choice:-0}" in
      1) run_legacy; pause ;;
      2) show_status ;;
      3) run_transport; pause ;;
      4) show_profiles ;;
      5) show_sni ;;
      6) run_rkn; pause ;;
      0) return 0 ;;
      *) echo -e "${RED}[ОШИБКА]${NC} Неверный пункт"; sleep 1 ;;
    esac
  done
}

menu
