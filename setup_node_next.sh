#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

MODULE_REF="${REMNANODE_REPO_REF:-7b57a221ea822d536995bcb18ec8ffe3420c3f7c}"
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
  [production/rkn-watcher-manager.sh]="286a1b9979811dec1f265d5c6beb8a26cb52ebced2583e93276e13879412a92a"
  [production/selfsteal-site-manager.sh]="5e6661f88700d7e8909c4b642084065d135c7d6a2e74e20711aabde7b0daa64d"
  [production/validate-generated-profile.sh]="df0edf610cd11cc0d311dd59f46fe5c263c535dbfcceeb8af90d9d25d89d0bf6"
  [production/network-tuning-manager.sh]="25ebe8434d96b5b55d248ec709e275913d9a227518b978b8bd0be7f3e0784af9"
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
MAGENTA='\033[0;35m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[38;5;244m'; NC='\033[0m'

preflight(){
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then printf '%b\n' "${RED}[ОШИБКА]${NC} Запусти от root"; return 1; fi
  [[ "$MODULE_REF" =~ ^[0-9a-f]{40}$ ]] || { printf '%b\n' "${RED}[ОШИБКА]${NC} MODULE_REF должен быть immutable 40-символьным commit SHA"; return 1; }
  [[ "$LEGACY_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { printf '%b\n' "${RED}[ОШИБКА]${NC} LEGACY_COMMIT должен быть immutable 40-символьным commit SHA"; return 1; }
  mkdir -p "$WORK_DIR"
}

pause(){ echo; read -r -p 'Нажми Enter для продолжения...' _; }
status_badge(){ local name="$1" ok="$2"; [[ "$ok" == 1 ]] && printf '%b' "${GREEN}[ON]${NC} $name" || printf '%b' "${GRAY}[OFF]${NC} $name"; }

fetch_url(){
  local url="$1" dst="$2" label="$3" want="${4:-}" got tmp="${dst}.part"
  rm -f "$tmp"
  if ! curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 45 "$url" -o "$tmp"; then rm -f "$tmp"; printf '%b\n' "${RED}[ОШИБКА]${NC} Не удалось скачать: $url"; return 1; fi
  if [[ -n "$want" ]]; then got="$(sha256sum "$tmp" | cut -d' ' -f1)"; [[ "$got" == "$want" ]] || { rm -f "$tmp"; printf '%b\n' "${RED}[ОШИБКА]${NC} SHA256 не совпал для $label"; return 1; }; fi
  bash -n "$tmp" || { rm -f "$tmp"; printf '%b\n' "${RED}[ОШИБКА]${NC} Синтаксис не прошёл проверку: $label"; return 1; }
  chmod 0755 "$tmp"; mv -f "$tmp" "$dst"
}
fetch_module(){ local rel="$1" dst="$2" want="${MODULE_SHA256[$1]:-}"; [[ -n "$want" ]] || { echo "[ОШИБКА] Нет SHA256 для $rel"; return 1; }; fetch_url "${MODULE_RAW}/${rel}" "$dst" "$rel@${MODULE_REF}" "$want"; }

run_network_tuning(){ local f="$WORK_DIR/network-tuning-manager.sh"; fetch_module production/network-tuning-manager.sh "$f" || return 1; bash "$f" apply; }
run_selfsteal_default(){ local f="$WORK_DIR/selfsteal-site-manager.sh"; fetch_module production/selfsteal-site-manager.sh "$f" || return 1; APP_DIR="$APP_DIR" bash "$f" ensure; }
run_selfsteal_site(){ local f="$WORK_DIR/selfsteal-site-manager.sh"; fetch_module production/selfsteal-site-manager.sh "$f" || return 1; APP_DIR="$APP_DIR" bash "$f" choose; }

rkn_guard_active(){ [[ -s "$APP_DIR/rkn-safe/.scanner-guard-active" ]] && command -v iptables >/dev/null 2>&1 && iptables -C INPUT -j REMNA_RKN_SCANNERS >/dev/null 2>&1; }
run_rkn_default(){
  local f="$WORK_DIR/rkn-watcher-manager.sh"
  if rkn_guard_active; then echo -e "${GREEN}[RKN]${NC} SAFE scanner guard уже активен; повторную установку пропускаю."; return 0; fi
  fetch_module production/rkn-watcher-manager.sh "$f" || return 1
  echo -e "${GREEN}[RKN]${NC} Ставлю SAFE scanner protection по умолчанию."
  APP_DIR="$APP_DIR" bash "$f" install-safe
}

prepare_legacy_for_next(){
  local f="$1" tmp="${f}.next"; rm -f "$tmp"
  if ! awk '
    BEGIN { skip_proto=0; proto_done=0; decoy_done=0 }
    /# Выбор протокола шифрования/ {
      print "    # NEXT: July base always installs Reality/SelfSteal; modern transports are generated later."
      print "    log \"${INFO} NEXT: базовая схема Reality/SelfSteal; XHTTP/RAW/Hysteria2 настраиваются отдельно.\""
      print "    local protocol=\"reality\""; skip_proto=1; proto_done=1; next
    }
    skip_proto && /# Скачивание и генерация маскировочного сайта SelfSteal/ { skip_proto=0; print; next }
    skip_proto { next }
    /read -p \"Домен маскировки \(decoy domain\) \[github\.com\]: \" decoy_domain/ { print "        decoy_domain=github.com"; decoy_done=1; next }
    { print }
    END { if (!proto_done || !decoy_done) exit 42 }
  ' "$f" > "$tmp"; then rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Не удалось адаптировать July base"; return 1; fi
  if grep -Fq 'read -p "Ваш выбор [1]: " proto_choice' "$tmp" || grep -Fq 'read -p "Домен маскировки (decoy domain) [github.com]: " decoy_domain' "$tmp"; then rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Остались старые transport/decoy prompts"; return 1; fi
  bash -n "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Адаптированный July base не прошёл bash -n"; return 1; }
  chmod 0755 "$tmp"; mv -f "$tmp" "$f"
  echo -e "${GREEN}[NEXT]${NC} Базовая схема фиксирована Reality/SelfSteal; современные транспорты настраиваются отдельно."
}

run_legacy(){
  local f="$WORK_DIR/setup_node-legacy.sh" rc
  echo -e "${GREEN}[STABLE 07.07]${NC} Запускаю зафиксированную рабочую базу."
  fetch_url "${LEGACY_RAW}/setup_node.sh" "$f" "setup_node.sh@${LEGACY_COMMIT}" "$LEGACY_SHA256" || return 1
  prepare_legacy_for_next "$f" || return 1
  if bash "$f"; then
    run_network_tuning || echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} Сетевой профиль прошёл не все проверки."
    if [[ -d /var/www/html && -f "$APP_DIR/docker-compose.yml" ]]; then run_selfsteal_default; fi
    run_rkn_default || echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} SAFE scanner protection не удалось активировать."
  else rc=$?; return "$rc"; fi
}

run_transport(){
  local f="$WORK_DIR/remnawave-transport-manager.sh" xhttp_sig="$WORK_DIR/xhttp-signature-manager.sh" sig_ok=''
  fetch_module production/remnawave-transport-manager.sh "$f" || return 1
  APP_DIR="$APP_DIR" XHTTP_SIGNATURE_MODE=none bash "$f" || return 1
  if [[ "$(cat "$APP_DIR/.transport" 2>/dev/null || true)" == xhttp ]]; then
    fetch_module production/xhttp-signature-manager.sh "$xhttp_sig" || return 1
    APP_DIR="$APP_DIR" bash "$xhttp_sig" revert >/dev/null || return 1
    echo; echo -e "${YELLOW}[ВНИМАНИЕ]${NC} XHTTP signature пока opt-in."
    read -r -p 'Применить signature сейчас? Введите SIGN (пусто = пропустить): ' sig_ok
    [[ "$sig_ok" == SIGN ]] && APP_DIR="$APP_DIR" bash "$xhttp_sig" apply || echo -e "${GREEN}[OK]${NC} XHTTP оставлен без signature."
  fi
}

run_xhttp_signature(){
  local f="$WORK_DIR/xhttp-signature-manager.sh" choice=''; fetch_module production/xhttp-signature-manager.sh "$f" || return 1
  echo '  1) Применить сохранённую signature + Host extra'; echo '  2) Снять signature с профиля'; echo '  3) Показать signature'; echo '  0) Назад'
  read -r -p 'Выбор [0]: ' choice
  case "${choice:-0}" in 1) APP_DIR="$APP_DIR" bash "$f" apply ;; 2) APP_DIR="$APP_DIR" bash "$f" revert ;; 3) APP_DIR="$APP_DIR" bash "$f" show ;; 0) return 0 ;; *) echo -e "${RED}[ОШИБКА]${NC} Неверный пункт"; return 1 ;; esac
}

run_rkn(){ local f="$WORK_DIR/rkn-watcher-manager.sh"; fetch_module production/rkn-watcher-manager.sh "$f" || return 1; APP_DIR="$APP_DIR" bash "$f" menu; }

show_sni(){
  clear || true
  echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}║              REALITY SNI / CAMOUFLAGE STATUS              ║${NC}"
  echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
  printf 'Current SNI:    '; [[ -s "$APP_DIR/.reality_sni" ]] && cat "$APP_DIR/.reality_sni" || echo 'не задан'
  printf 'Current target: '; [[ -s "$APP_DIR/.reality_target" ]] && cat "$APP_DIR/.reality_target" || echo 'не задан'
  printf 'Pool cache:     '; [[ -s "$APP_DIR/reality-targets.cache" ]] && echo "$(wc -l < "$APP_DIR/reality-targets.cache" | tr -d ' ') доменов" || echo 'нет'
  echo; echo -e "${YELLOW}[ВАЖНО]${NC} Обновление пула не меняет рабочий SNI автоматически."; pause
}

profile_paths(){
  local transport="$1"
  case "$transport" in
    xhttp) printf '%s\n%s\n' "$APP_DIR/remnawave-profiles/xhttp-reality.json" "$APP_DIR/remnawave-profiles/host-xhttp.txt" ;;
    raw) printf '%s\n%s\n' "$APP_DIR/remnawave-profiles/raw-reality.json" "$APP_DIR/remnawave-profiles/host-raw.txt" ;;
    hysteria) printf '%s\n%s\n' "$APP_DIR/remnawave-profiles/hysteria2-tls.json" "$APP_DIR/remnawave-profiles/host-hysteria2.txt" ;;
    combined) printf '%s\n%s\n%s\n' "$APP_DIR/remnawave-profiles/xhttp-hysteria2.json" "$APP_DIR/remnawave-profiles/host-xhttp.txt" "$APP_DIR/remnawave-profiles/host-hysteria2.txt" ;;
    *) return 1 ;;
  esac
}

print_profile_full(){
  local transport="$1" profile host host2='' remark
  local -a first=()
  mapfile -t first < <(profile_paths "$transport") || { echo -e "${RED}[ОШИБКА]${NC} Неизвестный transport: $transport"; return 1; }
  profile="${first[0]:-}"; host="${first[1]:-}"; host2="${first[2]:-}"
  [[ -s "$profile" ]] || { echo -e "${YELLOW}[НЕТ]${NC} Профиль ещё не создан: $profile"; return 1; }
  remark="$(sed -n 's/^Remark:[[:space:]]*//p' "$host" 2>/dev/null | head -1)"
  echo '#################### НАЧАЛО ВЫВОДА: REMNAWAVE PROFILE COPY ####################'
  echo "TRANSPORT: $transport"
  echo "PROFILE FILE: $profile"
  echo
  echo '=== ОПИСАНИЕ ХОСТА ==='
  echo "${remark:-$(basename "$profile")}" 
  echo
  echo '=== HOST REMNAWAVE ==='
  [[ -s "$host" ]] && cat "$host" || echo "Host-файл не найден: $host"
  if [[ -n "$host2" ]]; then echo; echo '=== HOST REMNAWAVE 2 ==='; [[ -s "$host2" ]] && cat "$host2" || echo "Host-файл не найден: $host2"; fi
  echo
  echo '=== ПОЛНЫЙ CONFIG PROFILE — КОПИРОВАТЬ В REMNAWAVE ==='
  cat "$profile"
  echo
  echo '#################### КОНЕЦ ВЫВОДА: REMNAWAVE PROFILE COPY ####################'
}

show_profiles(){
  local choice active
  while true; do
    clear || true
    active="$(cat "$APP_DIR/.transport" 2>/dev/null || true)"
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          ПРОСМОТР И КОПИРОВАНИЕ ПРОФИЛЕЙ REMNAWAVE        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo "Текущий transport: ${active:-не задан}"
    echo
    echo ' 1) Показать ТЕКУЩИЙ профиль + Host полностью'
    echo ' 2) XHTTP + REALITY'
    echo ' 3) RAW + REALITY'
    echo ' 4) Hysteria2 + TLS'
    echo ' 5) XHTTP + Hysteria2 (combined)'
    echo ' 6) Показать список созданных файлов'
    echo ' 0) Назад'
    read -r -p 'Выбор [1]: ' choice
    case "${choice:-1}" in
      1) [[ -n "$active" ]] && print_profile_full "$active" || echo 'Текущий transport не задан'; pause ;;
      2) print_profile_full xhttp || true; pause ;;
      3) print_profile_full raw || true; pause ;;
      4) print_profile_full hysteria || true; pause ;;
      5) print_profile_full combined || true; pause ;;
      6) find "$APP_DIR/remnawave-profiles" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort; pause ;;
      0) return 0 ;;
      *) echo -e "${RED}[ОШИБКА]${NC} Неверный пункт"; sleep 1 ;;
    esac
  done
}

show_status(){
  clear || true
  local node=0 nginx=0 rkn=0 scanner_guard=0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode && node=1 || true
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnawave-nginx && nginx=1 || true
  [[ -x /usr/local/bin/rkn-watcher || -x /opt/rkn-watcher/rkn-watcher.sh ]] && rkn=1 || true
  command -v iptables >/dev/null 2>&1 && iptables -C INPUT -j REMNA_RKN_SCANNERS >/dev/null 2>&1 && scanner_guard=1 || true
  printf '  '; status_badge 'Remnawave node' "$node"; echo
  printf '  '; status_badge 'SelfSteal nginx' "$nginx"; echo
  printf '  '; status_badge 'RKN Watcher' "$rkn"; echo
  printf '  '; status_badge 'RKN scanner guard' "$scanner_guard"; echo
  echo
  printf '  %-22s %s\n' 'Stable base:' "$LEGACY_COMMIT"
  printf '  %-22s %s\n' 'Module commit:' "$MODULE_REF"
  printf '  %-22s %s\n' 'Node domain:' "$(cat "$APP_DIR/.node_domain" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Transport profile:' "$(cat "$APP_DIR/.transport" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Reality SNI:' "$(cat "$APP_DIR/.reality_sni" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'SelfSteal site:' "$(cat "$APP_DIR/.selfsteal_site" 2>/dev/null || echo 'stream (default)')"
  echo; echo -e "${BLUE}[PORTS]${NC}"; ss -lntup 2>/dev/null | grep -E '(:443[[:space:]]|:2222[[:space:]]|:80[[:space:]])' || true; pause
}

menu(){
  while true; do
    clear || true
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        REMNANODE NEXT — STABLE JULY CORE + NEW MODULES          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}  [NODE / СТАБИЛЬНАЯ БАЗА]${NC}"
    echo -e "   ${WHITE}1)${NC} 🚀 Установка и штатное управление нодой"
    echo -e "   ${WHITE}2)${NC} 📊 Сводный статус ноды / портов / модулей"
    echo
    echo -e "${CYAN}  [TRANSPORT / REMNAWAVE]${NC}"
    echo -e "   ${WHITE}3)${NC} ⚡ Создать Config Profile + Host для XHTTP / RAW / Hysteria2 / XHTTP+Hysteria2"
    echo -e "   ${WHITE}4)${NC} 📋 Просмотр и копирование текущих профилей + описание Host"
    echo -e "   ${WHITE}5)${NC} 🧬 XHTTP signature — применить / снять / показать"
    echo
    echo -e "${MAGENTA}  [REALITY / SELFSTEAL]${NC}"
    echo -e "   ${WHITE}6)${NC} 🎭 Показать текущий SNI / target / состояние пула"
    echo -e "   ${WHITE}7)${NC} 🌐 Маскировочный сайт — STREAM / RADIO / старые шаблоны / RANDOM"
    echo
    echo -e "${YELLOW}  [SECURITY]${NC}"
    echo -e "   ${WHITE}8)${NC} 🛡️  RKN Watcher — SAFE scanner guard / status / update / advanced"
    echo
    echo -e "${RED}  [ВЫХОД]${NC}"
    echo -e "   ${WHITE}0)${NC} Закрыть меню"
    echo
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

main(){ preflight || return 1; menu; }
main "$@"
