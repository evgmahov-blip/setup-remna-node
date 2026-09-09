#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
CERTS_DIR="${CERTS_DIR:-$APP_DIR/certs}"
RKN_HEALTH_SERVICE="remnanode-rkn-scanner-health.service"
RKN_HEALTH_TIMER="remnanode-rkn-scanner-health.timer"
RKN_UFW_PATH="remnanode-rkn-scanner-ufw.path"
RKN_HEALTH_SCRIPT="$APP_DIR/rkn-safe/health-check.sh"
RKN_PATCHED_MANAGER_SHA256="a5f9f8a7a3bb8a5cce5683ee066e046bdedf754c277d99424184c39cf93ed244"
RKN_UPDATE_LOCK_MAX_MINUTES="${RKN_UPDATE_LOCK_MAX_MINUTES:-30}"

log(){ printf '%s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { fail 'Запусти от root'; return 1; }; }
need_python(){ command -v python3 >/dev/null 2>&1 || { fail 'Для детерминированного runtime patch нужен python3'; return 1; }; }

patch_rkn_manager(){
  local target="$1" got
  [[ -s "$target" ]] || { fail "RKN manager не найден: $target"; return 1; }
  need_python
  python3 - "$target" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')

needle='''IPSET_STATE_FILE="/var/lib/rkn-watcher/state/ipset.conf"\n'''
insert='''IPSET_STATE_FILE="/var/lib/rkn-watcher/state/ipset.conf"\nLAST_COUNT_FILE="/var/lib/rkn-watcher/state/remna-scanner-last-count"\nMIN_PREFIX="${SCANNER_MIN_PREFIX:-16}"\nMAX_ENTRIES="${SCANNER_MAX_ENTRIES:-300000}"\n'''
if needle not in s:
    raise SystemExit('RKN patch marker constants not found')
s=s.replace(needle, insert, 1)

needle='''scanner_count(){\n  ipset list TSPUIPS 2>/dev/null | awk -F': ' '/Number of entries/ {print $2; found=1} END {if (!found) print 0}'\n}\n\napply_guard(){\n'''
insert='''scanner_count(){\n  ipset list TSPUIPS 2>/dev/null | awk -F': ' '/Number of entries/ {print $2; found=1} END {if (!found) print 0}'\n}\n\nvalidate_scanner_set(){\n  local count prev wide\n  count="$(scanner_count)"\n  [[ "$count" =~ ^[0-9]+$ ]] || count=0\n  (( count >= 1 )) || { echo '[ERROR] TSPUIPS пуст' >&2; return 1; }\n  (( count <= MAX_ENTRIES )) || { echo "[ERROR] TSPUIPS=$count превышает лимит $MAX_ENTRIES" >&2; return 1; }\n  wide="$(ipset save TSPUIPS 2>/dev/null | awk -v minpfx="$MIN_PREFIX" '\''\n    $1=="add" && $2=="TSPUIPS" {\n      net=$3; if (index(net,"/")>0) { split(net,a,"/"); if ((a[2]+0) < minpfx) { print net; n++ } }\n      if (n>=3) exit\n    }'\'')"\n  if [[ -n "$wide" ]]; then\n    echo "[ERROR] TSPUIPS содержит слишком широкие сети (< /$MIN_PREFIX):" >&2\n    printf '%s\\n' "$wide" >&2\n    return 1\n  fi\n  if [[ -r "$LAST_COUNT_FILE" ]]; then\n    prev="$(cat "$LAST_COUNT_FILE" 2>/dev/null || true)"\n    if [[ "$prev" =~ ^[0-9]+$ ]] && (( prev > 100 && count > prev * 3 )); then\n      echo "[ERROR] TSPUIPS вырос с $prev до $count (>3x); автоматическое применение запрещено" >&2\n      return 1\n    fi\n  fi\n}\n\nrecord_good_count(){ scanner_count > "$LAST_COUNT_FILE"; chmod 600 "$LAST_COUNT_FILE"; }\n\napply_guard(){\n'''
if needle not in s:
    raise SystemExit('RKN patch marker scanner_count not found')
s=s.replace(needle, insert, 1)

needle='''  if (( count < 1 )); then\n    echo '[ERROR] TSPUIPS пуст; scanner guard не меняю' >&2\n    return 1\n  fi\n\n  iptables -N "$CHAIN" >/dev/null 2>&1 || true\n'''
insert='''  if (( count < 1 )); then\n    echo '[ERROR] TSPUIPS пуст; scanner guard не меняю' >&2\n    return 1\n  fi\n  validate_scanner_set || { echo '[ERROR] Scanner guard НЕ меняю: TSPUIPS не прошёл sanity-check' >&2; return 1; }\n\n  iptables -N "$CHAIN" >/dev/null 2>&1 || true\n'''
if needle not in s:
    raise SystemExit('RKN patch marker apply not found')
s=s.replace(needle, insert, 1)

needle='''  iptables -I INPUT 1 -j "$CHAIN"\n  echo "[OK] Scanner guard активен: TSPUIPS=$count; DROP tcp/80,tcp/443,udp/443"\n}\n'''
insert='''  iptables -I INPUT 1 -j "$CHAIN"\n  record_good_count\n  echo "[OK] Scanner guard активен: TSPUIPS=$count; DROP tcp/80,tcp/443,udp/443"\n}\n'''
if needle not in s:
    raise SystemExit('RKN patch marker record count not found')
s=s.replace(needle, insert, 1)

needle='''case "${1:-status}" in\n  apply) apply_guard ;;\n  remove) remove_guard ;;\n  status) status_guard ;;\n  *) echo 'Использование: scanner-guard.sh [apply|remove|status]' >&2; exit 1 ;;\nesac\n'''
insert='''case "${1:-status}" in\n  apply) apply_guard ;;\n  validate) validate_scanner_set ;;\n  remove) remove_guard ;;\n  status) status_guard ;;\n  *) echo 'Использование: scanner-guard.sh [apply|validate|remove|status]' >&2; exit 1 ;;\nesac\n'''
if needle not in s:
    raise SystemExit('RKN patch marker case not found')
s=s.replace(needle, insert, 1)

pattern=r'''write_safe_update_script\(\)\{\n.*?\n\}\n\nwrite_systemd_units\(\)\{'''
replacement='''write_safe_update_script(){\n  cat > "$SAFE_UPDATE_SCRIPT" <<EOF_UPDATE_SCRIPT\n#!/usr/bin/env bash\nset -Eeuo pipefail\nGUARD="$GUARD_SCRIPT"\nLAST_GOOD="$RKN_SAFE_DIR/last-good-tspu.ipset"\nTMP_GOOD="\\${LAST_GOOD}.tmp"\nUPDATE_LOCK="$RKN_SAFE_DIR/.safe-update-running"\ntrap 'rm -f "\\$UPDATE_LOCK"' EXIT\ntouch "\\$UPDATE_LOCK"\n\nrestore_last_good(){\n  "\\$GUARD" remove >/dev/null 2>&1 || true\n  if [[ -s "\\$LAST_GOOD" ]]; then\n    if ipset list TSPUIPS >/dev/null 2>&1; then ipset flush TSPUIPS >/dev/null 2>&1 || true; fi\n    if ipset restore -exist < "\\$LAST_GOOD"; then\n      "\\$GUARD" apply\n      logger -t remna-rkn 'SAFE update rejected; restored last-good TSPUIPS' || true\n      return 0\n    fi\n  fi\n  rm -f "$RKN_SAFE_DIR/.scanner-guard-active"\n  logger -t remna-rkn 'SAFE update rejected; no usable last-good TSPUIPS, guard disabled until manual recovery' || true\n  return 1\n}\n\ncat > "$SETTINGS_FILE" <<'EOF_SETTINGS'\nFILTER_PORTS="443"\nLOG_RST="n"\nAUTO_UPDATE="n"\nENABLE_TSPUBLOCK="n"\nENABLE_GOVIPS="n"\nEOF_SETTINGS\n/opt/rkn-watcher/config_tool.py set-enabled false >/dev/null 2>&1 || true\n\nif "\\$GUARD" validate >/dev/null 2>&1; then\n  rm -f "\\$TMP_GOOD"\n  if ipset save TSPUIPS > "\\$TMP_GOOD"; then chmod 600 "\\$TMP_GOOD"; mv -f "\\$TMP_GOOD" "\\$LAST_GOOD"; else rm -f "\\$TMP_GOOD"; fi\nfi\n\n"\\$GUARD" remove >/dev/null 2>&1 || true\nif ! /usr/local/bin/rkn-watcher update --quiet; then\n  echo '[ERROR] RKN list update failed; restoring last-good set' >&2\n  restore_last_good || true\n  exit 1\nfi\nif ! "\\$GUARD" validate; then\n  echo '[ERROR] Новый TSPUIPS не прошёл sanity-check; restoring last-good set' >&2\n  restore_last_good || true\n  exit 1\nfi\n"\\$GUARD" apply\nlogger -t remna-rkn 'SAFE scanner list update OK' || true\nEOF_UPDATE_SCRIPT\n  chmod 0755 "$SAFE_UPDATE_SCRIPT"\n}\n\nwrite_systemd_units(){'''
s2,n=re.subn(pattern,replacement,s,flags=re.S)
if n != 1:
    raise SystemExit(f'RKN patch safe-update replacement count={n}')
s=s2

needle='''[Service]\nType=oneshot\nExecStart=$SAFE_UPDATE_SCRIPT\nEOF_UPDATE\n'''
insert='''[Service]\nType=oneshot\nExecStart=$SAFE_UPDATE_SCRIPT\nExecStopPost=/bin/sh -c 'test "$$EXIT_STATUS" = "0" || logger -t remna-rkn "SAFE update FAILED"'\nEOF_UPDATE\n'''
if needle not in s:
    raise SystemExit('RKN patch marker ExecStopPost not found')
s=s.replace(needle, insert, 1)

p.write_text(s, encoding='utf-8')
PY
  bash -n "$target" || { fail 'patched RKN manager не прошёл bash -n'; return 1; }
  grep -Fq 'validate_scanner_set' "$target" || { fail 'RKN sanity patch не применён'; return 1; }
  grep -Fq 'last-good-tspu.ipset' "$target" || { fail 'RKN rollback patch не применён'; return 1; }
  grep -Fq '.safe-update-running' "$target" || { fail 'RKN update-lock patch не применён'; return 1; }
  got="$(sha256sum "$target" | cut -d' ' -f1)"
  [[ "$got" == "$RKN_PATCHED_MANAGER_SHA256" ]] || { fail "patched RKN SHA256 mismatch: $got"; return 1; }
  log "[OK] RKN manager усилен и аттестован: $got"
}

patch_selfsteal_manager(){
  local target="$1"
  [[ -s "$target" ]] || { fail "SelfSteal manager не найден: $target"; return 1; }
  bash -n "$target" || { fail 'SelfSteal manager не прошёл bash -n'; return 1; }
  grep -Fq "local selected='random' template" "$target" || { fail 'SelfSteal RANDOM default отсутствует'; return 1; }
  grep -Fq '/data/streams.json' "$target" || { fail 'SelfSteal STREAM не self-contained'; return 1; }
  grep -Fq '.uniquify-manifest.txt' "$target" || { fail 'SelfSteal manifest cleanup отсутствует'; return 1; }
  log '[OK] SelfSteal module уже hardened; runtime rewrite не требуется'
}

restore_hysteria_cert_mount(){
  local compose backup='' tmpc need_edit=0
  [[ -s "$APP_DIR/remnawave-profiles/hysteria2-tls.json" ]] || return 0
  compose="$APP_DIR/docker-compose.yml"
  [[ -f "$compose" ]] || { fail 'Hysteria2 profile существует, но docker-compose.yml отсутствует'; return 1; }
  [[ -s "$CERTS_DIR/fullchain.pem" && -s "$CERTS_DIR/privkey.pem" ]] || { fail 'Hysteria2 profile существует, но сертификаты ноды отсутствуют'; return 1; }
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode \
     && docker exec remnanode test -s /etc/xray/certs/fullchain.pem 2>/dev/null \
     && docker exec remnanode test -s /etc/xray/certs/privkey.pem 2>/dev/null; then
    return 0
  fi
  if ! grep -Fq "$CERTS_DIR:/etc/xray/certs:ro" "$compose"; then
    need_edit=1
    backup="$compose.bak.hysteria-restore.$(date +%Y%m%d-%H%M%S)"
    cp -a "$compose" "$backup"
    tmpc="$(mktemp "$APP_DIR/.compose-hysteria-restore.XXXXXX")"
    if ! awk -v bind="$CERTS_DIR:/etc/xray/certs:ro" '
      BEGIN {in_remna=0; added=0}
      /^  remnanode:[[:space:]]*$/ {in_remna=1}
      in_remna && /^  [^[:space:]][^:]*:/ && $0 !~ /^  remnanode:/ {in_remna=0}
      {print}
      in_remna && !added && $0 ~ /^[[:space:]]+- \/dev\/shm:\/dev\/shm:rw[[:space:]]*$/ {
        match($0,/^[[:space:]]*/); indent=substr($0,1,RLENGTH); print indent "- " bind; added=1
      }
      END { if (!added) exit 42 }
    ' "$compose" > "$tmpc"; then
      rm -f "$tmpc"; fail "Не удалось вернуть cert bind; backup: $backup"; return 1
    fi
    mv -f "$tmpc" "$compose"
  fi
  log '[HYSTERIA2] Проверяю cert bind и пересоздаю только remnanode'
  if ! ( cd "$APP_DIR" && docker compose up -d remnanode ); then
    if (( need_edit )); then cp -a "$backup" "$compose"; fi
    fail "Не удалось пересоздать remnanode; backup: ${backup:-не создавался}"
    return 1
  fi
  if ! docker exec remnanode test -s /etc/xray/certs/fullchain.pem 2>/dev/null \
     || ! docker exec remnanode test -s /etc/xray/certs/privkey.pem 2>/dev/null; then
    fail 'Cert bind после восстановления не виден внутри remnanode'
    return 1
  fi
  if (( need_edit )); then rm -f "$backup"; fi
  log '[OK] Hysteria2 cert bind восстановлен'
}

rkn_update_lock_active(){
  local lock="$APP_DIR/rkn-safe/.safe-update-running" now mtime max_age age
  [[ -e "$lock" ]] || return 1
  now="$(date +%s 2>/dev/null || true)"
  mtime="$(stat -c %Y -- "$lock" 2>/dev/null || true)"
  if [[ ! "$now" =~ ^[0-9]+$ || ! "$mtime" =~ ^[0-9]+$ ]]; then
    log '[RKN] Update lock не удалось достоверно датировать; считаю stale и пытаюсь удалить'
  else
    max_age=$(( RKN_UPDATE_LOCK_MAX_MINUTES * 60 ))
    age=$(( now - mtime ))
    if (( mtime <= now && age <= max_age )); then
      return 0
    fi
    if (( mtime > now )); then
      log '[RKN] Update lock имеет mtime из будущего; считаю stale'
    else
      log "[RKN] Обнаружен протухший update lock (> ${RKN_UPDATE_LOCK_MAX_MINUTES} мин)"
    fi
  fi
  if rm -f -- "$lock"; then
    return 1
  fi
  log '[RKN] Не удалось удалить stale update lock; self-heal откладываю во избежание гонки'
  return 0
}

restore_rkn_guard(){
  local guard="$APP_DIR/rkn-safe/scanner-guard.sh"
  [[ -s "$APP_DIR/rkn-safe/.scanner-guard-active" && -x "$guard" ]] || return 0
  if rkn_update_lock_active; then
    log '[RKN] SAFE update сейчас активен; self-heal временно отложен'
    return 0
  fi
  command -v iptables >/dev/null 2>&1 || return 0
  if iptables -C INPUT -j REMNA_RKN_SCANNERS >/dev/null 2>&1; then return 0; fi
  log '[RKN] Guard отсутствует (возможен ufw reload); восстанавливаю'
  "$guard" apply
}

remove_rkn_health_watch(){
  systemctl disable --now "$RKN_HEALTH_TIMER" "$RKN_UFW_PATH" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$RKN_HEALTH_SERVICE" "/etc/systemd/system/$RKN_HEALTH_TIMER" "/etc/systemd/system/$RKN_UFW_PATH" "$RKN_HEALTH_SCRIPT"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

sync_rkn_health_watch(){
  local guard="$APP_DIR/rkn-safe/scanner-guard.sh" health_dir
  if [[ ! -s "$APP_DIR/rkn-safe/.scanner-guard-active" || ! -x "$guard" ]]; then
    remove_rkn_health_watch
    return 0
  fi
  health_dir="$(dirname "$RKN_HEALTH_SCRIPT")"
  mkdir -p "$health_dir"
  cat > "$RKN_HEALTH_SCRIPT" <<EOF_HEALTH
#!/bin/sh
set -eu
LOCK='$APP_DIR/rkn-safe/.safe-update-running'
GUARD='$guard'
MAX_MINUTES='$RKN_UPDATE_LOCK_MAX_MINUTES'

if [ -e "\$LOCK" ]; then
  now=\$(date +%s 2>/dev/null || printf '0')
  mtime=\$(stat -c %Y -- "\$LOCK" 2>/dev/null || true)
  stale=0
  case "\$now:\$mtime" in
    *[!0-9:]*|*:|:*) stale=1 ;;
    *)
      max_age=\$((MAX_MINUTES * 60))
      if [ "\$mtime" -gt "\$now" ] || [ \$((now - mtime)) -gt "\$max_age" ]; then stale=1; fi
      ;;
  esac
  if [ "\$stale" -eq 0 ]; then exit 0; fi
  logger -t remna-rkn 'Removing stale SAFE update lock before self-heal' 2>/dev/null || true
  if ! rm -f -- "\$LOCK"; then
    logger -t remna-rkn 'Cannot remove stale SAFE update lock; self-heal deferred' 2>/dev/null || true
    exit 0
  fi
fi
iptables -C INPUT -j REMNA_RKN_SCANNERS >/dev/null 2>&1 || "\$GUARD" apply
EOF_HEALTH
  chmod 0755 "$RKN_HEALTH_SCRIPT"
  /bin/sh -n "$RKN_HEALTH_SCRIPT"
  cat > "/etc/systemd/system/$RKN_HEALTH_SERVICE" <<EOF_SERVICE
[Unit]
Description=Remnanode scanner guard self-heal
After=network-online.target ufw.service
Wants=network-online.target
ConditionPathExists=$APP_DIR/rkn-safe/.scanner-guard-active

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 2
ExecStart=/bin/sh $RKN_HEALTH_SCRIPT
EOF_SERVICE
  cat > "/etc/systemd/system/$RKN_HEALTH_TIMER" <<EOF_TIMER
[Unit]
Description=Periodic Remnanode scanner guard health check

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
RandomizedDelaySec=15
Unit=$RKN_HEALTH_SERVICE

[Install]
WantedBy=timers.target
EOF_TIMER
  cat > "/etc/systemd/system/$RKN_UFW_PATH" <<EOF_PATH
[Unit]
Description=Re-apply Remnanode scanner guard after UFW rule changes

[Path]
PathChanged=/etc/ufw/user.rules
PathChanged=/etc/ufw/user6.rules
Unit=$RKN_HEALTH_SERVICE

[Install]
WantedBy=multi-user.target
EOF_PATH
  systemctl daemon-reload
  systemctl enable --now "$RKN_HEALTH_TIMER" "$RKN_UFW_PATH" >/dev/null
  log '[OK] RKN self-heal: path watcher + 1-minute health timer включены'
}

main(){
  need_root || return 1
  case "${1:-}" in
    patch-rkn) [[ -n "${2:-}" ]] || { fail 'Нужен путь к rkn-watcher-manager.sh'; return 1; }; patch_rkn_manager "$2" ;;
    patch-selfsteal) [[ -n "${2:-}" ]] || { fail 'Нужен путь к selfsteal-site-manager.sh'; return 1; }; patch_selfsteal_manager "$2" ;;
    restore-hysteria) restore_hysteria_cert_mount ;;
    restore-rkn) restore_rkn_guard ;;
    sync-rkn-watch) sync_rkn_health_watch ;;
    remove-rkn-watch) remove_rkn_health_watch ;;
    *) fail 'Использование: next-runtime-guards.sh patch-rkn FILE | patch-selfsteal FILE | restore-hysteria | restore-rkn | sync-rkn-watch | remove-rkn-watch'; return 1 ;;
  esac
}

main "$@"
