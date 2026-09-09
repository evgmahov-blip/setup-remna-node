#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

MODULE_REF="${REMNANODE_REPO_REF:-31cd59665b90fa631caf837dc473b5bdb249aeeb}"
LEGACY_COMMIT="${REMNANODE_LEGACY_COMMIT:-34aeaa99aa1a5c21fc4f9d0c976d38607d025353}"
LEGACY_TEMPLATES_REF="845187fbee8fff72f66d1570af436438e859e40d"
RKN_UPDATE_LOCK_MAX_MINUTES="${RKN_UPDATE_LOCK_MAX_MINUTES:-30}"
REPO="evgmahov-blip/setup-remna-node"
MODULE_RAW="https://raw.githubusercontent.com/${REPO}/${MODULE_REF}"
LEGACY_RAW="https://raw.githubusercontent.com/${REPO}/${LEGACY_COMMIT}"
WORK_DIR="${WORK_DIR:-/opt/remnanode/next-installer}"
APP_DIR="${APP_DIR:-/opt/remnanode}"
NEXT_INSTALL_DIR="${NEXT_INSTALL_DIR:-/usr/local/lib/remnanode-next}"
NEXT_INSTALLED_SCRIPT="$NEXT_INSTALL_DIR/setup_node_next.sh"
NEXT_GLOBAL_COMMAND="/usr/local/bin/remnanode-next"
LEGACY_SHA256="aa79bc94916d41770b18dbad2ca0890123fc64cd5ce397841ca9f92e05dc67bf"

declare -A MODULE_SHA256=(
  [production/remnawave-transport-manager.sh]="441c82fb0eb3b155986d7b84bd66aa82bb1d028b8a9c49e02f1fbac326fac2e2"
  [production/xhttp-signature-manager.sh]="dbbd1110aec2e6dd32aee204b6d0174d7fe511e1b97118570cbbea553946bd4a"
  [production/rkn-watcher-manager.sh]="286a1b9979811dec1f265d5c6beb8a26cb52ebced2583e93276e13879412a92a"
  [production/selfsteal-site-manager.sh]="633200763bf9fdad85c87368449675d855a32c52d5607abb54714640a33f8a1e"
  [production/validate-generated-profile.sh]="df0edf610cd11cc0d311dd59f46fe5c263c535dbfcceeb8af90d9d25d89d0bf6"
  [production/network-tuning-manager.sh]="320a21fe345e541905c1fbac326fac2e2"
  [production/next-runtime-guards.sh]="b7e63f45eb8ce8ec87cf7c49089f9e69553bc23309fdd9a60fa85c28f0499328"
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
MAGENTA='\033[0;35m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[38;5;244m'; NC='\033[0m'

remove_legacy_global_command(){
  if [[ -e /usr/local/bin/remnanode || -L /usr/local/bin/remnanode ]]; then
    rm -f /usr/local/bin/remnanode
    echo -e "${YELLOW}[NEXT]${NC} Удалена legacy-команда /usr/local/bin/remnanode: она обходила NEXT post-processing."
  fi
}

register_next_global_command(){
  local src="" launcher_tmp=""
  src="$(readlink -f -- "$0" 2>/dev/null || true)"
  if [[ -z "$src" || ! -f "$src" ]]; then
    echo -e "${YELLOW}[NEXT]${NC} remnanode-next не зарегистрирован: текущий NEXT запущен не из обычного файла."
    return 0
  fi
  install -d -m 0755 "$NEXT_INSTALL_DIR"
  if [[ "$src" != "$NEXT_INSTALLED_SCRIPT" ]]; then
    install -m 0755 "$src" "$NEXT_INSTALLED_SCRIPT"
  else
    chmod 0755 "$NEXT_INSTALLED_SCRIPT"
  fi
  launcher_tmp="$(mktemp /usr/local/bin/.remnanode-next.XXXXXX)"
  cat > "$launcher_tmp" <<EOF_LAUNCHER
#!/usr/bin/env bash
set -Eeuo pipefail
bash "$NEXT_INSTALLED_SCRIPT" "\$@"
EOF_LAUNCHER
  chmod 0755 "$launcher_tmp"
  mv -f "$launcher_tmp" "$NEXT_GLOBAL_COMMAND"
  echo -e "${GREEN}[NEXT]${NC} Безопасная команда управления: ${WHITE}remnanode-next${NC}"
}

derive_node_name(){
  local d="" label="" region="" num="" n="${REMNANODE_NODE_NAME:-}"
  if [[ -n "$n" ]]; then
    n="$(printf '%s' "$n" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
    [[ -n "$n" ]] || { echo '[ОШИБКА] REMNANODE_NODE_NAME некорректен' >&2; return 1; }
    printf '%s' "$n"
    return 0
  fi
  [[ -s "$APP_DIR/.node_domain" ]] || { echo '[ОШИБКА] Не найден .node_domain для имени inbound' >&2; return 1; }
  d="$(tr -d '[:space:]' < "$APP_DIR/.node_domain")"
  label="${d%%.*}"
  if [[ "$label" =~ ^([A-Za-z]+)[_-]?([0-9]+)$ ]]; then
    region="${BASH_REMATCH[1]^^}"
    num="${BASH_REMATCH[2]}"
    printf '%s-node%s' "$region" "$num"
    return 0
  fi
  if [[ -s "$APP_DIR/.node_name" ]]; then
    n="$(head -n1 "$APP_DIR/.node_name" | tr -d '\r\n')"
    n="$(printf '%s' "$n" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
    [[ -n "$n" ]] && { printf '%s' "$n"; return 0; }
  fi
  label="$(printf '%s' "$label" | sed -E 's/[^A-Za-z0-9_-]+/-/g; s/^-+//; s/-+$//')"
  [[ -n "$label" ]] || { echo '[ОШИБКА] Не удалось вычислить имя inbound из домена' >&2; return 1; }
  printf '%s' "$label"
}

preflight(){
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then printf '%b\n' "${RED}[ОШИБКА]${NC} Запусти от root"; return 1; fi
  [[ "$MODULE_REF" =~ ^[0-9a-f]{40}$ ]] || { printf '%b\n' "${RED}[ОШИБКА]${NC} MODULE_REF должен быть immutable 40-символьным commit SHA"; return 1; }
  [[ "$LEGACY_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { printf '%b\n' "${RED}[ОШИБКА]${NC} LEGACY_COMMIT должен быть immutable 40-символьным commit SHA"; return 1; }
  [[ "$LEGACY_TEMPLATES_REF" =~ ^[0-9a-f]{40}$ ]] || { printf '%b\n' "${RED}[ОШИБКА]${NC} LEGACY_TEMPLATES_REF должен быть immutable SHA"; return 1; }
  [[ "$RKN_UPDATE_LOCK_MAX_MINUTES" =~ ^[0-9]+$ ]] && (( RKN_UPDATE_LOCK_MAX_MINUTES >= 1 )) || { printf '%b\n' "${RED}[ОШИБКА]${NC} RKN_UPDATE_LOCK_MAX_MINUTES должен быть целым числом >= 1"; return 1; }
  mkdir -p "$WORK_DIR"
  remove_legacy_global_command
  register_next_global_command
}

pause(){ echo; read -r -p 'Нажми Enter для продолжения...' _ || true; }
status_badge(){ local name="$1" ok="$2"; [[ "$ok" == 1 ]] && printf '%b' "${GREEN}[ON]${NC} $name" || printf '%b' "${GRAY}[OFF]${NC} $name"; }

fetch_url(){
  local url="$1" dst="$2" label="$3" want="${4:-}" got tmp
  tmp="${dst}.part"
  rm -f "$tmp"
  if ! curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 45 "$url" -o "$tmp"; then
    rm -f "$tmp"; printf '%b\n' "${RED}[ОШИБКА]${NC} Не удалось скачать: $url" >&2; return 1
  fi
  if [[ -n "$want" ]]; then
    got="$(sha256sum "$tmp" | cut -d' ' -f1)"
    [[ "$got" == "$want" ]] || { rm -f "$tmp"; printf '%b\n' "${RED}[ОШИБКА]${NC} SHA256 не совпал для $label" >&2; return 1; }
  fi
  bash -n "$tmp" || { rm -f "$tmp"; printf '%b\n' "${RED}[ОШИБКА]${NC} Синтаксис не прошёл проверку: $label" >&2; return 1; }
  chmod 0755 "$tmp"; mv -f "$tmp" "$dst"
}

fetch_module(){
  local rel="$1" dst="$2" want="${MODULE_SHA256[$1]:-}"
  [[ -n "$want" ]] || { echo "[ОШИБКА] Нет SHA256 для $rel" >&2; return 1; }
  fetch_url "${MODULE_RAW}/${rel}" "$dst" "$rel@${MODULE_REF}" "$want"
}

ensure_python3_for_patch(){
  command -v python3 >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 || { echo -e "${RED}[ОШИБКА]${NC} Для runtime guards нужен python3" >&2; return 1; }
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
  APP_DIR="$APP_DIR" RKN_UPDATE_LOCK_MAX_MINUTES="$RKN_UPDATE_LOCK_MAX_MINUTES" bash "$f" "$@"
}

prepare_selfsteal_manager(){
  local f="$WORK_DIR/selfsteal-site-manager.sh"
  fetch_module production/selfsteal-site-manager.sh "$f" || return 1
  printf '%s' "$f"
}

prepare_rkn_manager(){
  local f="$WORK_DIR/rkn-watcher-manager.sh" g
  ensure_python3_for_patch >&2 || return 1
  fetch_module production/rkn-watcher-manager.sh "$f" || return 1
  g="$(runtime_guard_file)" || return 1
  APP_DIR="$APP_DIR" RKN_UPDATE_LOCK_MAX_MINUTES="$RKN_UPDATE_LOCK_MAX_MINUTES" bash "$g" patch-rkn "$f" >&2 || return 1
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

rkn_update_lock_state(){
  local lock="$APP_DIR/rkn-safe/.safe-update-running" now mtime max_age age
  [[ -e "$lock" ]] || { printf 'none'; return 0; }
  now="$(date +%s 2>/dev/null || true)"
  mtime="$(stat -c %Y -- "$lock" 2>/dev/null || true)"
  if [[ ! "$now" =~ ^[0-9]+$ || ! "$mtime" =~ ^[0-9]+$ ]]; then
    printf 'stale'
    return 0
  fi
  max_age=$(( RKN_UPDATE_LOCK_MAX_MINUTES * 60 ))
  age=$(( now - mtime ))
  if (( mtime > now || age > max_age )); then printf 'stale'; else printf 'active'; fi
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
  if ! awk -v tref="$LEGACY_TEMPLATES_REF" -v lcommit="$LEGACY_COMMIT" '
    BEGIN { skip_proto=0; proto_done=0; decoy_done=0; pin_url=0; pin_root=0; reg_done=0; pin_telemt=0; telemt_label=0; telemt_menu=0; uninstall_marker=0 }
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
    /base_url="https:\/\/raw\.githubusercontent\.com\/evgmahov-blip\/setup-remna-node\/custom\/vendor\/telemt-install"/ {
      sub(/\/custom\//, "/" lcommit "/"); pin_telemt=1; print; next
    }
    /echo " 11\) ✈️  Установка и управление Telemt \/ MTProto"/ {
      print "        echo \" 11) ⛔ Telemt / MTProto отключён в NEXT (конфликт host nginx stream/ssl_preread с Xray :443)\""; telemt_label=1; next
    }
    /^[[:space:]]*log "\$\{INFO\} Остановка контейнеров Docker\.\.\."$/ {
      print "    printf \"uninstall\\n\" > \"${NEXT_ACTION_FILE:-/tmp/remnanode-next-legacy-action}\""
      print; uninstall_marker=1; next
    }
    /^[[:space:]]*11\) run_telemt_installer ;;/ {
      print "            11) log \"${WARNING} Telemt отключён в NEXT: его site-stub ставит host nginx stream/ssl_preread на public 443 и конфликтует с Xray.\"; pause_prompt ;;"; telemt_menu=1; next
    }
    /^    register_globally$/ {
      print "    : # NEXT: bypass-команда remnanode не регистрируется; post-processing живёт в NEXT"
      reg_done=1; next
    }
    { print }
    END { if (!proto_done || !decoy_done || !pin_url || !pin_root || !reg_done || !pin_telemt || !telemt_label || !telemt_menu || !uninstall_marker) exit 42 }
  ' "$f" > "$tmp"; then
    rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Не удалось безопасно адаптировать July base"; return 1
  fi
  if grep -Fq 'read -p "Ваш выбор [1]: " proto_choice' "$tmp" \
     || grep -Fq 'read -p "Домен маскировки (decoy domain) [github.com]: " decoy_domain' "$tmp" \
     || grep -Fq 'node-templates/archive/refs/heads/main.zip' "$tmp" \
     || grep -Fq 'setup-remna-node/custom/vendor/telemt-install' "$tmp" \
     || grep -Eq '^[[:space:]]*11\) run_telemt_installer ;;' "$tmp" \
     || grep -q '^    register_globally$' "$tmp"; then
    rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} В адаптированном legacy остались mutable/bypass/unsafe Telemt/prompt маркеры"; return 1
  fi
  grep -Fq "node-templates-${LEGACY_TEMPLATES_REF}" "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Legacy template repo root не закреплён"; return 1; }
  grep -Fq "setup-remna-node/${LEGACY_COMMIT}/vendor/telemt-install" "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Telemt legacy source не закреплён"; return 1; }
  grep -Fq 'Telemt отключён в NEXT' "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Telemt safety gate не применён"; return 1; }
  grep -Fq 'NEXT_ACTION_FILE' "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Legacy uninstall marker не применён"; return 1; }
  bash -n "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Адаптированный July base не прошёл bash -n"; return 1; }
  chmod 0755 "$tmp"; mv -f "$tmp" "$f"
  echo -e "${GREEN}[NEXT]${NC} July base: Reality/SelfSteal + pinned templates; Telemt отключён из-за конфликта public 443; bypass remnanode отключён"
}

compose_fingerprint(){
  local compose="$APP_DIR/docker-compose.yml"
  [[ -f "$compose" ]] || { printf 'MISSING'; return 0; }
  sha256sum "$compose" | cut -d' ' -f1
}

cleanup_rkn_watch_after_uninstall(){
  systemctl disable --now \
    remnanode-rkn-scanner-health.timer \
    remnanode-rkn-scanner-ufw.path \
    remnanode-rkn-scanner-update.timer \
    remnanode-rkn-scanner-boot.service >/dev/null 2>&1 || true
  systemctl stop remnanode-rkn-scanner-health.service remnanode-rkn-scanner-update.service remnanode-rkn-scanner-rollback.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/remnanode-rkn-scanner-health.service \
        /etc/systemd/system/remnanode-rkn-scanner-health.timer \
        /etc/systemd/system/remnanode-rkn-scanner-ufw.path \
        /etc/systemd/system/remnanode-rkn-scanner-boot.service \
        /etc/systemd/system/remnanode-rkn-scanner-update.service \
        /etc/systemd/system/remnanode-rkn-scanner-update.timer \
        "$APP_DIR/rkn-safe/health-check.sh"
  rm -f "$APP_DIR/rkn-safe/.scanner-guard-active" "$APP_DIR/rkn-safe/.safe-update-running"
  if command -v iptables >/dev/null 2>&1; then
    while iptables -C INPUT -j REMNA_RKN_SCANNERS >/dev/null 2>&1; do
      iptables -D INPUT -j REMNA_RKN_SCANNERS >/dev/null 2>&1 || break
    done
    iptables -F REMNA_RKN_SCANNERS >/dev/null 2>&1 || true
    iptables -X REMNA_RKN_SCANNERS >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  remove_legacy_global_command
}

run_legacy(){
  local f="$WORK_DIR/setup_node-legacy.sh" rc=0 before after action_file action=''
  echo -e "${GREEN}[STABLE 07.07]${NC} Запускаю зафиксированную рабочую базу."
  fetch_url "${LEGACY_RAW}/setup_node.sh" "$f" "setup_node.sh@${LEGACY_COMMIT}" "$LEGACY_SHA256" || return 1
  prepare_legacy_for_next "$f" || return 1
  remove_legacy_global_command
  action_file="$WORK_DIR/.legacy-action"
  rm -f "$action_file"
  before="$(compose_fingerprint)"
  if NEXT_ACTION_FILE="$action_file" bash "$f"; then
    :
  else
    rc=$?
  fi
  remove_legacy_global_command
  after="$(compose_fingerprint)"
  action="$(cat "$action_file" 2>/dev/null || true)"
  rm -f "$action_file"

  if [[ "$action" == uninstall ]]; then
    cleanup_rkn_watch_after_uninstall
    if [[ "$after" == MISSING ]]; then
      echo -e "${GRAY}[NEXT] Нода удалена; RKN/self-heal cleanup выполнен.${NC}"
    else
      echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} Legacy uninstall завершился не полностью; RKN self-heal/chain сняты, оставшиеся файлы ноды не восстанавливаю."
    fi
    return "$rc"
  fi

  if [[ "$after" == MISSING ]]; then
    echo -e "${GRAY}[NEXT] Нода отсутствует/удалена — выполняю только cleanup защитных юнитов.${NC}"
    cleanup_rkn_watch_after_uninstall
    return "$rc"
  fi

  restore_rkn_guard || echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} Scanner guard восстановить не удалось."
  sync_rkn_watch || echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} RKN self-heal unit не синхронизирован."
  restore_hysteria_mount || echo -e "${RED}[ОШИБКА]${NC} Cert bind Hysteria2 НЕ восстановлен — не применяй Hysteria2 профиль до исправления."

  if (( rc != 0 )); then
    echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} July base завершился с кодом $rc; восстановительные проверки выполнены, тяжёлую постобработку пропускаю."
    return "$rc"
  fi

  if [[ "$before" == "$after" ]]; then
    echo -e "${GRAY}[NEXT] docker-compose.yml не менялся — SelfSteal/transport/network не трогаю; Hysteria/RKN уже проверены.${NC}"
    return 0
  fi

  echo -e "${GREEN}[NEXT]${NC} Compose изменён: выполняю только безопасную тяжёлую постобработку."
  if [[ -d /var/www/html ]]; then
    run_selfsteal_default || echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} SelfSteal не обновлён; текущий webroot оставлен как есть."
  fi
  run_rkn_default || echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} SAFE scanner protection не удалось активировать."
  echo -e "${GRAY}[NETWORK] Автоматический NEXT tuning отключён: сохраняю проверенный July sysctl baseline без понижения лимитов.${NC}"
}

run_transport(){
  local f="$WORK_DIR/remnawave-transport-manager.sh" xhttp_sig="$WORK_DIR/xhttp-signature-manager.sh" sig_ok='' minver='' node_name=''
  fetch_module production/remnawave-transport-manager.sh "$f" || return 1
  node_name="$(derive_node_name)" || return 1
  echo -e "${GREEN}[INBOUND]${NC} Базовое имя: ${WHITE}${node_name}${NC} → ${node_name}-xHTTP / ${node_name}-RAW / ${node_name}-Hysteria2"
  echo
  echo -e "${YELLOW}[REALITY]${NC} Пустой minClientVer оставляет дефолт Xray >= 26.3.27; старые клиенты могут быть отклонены."
  read -r -p 'minClientVer (пусто = дефолт Xray): ' minver || true
  if [[ -n "$minver" && ! "$minver" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
    echo -e "${RED}[ОШИБКА]${NC} minClientVer: допустим формат N, N.N или N.N.N"
    return 1
  fi
  APP_DIR="$APP_DIR" NODE_NAME="$node_name" XHTTP_SIGNATURE_MODE=none REALITY_MIN_CLIENT_VER="$minver" bash "$f" || return 1

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

rkn_selftest(){
  local guard="$APP_DIR/rkn-safe/scanner-guard.sh" failed=0 lock_state
  echo '#################### НАЧАЛО ВЫВОДА: RKN WATCHER SELFTEST ####################'
  [[ -x "$guard" ]] || { echo '[FAIL] scanner-guard.sh отсутствует'; failed=1; }
  if [[ -x "$guard" ]]; then "$guard" validate && echo '[OK] TSPUIPS sanity-check' || { echo '[FAIL] TSPUIPS sanity-check'; failed=1; }; fi
  if command -v iptables >/dev/null 2>&1 && iptables -C INPUT -j REMNA_RKN_SCANNERS >/dev/null 2>&1; then echo '[OK] INPUT -> REMNA_RKN_SCANNERS'; else echo '[FAIL] INPUT jump отсутствует'; failed=1; fi
  systemctl is-enabled remnanode-rkn-scanner-boot.service >/dev/null 2>&1 && echo '[OK] boot restore enabled' || { echo '[FAIL] boot restore disabled'; failed=1; }
  systemctl is-enabled remnanode-rkn-scanner-update.timer >/dev/null 2>&1 && echo '[OK] daily update timer enabled' || { echo '[FAIL] daily update timer disabled'; failed=1; }
  lock_state="$(rkn_update_lock_state)"
  case "$lock_state" in
    none) echo '[OK] SAFE update lock отсутствует' ;;
    active) echo '[INFO] SAFE update lock активен и свежий' ;;
    stale) echo '[FAIL] SAFE update lock протух; self-heal должен удалить его при следующей проверке'; failed=1 ;;
  esac
  echo '#################### КОНЕЦ ВЫВОДА: RKN WATCHER SELFTEST ####################'
  return "$failed"
}

run_rkn(){
  local f choice rc=0 guard="$APP_DIR/rkn-safe/scanner-guard.sh"
  f="$(prepare_rkn_manager)" || return 1
  while true; do
    clear || true
    echo '========================================================'
    echo ' RKN WATCHER / TSPU SCANNER GUARD'
    echo '========================================================'
    echo ' 1) Полная проверка состояния / SELFTEST'
    echo ' 2) Показать весь текущий список TSPUIPS'
    echo ' 3) Принудительно обновить scanner list SAFE updater-ом'
    echo ' 4) Активировать / пере-применить guard с rollback 120 сек'
    echo ' 5) Показать правила и счётчики DROP'
    echo ' 6) Показать исключения / Allow-list'
    echo ' 7) Статус boot restore и daily timer'
    echo ' 8) Логи RKN Watcher / обновления / self-heal'
    echo ' 9) Установить / обновить RKN Watcher SAFE'
    echo '10) ADVANCED upstream menu (ночной SAFE updater вернёт безопасные настройки)'
    echo '11) Полностью удалить RKN Watcher'
    echo ' 0) Назад'
    read -r -p 'Выбор [0]: ' choice || true
    case "${choice:-0}" in
      1) rkn_selftest || true; pause ;;
      2) ipset list TSPUIPS 2>&1 || echo '[НЕТ] TSPUIPS отсутствует'; pause ;;
      3)
        if systemctl cat remnanode-rkn-scanner-update.service >/dev/null 2>&1; then
          if systemctl start remnanode-rkn-scanner-update.service; then echo '[OK] SAFE update выполнен'; else echo '[FAIL] SAFE update завершился ошибкой'; fi
          restore_rkn_guard || true; sync_rkn_watch || true
        else
          echo '[НЕТ] SAFE updater не установлен. Сначала пункт 9.'
        fi
        pause
        ;;
      4) APP_DIR="$APP_DIR" bash "$f" activate || true; sync_rkn_watch || true; pause ;;
      5) iptables -L INPUT -n -v --line-numbers 2>&1 | head -20; echo; iptables -L REMNA_RKN_SCANNERS -n -v --line-numbers 2>&1 || true; pause ;;
      6) cat /etc/rkn-watcher/remnanode-scanner-allow.txt 2>/dev/null || echo '[НЕТ] Allow-list отсутствует'; pause ;;
      7) systemctl status remnanode-rkn-scanner-boot.service remnanode-rkn-scanner-update.timer --no-pager 2>&1 || true; systemctl list-timers --all remnanode-rkn-scanner-update.timer --no-pager 2>&1 || true; pause ;;
      8) journalctl -u remnanode-rkn-scanner-update.service -u remnanode-rkn-scanner-boot.service -u remnanode-rkn-scanner-health.service -n 150 --no-pager 2>&1 || true; pause ;;
      9) APP_DIR="$APP_DIR" bash "$f" install-safe || true; sync_rkn_watch || true; pause ;;
      10) APP_DIR="$APP_DIR" bash "$f" upstream || true ;;
      11) APP_DIR="$APP_DIR" bash "$f" uninstall || true; cleanup_rkn_watch_after_uninstall; pause ;;
      0) return 0 ;;
      *) echo -e "${RED}[ОШИБКА]${NC} Неверный пункт"; sleep 1 ;;
    esac
  done
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
  local transport="$1" profile host host2='' host_label='' host2_label='' remark mtime
  local -a first=()
  case "$transport" in
    xhttp) host_label='XHTTP' ;;
    raw) host_label='RAW' ;;
    hysteria) host_label='HYSTERIA2' ;;
    combined) host_label='XHTTP'; host2_label='HYSTERIA2' ;;
    *) echo -e "${RED}[ОШИБКА]${NC} Неизвестный transport: $transport"; return 1 ;;
  esac
  mapfile -t first < <(profile_paths "$transport")
  profile="${first[0]:-}"; host="${first[1]:-}"; host2="${first[2]:-}"
  [[ -s "$profile" ]] || { echo -e "${YELLOW}[НЕТ]${NC} Профиль ещё не создан: $profile"; return 1; }
  remark="$(sed -n 's/^Remark:[[:space:]]*//p' "$host" 2>/dev/null | head -1)"
  mtime="$(stat -c '%y' "$profile" 2>/dev/null || echo '-')"
  echo '#################### НАЧАЛО ВЫВОДА: REMNAWAVE PROFILE COPY ####################'
  echo "TRANSPORT: $transport"
  echo "PROFILE FILE: $profile"
  echo "UPDATED: $mtime"
  echo 'ВАЖНО: это локально сгенерированный файл. Какой Config Profile реально назначен ноде, проверяй в Remnawave panel.'
  echo
  echo '=== ОПИСАНИЕ ХОСТА ==='
  echo "${remark:-$(basename "$profile")}" 
  echo
  echo "=== HOST REMNAWAVE: $host_label ==="
  [[ -s "$host" ]] && cat "$host" || echo "Host-файл не найден: $host"
  if [[ -n "$host2" ]]; then
    echo
    echo "=== HOST REMNAWAVE: $host2_label ==="
    [[ -s "$host2" ]] && cat "$host2" || echo "Host-файл не найден: $host2"
  fi
  echo
  echo '=== ПОЛНЫЙ CONFIG PROFILE — КОПИРОВАТЬ В REMNAWAVE ==='
  cat "$profile"
  echo
  echo '#################### КОНЕЦ ВЫВОДА: REMNAWAVE PROFILE COPY ####################'
}

show_all_hosts(){
  local found=0 f
  echo '#################### НАЧАЛО ВЫВОДА: REMNAWAVE HOSTS ####################'
  f="$APP_DIR/remnawave-profiles/host-xhttp.txt"
  if [[ -s "$f" ]]; then echo '=== HOST XHTTP ==='; cat "$f"; echo; found=1; fi
  f="$APP_DIR/remnawave-profiles/host-raw.txt"
  if [[ -s "$f" ]]; then echo '=== HOST RAW ==='; cat "$f"; echo; found=1; fi
  f="$APP_DIR/remnawave-profiles/host-hysteria2.txt"
  if [[ -s "$f" ]]; then echo '=== HOST HYSTERIA2 ==='; cat "$f"; echo; found=1; fi
  (( found == 1 )) || echo '[НЕТ] Host-файлы ещё не созданы.'
  echo '#################### КОНЕЦ ВЫВОДА: REMNAWAVE HOSTS ####################'
}

show_profiles(){
  local choice active
  while true; do
    clear || true
    active="$(cat "$APP_DIR/.transport" 2>/dev/null || true)"
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          ПРОСМОТР И КОПИРОВАНИЕ ПРОФИЛЕЙ REMNAWAVE        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo "Последний локально сгенерированный transport: ${active:-не задан}"
    echo "Базовое имя inbound: $(cat "$APP_DIR/.node_name" 2>/dev/null || echo 'не задано')"
    echo 'Назначенный в Remnawave Config Profile может отличаться — проверяй панель.'
    echo
    echo ' 1) Показать ПОСЛЕДНИЙ ЛОКАЛЬНЫЙ профиль + Host полностью'
    echo ' 2) XHTTP + REALITY'
    echo ' 3) RAW + REALITY'
    echo ' 4) Hysteria2 + TLS'
    echo ' 5) XHTTP + Hysteria2 (combined)'
    echo ' 6) Показать список созданных файлов'
    echo ' 7) Вывод Host: XHTTP / RAW / Hysteria2'
    echo ' 0) Назад'
    read -r -p 'Выбор [1]: ' choice || true
    case "${choice:-1}" in
      1)
        if [[ -n "$active" ]]; then
          print_profile_full "$active" || echo 'Локальный transport marker задан, но его профиль отсутствует/повреждён.'
        else
          echo 'Локальный transport marker не задан'
        fi
        pause
        ;;
      2) print_profile_full xhttp || true; pause ;;
      3) print_profile_full raw || true; pause ;;
      4) print_profile_full hysteria || true; pause ;;
      5) print_profile_full combined || true; pause ;;
      6) find "$APP_DIR/remnawave-profiles" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM  %f\n' 2>/dev/null | sort; pause ;;
      7) show_all_hosts; pause ;;
      0) return 0 ;;
      *) echo -e "${RED}[ОШИБКА]${NC} Неверный пункт"; sleep 1 ;;
    esac
  done
}

show_status(){
  clear || true
  local node=0 nginx=0 rkn=0 scanner_guard=0 scanner_state=0 lock_state legacy_bypass=0 telemt_443=0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode && node=1 || true
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnawave-nginx && nginx=1 || true
  [[ -x /usr/local/bin/rkn-watcher || -x /opt/rkn-watcher/rkn-watcher.sh ]] && rkn=1 || true
  [[ -s "$APP_DIR/rkn-safe/.scanner-guard-active" ]] && scanner_state=1 || true
  command -v iptables >/dev/null 2>&1 && iptables -C INPUT -j REMNA_RKN_SCANNERS >/dev/null 2>&1 && scanner_guard=1 || true
  lock_state="$(rkn_update_lock_state)"
  [[ -e /usr/local/bin/remnanode || -L /usr/local/bin/remnanode ]] && legacy_bypass=1 || true
  [[ -e /etc/nginx/modules-enabled/90-stream-sni.conf ]] && telemt_443=1 || true
  if ss -lntp 2>/dev/null | grep -E '[:.]443[[:space:]]' | grep -q 'nginx'; then telemt_443=1; fi
  printf '  '; status_badge 'Remnawave node' "$node"; echo
  printf '  '; status_badge 'SelfSteal nginx' "$nginx"; echo
  printf '  '; status_badge 'RKN Watcher' "$rkn"; echo
  printf '  '; status_badge 'RKN scanner guard' "$scanner_guard"; echo
  printf '  %-22s %s\n' 'RKN update lock:' "$lock_state"
  if (( scanner_state == 1 && scanner_guard == 0 )); then echo -e "  ${RED}[РАСХОЖДЕНИЕ] state=active, но INPUT jump отсутствует${NC}"; fi
  [[ "$lock_state" == stale ]] && echo -e "  ${RED}[РАСХОЖДЕНИЕ] RKN update lock протух/имеет некорректный mtime; self-heal удалит его при следующей проверке${NC}"
  (( legacy_bypass == 1 )) && echo -e "  ${RED}[BYPASS] найден /usr/local/bin/remnanode — запусти NEXT заново, preflight его удалит${NC}"
  (( telemt_443 == 1 )) && echo -e "  ${RED}[КОНФЛИКТ 443] обнаружен старый Telemt/host-nginx listener или 90-stream-sni.conf; Xray должен единолично владеть TCP/443${NC}"
  echo
  printf '  %-22s %s\n' 'Stable base:' "$LEGACY_COMMIT"
  printf '  %-22s %s\n' 'Module commit:' "$MODULE_REF"
  printf '  %-22s %s\n' 'Node domain:' "$(cat "$APP_DIR/.node_domain" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Inbound base name:' "$(cat "$APP_DIR/.node_name" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Local transport marker:' "$(cat "$APP_DIR/.transport" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'Reality SNI:' "$(cat "$APP_DIR/.reality_sni" 2>/dev/null || echo '-')"
  printf '  %-22s %s\n' 'SelfSteal site:' "$(cat "$APP_DIR/.selfsteal_site" 2>/dev/null || echo 'random (default)')"
  printf '  %-22s %s\n' 'NEXT command:' "$NEXT_GLOBAL_COMMAND"
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
      8) run_rkn ;;
      0) return 0 ;;
      *) echo -e "${RED}[ОШИБКА]${NC} Неверный пункт"; sleep 1 ;;
    esac
  done
}

main(){ preflight || return 1; menu; }
main "$@"
