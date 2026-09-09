#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

MODULE_REF="${REMNANODE_REPO_REF:-4e34ab5f9636c2610cb34165984ba3e31820796f}"
LEGACY_COMMIT="${REMNANODE_LEGACY_COMMIT:-34aeaa99aa1a5c21fc4f9d0c976d38607d025353}"
LEGACY_TEMPLATES_REF="845187fbee8fff72f66d1570af436438e859e40d"
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
  [production/selfsteal-site-manager.sh]="f2006f86dcc3bd2c60e45e540d935fdc57a8a0dca44320bac573b1445ccde2af"
  [production/validate-generated-profile.sh]="df0edf610cd11cc0d311dd59f46fe5c263c535dbfcceeb8af90d9d25d89d0bf6"
  [production/network-tuning-manager.sh]="25ebe8434d96b5b55d248ec709e275913d9a227518b978b8bd0be7f3e0784af9"
  [production/next-runtime-guards.sh]="6832fec731e4bf3b76c5c49e97ee857b1f7aafdf870f0090ab9be58103845dc4"
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
MAGENTA='\033[0;35m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[38;5;244m'; NC='\033[0m'

preflight(){
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then printf '%b\n' "${RED}[ОШИБКА]${NC} Запусти от root"; return 1; fi
  [[ "$MODULE_REF" =~ ^[0-9a-f]{40}$ ]] || { printf '%b\n' "${RED}[ОШИБКА]${NC} MODULE_REF должен быть immutable 40-символьным commit SHA"; return 1; }
  [[ "$LEGACY_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { printf '%b\n' "${RED}[ОШИБКА]${NC} LEGACY_COMMIT должен быть immutable 40-символьным commit SHA"; return 1; }
  [[ "$LEGACY_TEMPLATES_REF" =~ ^[0-9a-f]{40}$ ]] || { printf '%b\n' "${RED}[ОШИБКА]${NC} LEGACY_TEMPLATES_REF должен быть immutable SHA"; return 1; }
  mkdir -p "$WORK_DIR"
}

pause(){ echo; read -r -p 'Нажми Enter для продолжения...' _ || true; }
status_badge(){ local name="$1" ok="$2"; [[ "$ok" == 1 ]] && printf '%b' "${GREEN}[ON]${NC} $name" || printf '%b' "${GRAY}[OFF]${NC} $name"; }

fetch_url(){
  local url="$1" dst="$2" label="$3" want="${4:-}" got tmp
  tmp="${dst}.part"
  rm -f "$tmp"
  if ! curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 45 "$url" -o "$tmp"; then
    rm -f "$tmp"; printf '%b\n' "${RED}[ОШИБКА]${NC} Не удалось скачать: $url"; return 1
  fi
  if [[ -n "$want" ]]; then
    got="$(sha256sum "$tmp" | cut -d' ' -f1)"
    [[ "$got" == "$want" ]] || { rm -f "$tmp"; printf '%b\n' "${RED}[ОШИБКА]${NC} SHA256 не совпал для $label"; return 1; }
  fi
  bash -n "$tmp" || { rm -f "$tmp"; printf '%b\n' "${RED}[ОШИБКА]${NC} Синтаксис не прошёл проверку: $label"; return 1; }
  chmod 0755 "$tmp"; mv -f "$tmp" "$dst"
}

fetch_module(){
  local rel="$1" dst="$2" want="${MODULE_SHA256[$1]:-}"
  [[ -n "$want" ]] || { echo "[ОШИБКА] Нет SHA256 для $rel"; return 1; }
  fetch_url "${MODULE_RAW}/${rel}" "$dst" "$rel@${MODULE_REF}" "$want"
}

ensure_python3_for_patch(){
  command -v python3 >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 || { echo -e "${RED}[ОШИБКА]${NC} Для runtime guards нужен python3"; return 1; }
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y && apt-get install -y python3
}

runtime_guard_file(){
  local f="$WORK_DIR/next-runtime-guards.sh"
  fetch_module production/next-runtime-guards.sh "$f" || return 1
  printf '%s' "$f"
}

run_runtime_guard(){
  local f
  f="$(runtime_guard_file)" || return 1
  APP_DIR="$APP_DIR" bash "$f" "$@"
}

prepare_selfsteal_manager(){
  local f="$WORK_DIR/selfsteal-site-manager.sh" g
  ensure_python3_for_patch >&2 || return 1
  fetch_module production/selfsteal-site-manager.sh "$f" || return 1
  g="$(runtime_guard_file)" || return 1
  APP_DIR="$APP_DIR" bash "$g" patch-selfsteal "$f" >&2 || return 1
  printf '%s' "$f"
}

prepare_rkn_manager(){
  local f="$WORK_DIR/rkn-watcher-manager.sh" g
  ensure_python3_for_patch >&2 || return 1
  fetch_module production/rkn-watcher-manager.sh "$f" || return 1
  g="$(runtime_guard_file)" || return 1
  APP_DIR="$APP_DIR" bash "$g" patch-rkn "$f" >&2 || return 1
  printf '%s' "$f"
}

run_selfsteal_default(){
  local f
  f="$(prepare_selfsteal_manager)" || return 1
  if [[ -s "$APP_DIR/.selfsteal_site" ]]; then
    APP_DIR="$APP_DIR" bash "$f" ensure
  else
    APP_DIR="$APP_DIR" bash "$f" random
  fi
}

run_selfsteal_site(){
  local f
  f="$(prepare_selfsteal_manager)" || return 1
  APP_DIR="$APP_DIR" bash "$f" choose
}

rkn_guard_active(){
  [[ -s "$APP_DIR/rkn-safe/.scanner-guard-active" ]] \
    && command -v iptables >/dev/null 2>&1 \
    && iptables -C INPUT -j REMNA_RKN_SCANNERS >/dev/null 2>&1
}

sync_rkn_watch(){ run_runtime_guard sync-rkn-watch; }
restore_rkn_guard(){ run_runtime_guard restore-rkn; }
restore_hysteria_mount(){ run_runtime_guard restore-hysteria; }

run_rkn_default(){
  local f
  if [[ -s "$APP_DIR/rkn-safe/.scanner-guard-active" ]]; then
    restore_rkn_guard || return 1
    sync_rkn_watch || return 1
    echo -e "${GREEN}[RKN]${NC} SAFE scanner guard уже активен; переустановку пропускаю."
    return 0
  fi
  f="$(prepare_rkn_manager)" || return 1
  echo -e "${GREEN}[RKN]${NC} Ставлю SAFE scanner protection с sanity-check и last-good rollback."
  APP_DIR="$APP_DIR" bash "$f" install-safe || return 1
  sync_rkn_watch
}

prepare_legacy_for_next(){
  local f tmp
  f="$1"
  tmp="${f}.next"
  rm -f "$tmp"
  if ! awk -v tref="$LEGACY_TEMPLATES_REF" '
    BEGIN { skip_proto=0; proto_done=0; decoy_done=0; pin_url=0; pin_root=0 }
    /# Выбор протокола шифрования/ {
      print "    # NEXT: July base always installs Reality/SelfSteal; modern transports are generated later."
      print "    log \"${INFO} NEXT: базовая схема Reality/SelfSteal; XHTTP/RAW/Hysteria2 настраиваются отдельно.\""
      print "    local protocol=\"reality\""; skip_proto=1; proto_done=1; next
    }
    skip_proto && /# Скачивание и генерация маскировочного сайта SelfSteal/ { skip_proto=0; print; next }
    skip_proto { next }
    /read -p \"Домен маскировки \(decoy domain\) \[github\.com\]: \" decoy_domain/ {
      print "        decoy_domain=github.com"; decoy_done=1; next
    }
    /local templates_url="https:\/\/github\.com\/Mrvibecodic\/node-templates\/archive\/refs\/heads\/main\.zip"/ {
      sub(/refs\/heads\/main\.zip/, tref ".zip"); pin_url=1; print; next
    }
    /local repo_root="\$temp_unzip\/node-templates-main"/ {
      sub(/node-templates-main/, "node-templates-" tref); pin_root=1; print; next
    }
    { print }
    END { if (!proto_done || !decoy_done || !pin_url || !pin_root) exit 42 }
  ' "$f" > "$tmp"; then
    rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Не удалось безопасно адаптировать July base"; return 1
  fi
  if grep -Fq 'read -p "Ваш выбор [1]: " proto_choice' "$tmp" \
     || grep -Fq 'read -p "Домен маскировки (decoy domain) [github.com]: " decoy_domain' "$tmp" \
     || grep -Fq 'node-templates/archive/refs/heads/main.zip' "$tmp"; then
    rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} В адаптированном legacy остались mutable/prompt маркеры"; return 1
  fi
  grep -Fq "node-templates-${LEGACY_TEMPLATES_REF}" "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Legacy template repo root не закреплён"; return 1; }
  bash -n "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Адаптированный July base не прошёл bash -n"; return 1; }
  chmod 0755 "$tmp"; mv -f "$tmp" "$f"
  echo -e "${GREEN}[NEXT]${NC} July base: Reality/SelfSteal + pinned node-templates@$LEGACY_TEMPLATES_REF"
}

compose_fingerprint(){
  local compose="$APP_DIR/docker-compose.yml"
  [[ -f "$compose" ]] || { printf 'MISSING'; return 0; }
  sha256sum "$compose" | cut -d' ' -f1
}

cleanup_rkn_watch_after_uninstall(){
  systemctl disable --now remnanode-rkn-scanner-health.timer remnanode-rkn-scanner-ufw.path >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/remnanode-rkn-scanner-health.service \
        /etc/systemd/system/remnanode-rkn-scanner-health.timer \
        /etc/systemd/system/remnanode-rkn-scanner-ufw.path
  systemctl daemon-reload >/dev/null 2>&1 || true
}

run_legacy(){
  local f="$WORK_DIR/setup_node-legacy.sh" rc before after
  echo -e "${GREEN}[STABLE 07.07]${NC} Запускаю зафиксированную рабочую базу."
  fetch_url "${LEGACY_RAW}/setup_node.sh" "$f" "setup_node.sh@${LEGACY_COMMIT}" "$LEGACY_SHA256" || return 1
  prepare_legacy_for_next "$f" || return 1
  before="$(compose_fingerprint)"
  if bash "$f"; then :; else rc=$?; return "$rc"; fi
  after="$(compose_fingerprint)"

  if [[ "$after" == MISSING ]]; then
    echo -e "${GRAY}[NEXT] Нода отсутствует/удалена — никакой постобработки не выполняю.${NC}"
    cleanup_rkn_watch_after_uninstall
    return 0
  fi

  restore_rkn_guard || echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} Scanner guard восстановить не удалось."
  sync_rkn_watch || echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} RKN self-heal unit не синхронизирован."

  if [[ "$before" == "$after" ]]; then
    echo -e "${GRAY}[NEXT] docker-compose.yml не менялся — SelfSteal/transport/network не трогаю.${NC}"
    return 0
  fi

  echo -e "${GREEN}[NEXT]${NC} Compose изменён: выполняю только безопасную постобработку."
  if [[ -d /var/www/html ]]; then
    run_selfsteal_default || echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} SelfSteal не обновлён; текущий webroot оставлен как есть."
  fi
  restore_hysteria_mount || echo -e "${RED}[ОШИБКА]${NC} Cert bind Hysteria2 НЕ восстановлен — не применяй Hysteria2 профиль до исправления."
  run_rkn_default || echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} SAFE scanner protection не удалось активировать."
  echo -e "${GRAY}[NETWORK] Автоматический NEXT tuning отключён: сохраняю проверенный July sysctl baseline без понижения лимитов.${NC}"
}

run_transport(){
  local f="$WORK_DIR/remnawave-transport-manager.sh" xhttp_sig="$WORK_DIR/xhttp-signature-manager.sh" sig_ok='' minver=''
  fetch_module production/remnawave-transport-manager.sh "$f" || return 1
  echo
  echo -e "${YELLOW}[REALITY]${NC} Xray по умолчанию может требовать client >= 26.3.27."
  echo -e "${GRAY}Пустое значение оставляет дефолт Xray. Указывай другое только если осознанно нужна совместимость со старыми клиентами.${NC}"
  read -r -p 'minClientVer (пусто = дефолт Xray): ' minver || true
  APP_DIR="$APP_DIR" XHTTP_SIGNATURE_MODE=none REALITY_MIN_CLIENT_VER="$minver" bash "$f" || return 1

  if [[ "$(cat "$APP_DIR/.transport" 2>/dev/null || true)" == xhttp ]]; then
    fetch_module production/xhttp-signature-manager.sh "$xhttp_sig" || return 1
    echo; echo -e "${YELLOW}[ВНИМАНИЕ]${NC} XHTTP signature пока opt-in."
    read -r -p 'Применить signature сейчас? Введите SIGN (пусто = пропустить): ' sig_ok || true
    if [[ "$sig_ok" == SIGN ]]; then
      if APP_DIR="$APP_DIR" bash "$xhttp_sig" apply; then
        echo -e "${GREEN}[OK]${NC} XHTTP signature применена."
      else
        echo -e "${RED}[ОШИБКА]${NC} Signature применить не удалось; профиль оставлен без неё."
        return 1
      fi
    else
      echo -e "${GREEN}[OK]${NC} XHTTP оставлен без signature."
    fi
  fi
}

run_xhttp_signature(){
  local f="$WORK_DIR/xhttp-signature-manager.sh" choice=''
  fetch_module production/xhttp-signature-manager.sh "$f" || return 1
  echo '  1) Применить сохранённую signature + Host extra'
  echo '  2) Снять signature с профиля'
  echo '  3) Показать signature'
  echo '  0) Назад'
  read -r -p 'Выбор [0]: ' choice || true
  case "${choice:-0}" in
    1) APP_DIR="$APP_DIR" bash "$f" apply ;;
    2) APP_DIR="$APP_DIR" bash "$f" revert ;;
    3) APP_DIR="$APP_DIR" bash "$f" show ;;
    0) return 0 ;;
    *) echo -e "${RED}[ОШИБКА]${NC} Неверный пункт"; return 1 ;;
  esac
}

run_rkn(){
  local f rc=0
  f="$(prepare_rkn_manager)" || return 1
  APP_DIR="$APP_DIR" bash "$f" menu || rc=$?
  sync_rkn_watch || true
  return "$rc"
}

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
  local transport="$1" profile host host2='' remark mtime
  local -a first=()
  mapfile -t first < <(profile_paths "$transport") || { echo -e "${RED}[ОШИБКА]${NC} Неизвестный transport: $transport"; return 1; }
  profile="${first[0]:-}"; host="${first[1]:-}"; host2="${first[2]:-}"
  [[ -s "$profile" ]] || { echo -e "${YELLOW}[НЕТ]${NC} Профиль ещё не создан: $profile"; return 1; }
  remark="$(sed -n 's/^Remark:[[:space:]]*//p' "$host" 2>/dev/null | head -1)"
  mtime="$(stat -c '%y' "$profile" 2>/dev/null || echo '-')"
  echo '#################### НАЧАЛО ВЫВОДА: REMNAWAVE PROFILE COPY ####################'
  echo "TRANSPORT: $transport"
  echo "PROFILE FILE: $profile"
  echo "UPDATED: $mtime"
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
    read -r -p 'Выбор [1]: ' choice || true
    case "${choice:-1}" in
      1)
        if [[ -n "$active" ]]; then
          print_profile_full "$active" || echo 'Текущий transport задан, но его профиль отсутствует/повреждён.'
        else
          echo 'Текущий transport не задан'
        fi
        pause
        ;;
      2) print_profile_full xhttp || true; pause ;;
      3) print_profile_full raw || true; pause ;;
      4) print_profile_full hysteria || true; pause ;;
      5) print_profile_full combined || true; pause ;;
      6) find "$APP_DIR/remnawave-profiles" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM  %f\n' 2>/dev/null | sort; pause ;;
      0) return 0 ;;
      *) echo -e "${RED}[ОШИБКА]${NC} Неверный пункт"; sleep 1 ;;
    esac
  done
}

show_status(){
  clear || true
  local node=0 nginx=0 rkn=0 scanner_guard=0 scanner_state=0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode && node=1 || true
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnawave-nginx && nginx=1 || true
  [[ -x /usr/local/bin/rkn-watcher || -x /opt/rkn-watcher/rkn-watcher.sh ]] && rkn=1 || true
  [[ -s "$APP_DIR/rkn-safe/.scanner-guard-active" ]] && scanner_state=1 || true
  command -v iptables >/dev/null 2>&1 && iptables -C INPUT -j REMNA_RKN_SCANNERS >/dev/null 2>&1 && scanner_guard=1 || true
  printf '  '; status_badge 'Remnawave node' "$node"; echo
  printf '  '; status_badge 'SelfSteal nginx' "$nginx"; echo
  printf '  '; status_badge 'RKN Watcher' "$rkn"; echo
  printf '  '; status_badge 'RKN scanner guard' "$scanner_guard"; echo
  if (( scanner_state == 1 && scanner_guard == 0 )); then echo -e "  ${RED}[РАСХОЖДЕНИЕ] state=active, но INPUT jump отсутствует${NC}"; fi
  echo
  printf '  %-22s %s\n' 'Stable base:' "$LEGACY_COMMIT"
  printf '  %-22s %s\n' 'Module commit:' "$MODULE_REF"
  printf '  %-22s %s\n' 'Node domain:' "$(cat "$APP_DIR/.node_domain" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Transport profile:' "$(cat "$APP_DIR/.transport" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Reality SNI:' "$(cat "$APP_DIR/.reality_sni" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'SelfSteal site:' "$(cat "$APP_DIR/.selfsteal_site" 2>/dev/null || echo 'random (default)')"
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
    read -r -p 'Выбери действие [0-8]: ' choice || true
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
