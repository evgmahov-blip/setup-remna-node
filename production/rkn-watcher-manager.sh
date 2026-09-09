#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
RKN_VENDOR_DIR="${RKN_VENDOR_DIR:-$APP_DIR/vendor/rkn-watcher}"
RKN_SAFE_DIR="${RKN_SAFE_DIR:-$APP_DIR/rkn-safe}"
GUARD_SCRIPT="$RKN_SAFE_DIR/scanner-guard.sh"
ALLOW_FILE="/etc/rkn-watcher/remnanode-scanner-allow.txt"
SETTINGS_FILE="/etc/rkn-watcher/settings.conf"
WHITELIST_FILE="/etc/rkn-watcher/whitelist.json"
BLACKLIST_FILE="/etc/rkn-watcher/blacklist.json"
ACTIVE_STATE="$RKN_SAFE_DIR/.scanner-guard-active"
RKN_UPSTREAM_REPO="Balbuto/RKN-Watcher"
RKN_UPSTREAM_REF="558fc11a0792892927785e162359585d51972a6a"
RKN_RAW_BASE="https://raw.githubusercontent.com/${RKN_UPSTREAM_REPO}/${RKN_UPSTREAM_REF}"
RKN_FILES=(installer.sh rkn-watcher.sh config_tool.py geoip_apply.py SHA256SUMS VERSION)
ROLLBACK_UNIT="remnanode-rkn-scanner-rollback"
BOOT_UNIT="remnanode-rkn-scanner-boot.service"
UPDATE_UNIT="remnanode-rkn-scanner-update.service"
UPDATE_TIMER="remnanode-rkn-scanner-update.timer"

say(){ printf '%s\n' "$*"; }
err(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { err 'Запусти от root'; return 1; }; }

session_ip(){
  local raw="${SSH_CLIENT:-${SSH_CONNECTION:-}}"
  printf '%s' "${raw%% *}"
}

panel_ip(){
  if [[ -r "$APP_DIR/.panel_ip" ]]; then
    tr -d '[:space:]' < "$APP_DIR/.panel_ip"
  fi
  return 0
}

node_port(){
  sed -n 's/^NODE_PORT=//p' "$APP_DIR/.env" 2>/dev/null | head -1 || true
}

normalize_ipv4(){
  local value="$1"
  [[ -n "$value" ]] || return 1
  python3 - "$value" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1].strip())
    if ip.version != 4:
        raise ValueError
except Exception:
    raise SystemExit(1)
print(ip)
PY
}

fetch_upstream(){
  local tmp file
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  for file in "${RKN_FILES[@]}"; do
    curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
      "$RKN_RAW_BASE/$file" -o "$tmp/$file" || { err "Не удалось скачать $file"; return 1; }
  done

  (
    cd "$tmp"
    grep -E '  (installer\.sh|rkn-watcher\.sh|config_tool\.py|geoip_apply\.py)$' SHA256SUMS > SHA256SUMS.required
    sha256sum -c SHA256SUMS.required
  ) || { err 'Контрольные суммы RKN Watcher не совпали'; return 1; }

  mkdir -p "$RKN_VENDOR_DIR"
  install -m 0755 "$tmp/installer.sh" "$RKN_VENDOR_DIR/installer.sh"
  install -m 0755 "$tmp/rkn-watcher.sh" "$RKN_VENDOR_DIR/rkn-watcher.sh"
  install -m 0755 "$tmp/config_tool.py" "$RKN_VENDOR_DIR/config_tool.py"
  install -m 0755 "$tmp/geoip_apply.py" "$RKN_VENDOR_DIR/geoip_apply.py"
  install -m 0644 "$tmp/SHA256SUMS" "$RKN_VENDOR_DIR/SHA256SUMS"
  install -m 0644 "$tmp/VERSION" "$RKN_VENDOR_DIR/VERSION"
  printf '%s\n' "$RKN_UPSTREAM_REF" > "$RKN_VENDOR_DIR/.upstream-ref"
  say "[OK] RKN Watcher подготовлен из фиксированного upstream commit $RKN_UPSTREAM_REF"
}

install_dependencies(){
  local pkg missing=()
  for pkg in iptables ipset curl ca-certificates python3 util-linux; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
      missing+=("$pkg")
    fi
  done
  if ((${#missing[@]})); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${missing[@]}"
  fi
}

install_upstream_files(){
  mkdir -p /opt/rkn-watcher /etc/rkn-watcher \
    /var/lib/rkn-watcher/cache/countries /var/lib/rkn-watcher/state \
    /var/lib/rkn-watcher/locks /var/log/rkn-watcher "$RKN_SAFE_DIR"
  install -m 0755 "$RKN_VENDOR_DIR/rkn-watcher.sh" /opt/rkn-watcher/rkn-watcher.sh
  install -m 0755 "$RKN_VENDOR_DIR/config_tool.py" /opt/rkn-watcher/config_tool.py
  install -m 0755 "$RKN_VENDOR_DIR/geoip_apply.py" /opt/rkn-watcher/geoip_apply.py
  ln -sfn /opt/rkn-watcher/rkn-watcher.sh /usr/local/bin/rkn-watcher
}

record_safe_allow_ips(){
  local ssh_ip panel tmp value normalized
  ssh_ip="$(session_ip)"
  panel="$(panel_ip)"
  mkdir -p /etc/rkn-watcher
  tmp="$(mktemp)"
  [[ -r "$ALLOW_FILE" ]] && cat "$ALLOW_FILE" >> "$tmp"
  for value in "$ssh_ip" "$panel"; do
    if normalized="$(normalize_ipv4 "$value" 2>/dev/null)"; then
      printf '%s\n' "$normalized" >> "$tmp"
    fi
  done
  python3 - "$tmp" "$ALLOW_FILE" <<'PY'
import ipaddress, sys
src, dst = sys.argv[1:3]
items = set()
for raw in open(src, encoding='utf-8'):
    value = raw.strip()
    if not value:
        continue
    try:
        ip = ipaddress.ip_address(value)
        if ip.version == 4:
            items.add(str(ip))
    except Exception:
        pass
with open(dst, 'w', encoding='utf-8') as fh:
    for item in sorted(items, key=lambda x: int(ipaddress.ip_address(x))):
        fh.write(item + '\n')
PY
  chmod 600 "$ALLOW_FILE"
  rm -f "$tmp"
}

write_safe_config(){
  local ips_json
  record_safe_allow_ips

  cat > "$SETTINGS_FILE" <<'EOF_SETTINGS'
FILTER_PORTS="443"
LOG_RST="n"
AUTO_UPDATE="n"
ENABLE_TSPUBLOCK="n"
ENABLE_GOVIPS="n"
EOF_SETTINGS

  ips_json="$(python3 - "$ALLOW_FILE" <<'PY'
import json, sys
items=[line.strip() for line in open(sys.argv[1], encoding='utf-8') if line.strip()]
print(json.dumps(items))
PY
)"
  python3 - "$WHITELIST_FILE" "$ips_json" <<'PY'
import json, os, sys, tempfile
path, ips_raw = sys.argv[1:3]
data = {"enabled": False, "countries": [], "ips": json.loads(ips_raw), "ports": []}
os.makedirs(os.path.dirname(path), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.whitelist.', text=True)
with os.fdopen(fd, 'w', encoding='utf-8') as fh:
    json.dump(data, fh, indent=4)
    fh.write('\n')
os.replace(tmp, path)
PY

  cat > "$BLACKLIST_FILE" <<'EOF_BLACKLIST'
{
    "ips": [],
    "ports": []
}
EOF_BLACKLIST
  chmod 600 "$SETTINGS_FILE" "$WHITELIST_FILE" "$BLACKLIST_FILE"
}

write_guard_script(){
  mkdir -p "$RKN_SAFE_DIR"
  cat > "$GUARD_SCRIPT" <<'EOF_GUARD'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

CHAIN="REMNA_RKN_SCANNERS"
ALLOW_FILE="/etc/rkn-watcher/remnanode-scanner-allow.txt"

remove_jump(){
  while iptables -C INPUT -j "$CHAIN" >/dev/null 2>&1; do
    iptables -D INPUT -j "$CHAIN" >/dev/null 2>&1 || break
  done
}

scanner_count(){
  ipset list TSPUIPS 2>/dev/null | awk -F': ' '/Number of entries/ {print $2; found=1} END {if (!found) print 0}'
}

apply_guard(){
  local count ip
  count="$(scanner_count)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  if (( count < 1 )); then
    echo '[ERROR] TSPUIPS пуст; scanner guard не меняю' >&2
    return 1
  fi

  iptables -N "$CHAIN" >/dev/null 2>&1 || true
  remove_jump
  iptables -F "$CHAIN"

  if [[ -r "$ALLOW_FILE" ]]; then
    while IFS= read -r ip; do
      [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
      iptables -A "$CHAIN" -s "$ip" -j RETURN
    done < "$ALLOW_FILE"
  fi

  iptables -A "$CHAIN" -p tcp -m multiport --dports 80,443 -m set --match-set TSPUIPS src -j DROP
  iptables -A "$CHAIN" -p udp --dport 443 -m set --match-set TSPUIPS src -j DROP
  iptables -A "$CHAIN" -j RETURN
  iptables -I INPUT 1 -j "$CHAIN"
  echo "[OK] Scanner guard активен: TSPUIPS=$count; DROP tcp/80,tcp/443,udp/443"
}

remove_guard(){
  remove_jump
  if iptables -nL "$CHAIN" >/dev/null 2>&1; then
    iptables -F "$CHAIN" >/dev/null 2>&1 || true
    iptables -X "$CHAIN" >/dev/null 2>&1 || true
  fi
  echo '[OK] Scanner guard снят'
}

status_guard(){
  printf 'TSPUIPS entries: %s\n' "$(scanner_count)"
  if iptables -C INPUT -j "$CHAIN" >/dev/null 2>&1; then
    echo 'Scanner guard: ACTIVE'
    iptables -S "$CHAIN" 2>/dev/null || true
  else
    echo 'Scanner guard: INACTIVE'
  fi
}

case "${1:-status}" in
  apply) apply_guard ;;
  remove) remove_guard ;;
  status) status_guard ;;
  *) echo 'Использование: scanner-guard.sh [apply|remove|status]' >&2; exit 1 ;;
esac
EOF_GUARD
  chmod 0755 "$GUARD_SCRIPT"
}

write_systemd_units(){
  cat > "/etc/systemd/system/$BOOT_UNIT" <<EOF_BOOT
[Unit]
Description=Remnanode RKN scanner guard restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rkn-watcher apply --quiet
ExecStart=$GUARD_SCRIPT apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_BOOT

  cat > "/etc/systemd/system/$UPDATE_UNIT" <<EOF_UPDATE
[Unit]
Description=Remnanode RKN scanner list update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rkn-watcher update --quiet
ExecStartPost=$GUARD_SCRIPT apply
EOF_UPDATE

  cat > "/etc/systemd/system/$UPDATE_TIMER" <<EOF_TIMER
[Unit]
Description=Remnanode daily RKN scanner list update

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=1800
Persistent=true
Unit=$UPDATE_UNIT

[Install]
WantedBy=timers.target
EOF_TIMER

  systemctl daemon-reload
}

disable_all_autostart(){
  systemctl disable --now "$UPDATE_TIMER" "$BOOT_UNIT" >/dev/null 2>&1 || true
  systemctl disable --now rkn-watcher-update.timer rkn-watcher-boot.service >/dev/null 2>&1 || true
}

enable_safe_autostart(){
  systemctl enable "$BOOT_UNIT" >/dev/null
  systemctl enable --now "$UPDATE_TIMER" >/dev/null
}

cancel_rollback(){
  systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemctl reset-failed "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
}

schedule_rollback(){
  cancel_rollback
  systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active=120s "$GUARD_SCRIPT" remove
}

verify_guard(){
  local rules ssh_ip panel port
  iptables -C INPUT -j REMNA_RKN_SCANNERS >/dev/null 2>&1 || { err 'Нет INPUT jump в scanner guard'; return 1; }
  rules="$(iptables -S REMNA_RKN_SCANNERS 2>/dev/null || true)"
  grep -Fq -- '--dports 80,443' <<<"$rules" || { err 'Нет scanner DROP для TCP 80/443'; return 1; }
  grep -Fq -- '-p udp' <<<"$rules" || { err 'Нет scanner DROP для UDP'; return 1; }
  grep -Fq -- '--dport 443' <<<"$rules" || { err 'Нет scanner DROP для UDP/443'; return 1; }
  grep -Fq -- '--match-set TSPUIPS src' <<<"$rules" || { err 'Scanner guard не привязан к TSPUIPS'; return 1; }
  if grep -Eq -- '--dport (22|2222)( |$)|--dports [^ ]*(22|2222)' <<<"$rules"; then
    err 'Scanner guard неожиданно затрагивает SSH/control port'
    return 1
  fi

  ssh_ip="$(session_ip)"
  panel="$(panel_ip)"
  port="$(node_port)"
  if [[ "$port" == '80' || "$port" == '443' ]]; then
    err "Node control port $port пересекается с scanner-protection ports; SAFE mode не подтверждаю"
    return 1
  fi
  printf '[OK] Current SSH IP: %s\n' "${ssh_ip:-не найден}"
  printf '[OK] Panel IP: %s\n' "${panel:-не найден}"
  printf '[OK] Node control port не фильтруется: %s\n' "${port:-не найден}"
  return 0
}

refresh_lists(){
  [[ -x /usr/local/bin/rkn-watcher ]] || { err 'RKN Watcher не установлен'; return 1; }
  if /usr/local/bin/rkn-watcher update --quiet; then
    "$GUARD_SCRIPT" apply
  else
    err 'Обновление списков не прошло; старый рабочий TSPUIPS не заменяем'
    return 1
  fi
}

activate_safe(){
  local answer=""
  [[ -x "$GUARD_SCRIPT" ]] || { err 'Scanner guard не установлен'; return 1; }
  record_safe_allow_ips
  write_safe_config
  schedule_rollback

  if ! "$GUARD_SCRIPT" apply || ! verify_guard; then
    echo '[ERROR] Проверка scanner guard не прошла; выполняю немедленный rollback.'
    "$GUARD_SCRIPT" remove || true
    cancel_rollback
    return 1
  fi

  echo
  echo '[SAFE] Защита от известных TSPU/Skipa scanners уже активна.'
  echo '[SAFE] Она режет только tcp/80, tcp/443 и udp/443 для IP из TSPUIPS.'
  echo '[SAFE] SSH и control port не входят в правила.'
  echo '[SAFE] Если не подтвердить, через 120 секунд guard будет снят автоматически.'

  if [[ "${RKN_ASSUME_KEEP:-0}" == "1" ]]; then
    answer='KEEP'
  elif [[ -t 0 ]]; then
    read -r -p 'Оставить защиту постоянно? Введите KEEP: ' answer
  fi

  if [[ "$answer" == 'KEEP' ]]; then
    cancel_rollback
    "$GUARD_SCRIPT" apply
    enable_safe_autostart
    printf 'active\n' > "$ACTIVE_STATE"
    chmod 600 "$ACTIVE_STATE"
    echo '[OK] SAFE SCANNER MODE зафиксирован: boot restore + daily update включены.'
  else
    disable_all_autostart
    rm -f "$ACTIVE_STATE"
    echo '[INFO] KEEP не получен. Автооткат оставлен; защита будет снята максимум через 120 секунд.'
  fi
}

install_safe(){
  echo '#################### НАЧАЛО ВЫВОДА: RKN WATCHER SAFE INSTALL ####################'
  fetch_upstream
  install_dependencies
  install_upstream_files
  disable_all_autostart
  write_safe_config
  write_guard_script
  write_systemd_units

  echo '[*] Загружаю scanner lists. Upstream TSPUBLOCK/GOVIPS/GeoIP firewall hooks выключены.'
  if ! /usr/local/bin/rkn-watcher update --quiet; then
    echo '[ERROR] Не удалось получить свежий TSPUIPS; firewall не активирую.'
    echo '#################### КОНЕЦ ВЫВОДА: RKN WATCHER SAFE INSTALL ####################'
    return 1
  fi

  local count
  count="$(ipset list TSPUIPS 2>/dev/null | awk -F': ' '/Number of entries/ {print $2; found=1} END {if (!found) print 0}')"
  if [[ ! "$count" =~ ^[0-9]+$ ]] || (( count < 1 )); then
    echo '[ERROR] TSPUIPS пуст; firewall не активирую.'
    echo '#################### КОНЕЦ ВЫВОДА: RKN WATCHER SAFE INSTALL ####################'
    return 1
  fi
  echo "[OK] TSPUIPS загружен: $count записей"
  echo '#################### КОНЕЦ ВЫВОДА: RKN WATCHER SAFE INSTALL ####################'
  activate_safe
}

show_status(){
  echo '#################### НАЧАЛО ВЫВОДА: RKN WATCHER STATUS ####################'
  if [[ -x /usr/local/bin/rkn-watcher ]]; then
    /usr/local/bin/rkn-watcher status --quiet 2>/dev/null || /usr/local/bin/rkn-watcher status || true
  else
    echo 'RKN Watcher: не установлен'
  fi

  echo
  if [[ -x "$GUARD_SCRIPT" ]]; then
    "$GUARD_SCRIPT" status || true
  else
    echo 'Scanner guard: не установлен'
  fi
  printf 'Safe state: %s\n' "$( [[ -s "$ACTIVE_STATE" ]] && cat "$ACTIVE_STATE" || echo inactive )"
  printf 'Current SSH IP: %s\n' "$(session_ip || true)"
  printf 'Panel IP: %s\n' "$(panel_ip || true)"
  printf 'Node control port: %s\n' "$(node_port || true)"
  printf 'Pinned upstream: %s\n' "$RKN_UPSTREAM_REF"
  systemctl is-enabled "$UPDATE_TIMER" 2>/dev/null | sed 's/^/Safe update timer: /' || echo 'Safe update timer: disabled'
  echo '#################### КОНЕЦ ВЫВОДА: RKN WATCHER STATUS ####################'
}

run_upstream_menu(){
  local answer
  echo '#################### НАЧАЛО ВЫВОДА: RKN WATCHER ADVANCED WARNING ####################'
  echo '[WARN] ADVANCED upstream menu может включить широкие TSPUBLOCK/GOVIPS/GeoIP правила.'
  echo '[WARN] SAFE SCANNER MODE использует отдельную узкую цепочку только для известных scanner IP.'
  echo '#################### КОНЕЦ ВЫВОДА: RKN WATCHER ADVANCED WARNING ####################'
  read -r -p 'Открыть ADVANCED upstream menu? Введите UPSTREAM: ' answer
  [[ "$answer" == 'UPSTREAM' ]] || { say '[INFO] Отменено'; return 0; }
  fetch_upstream
  (
    cd "$RKN_VENDOR_DIR"
    ./installer.sh menu
  )
}

uninstall_rkn(){
  echo '#################### НАЧАЛО ВЫВОДА: RKN WATCHER SAFE UNINSTALL ####################'
  cancel_rollback
  disable_all_autostart
  [[ -x "$GUARD_SCRIPT" ]] && "$GUARD_SCRIPT" remove || true
  rm -f "/etc/systemd/system/$BOOT_UNIT" "/etc/systemd/system/$UPDATE_UNIT" "/etc/systemd/system/$UPDATE_TIMER"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$RKN_SAFE_DIR"
  if [[ -x /opt/rkn-watcher/rkn-watcher.sh ]]; then
    RKN_ASSUME_YES=1 /opt/rkn-watcher/rkn-watcher.sh uninstall || true
  else
    rm -f /usr/local/bin/rkn-watcher
    rm -rf /opt/rkn-watcher /etc/rkn-watcher /var/lib/rkn-watcher /var/log/rkn-watcher
  fi
  echo '#################### КОНЕЦ ВЫВОДА: RKN WATCHER SAFE UNINSTALL ####################'
}

main_menu(){
  while true; do
    clear || true
    echo '========================================================'
    echo ' RKN WATCHER — SAFE SCANNER MODE'
    echo '========================================================'
    echo ' 1) Установить / обновить SAFE scanner protection'
    echo ' 2) Активировать / пере-применить guard с rollback 120 сек'
    echo ' 3) Обновить scanner lists сейчас'
    echo ' 4) Статус'
    echo ' 5) ADVANCED upstream menu'
    echo ' 6) Полностью удалить RKN Watcher'
    echo ' 0) Назад'
    echo
    read -r -p 'Выбор [0]: ' choice
    case "${choice:-0}" in
      1) install_safe; read -r -p 'Enter...' _ ;;
      2) activate_safe; read -r -p 'Enter...' _ ;;
      3) refresh_lists; read -r -p 'Enter...' _ ;;
      4) show_status; read -r -p 'Enter...' _ ;;
      5) run_upstream_menu ;;
      6) uninstall_rkn; read -r -p 'Enter...' _ ;;
      0) return 0 ;;
      *) say '[WARN] Неверный пункт'; sleep 1 ;;
    esac
  done
}

main(){
  need_root
  case "${1:-menu}" in
    menu) main_menu ;;
    install|install-safe|update) install_safe ;;
    activate|apply) activate_safe ;;
    refresh) refresh_lists ;;
    status) show_status ;;
    upstream) run_upstream_menu ;;
    uninstall) uninstall_rkn ;;
    *) err 'Использование: rkn-watcher-manager.sh [menu|install-safe|activate|refresh|status|upstream|uninstall]'; return 1 ;;
  esac
}

main "$@"
