#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
RKN_VENDOR_DIR="${RKN_VENDOR_DIR:-$APP_DIR/vendor/rkn-watcher}"
RKN_UPSTREAM_REPO="Balbuto/RKN-Watcher"
RKN_UPSTREAM_REF="558fc11a0792892927785e162359585d51972a6a"
RKN_RAW_BASE="https://raw.githubusercontent.com/${RKN_UPSTREAM_REPO}/${RKN_UPSTREAM_REF}"
RKN_FILES=(installer.sh rkn-watcher.sh config_tool.py geoip_apply.py SHA256SUMS VERSION)

say(){ printf '%s\n' "$*"; }
err(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || err 'Запусти от root'; }

fetch_upstream(){
  local tmp file
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  for file in "${RKN_FILES[@]}"; do
    curl -fsSL --proto '=https' --connect-timeout 10 --max-time 60 \
      "$RKN_RAW_BASE/$file" -o "$tmp/$file" || err "Не удалось скачать $file"
  done

  (
    cd "$tmp"
    grep -E '  (installer\.sh|rkn-watcher\.sh|config_tool\.py|geoip_apply\.py)$' SHA256SUMS > SHA256SUMS.required
    sha256sum -c SHA256SUMS.required
  ) || err 'Контрольные суммы RKN Watcher не совпали'

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

show_status(){
  echo '#################### НАЧАЛО ВЫВОДА: RKN WATCHER STATUS ####################'
  if command -v rkn-watcher >/dev/null 2>&1; then
    rkn-watcher status || true
  elif [[ -x /opt/rkn-watcher/rkn-watcher.sh ]]; then
    /opt/rkn-watcher/rkn-watcher.sh status || true
  else
    echo 'RKN Watcher: не установлен'
  fi

  if [[ -r "$RKN_VENDOR_DIR/.upstream-ref" ]]; then
    printf 'Pinned upstream: %s\n' "$(cat "$RKN_VENDOR_DIR/.upstream-ref")"
  else
    printf 'Pinned upstream: %s\n' "$RKN_UPSTREAM_REF"
  fi

  systemctl --no-pager --full status rkn-watcher-update.timer 2>/dev/null | sed -n '1,12p' || true
  echo '#################### КОНЕЦ ВЫВОДА: RKN WATCHER STATUS ####################'
}

install_or_update(){
  fetch_upstream
  echo
  echo 'RKN Watcher меняет iptables/ipset. UFW не отключаем и не сбрасываем.'
  echo 'Перед применением внимательно проверь allow/deny IP, страны и FILTER_PORTS.'
  echo
  (
    cd "$RKN_VENDOR_DIR"
    ./installer.sh install
  )
}

run_upstream_menu(){
  fetch_upstream
  (
    cd "$RKN_VENDOR_DIR"
    ./installer.sh menu
  )
}

safe_apply(){
  local panel_ip="" ssh_ip=""
  [[ -r "$APP_DIR/.panel_ip" ]] && panel_ip="$(tr -d '[:space:]' < "$APP_DIR/.panel_ip")"
  ssh_ip="${SSH_CLIENT%% *}"

  echo '#################### НАЧАЛО ВЫВОДА: RKN WATCHER PRECHECK ####################'
  printf 'Panel IP: %s\n' "${panel_ip:-не найден}"
  printf 'Current SSH IP: %s\n' "${ssh_ip:-не найден}"
  printf 'Node control port: %s\n' "$(sed -n 's/^NODE_PORT=//p' "$APP_DIR/.env" 2>/dev/null | head -1 || true)"
  echo
  echo 'Текущая конфигурация RKN Watcher:'
  [[ -r /etc/rkn-watcher/settings.conf ]] && cat /etc/rkn-watcher/settings.conf || true
  [[ -r /etc/rkn-watcher/whitelist.json ]] && cat /etc/rkn-watcher/whitelist.json || true
  [[ -r /etc/rkn-watcher/blacklist.json ]] && cat /etc/rkn-watcher/blacklist.json || true
  echo '#################### КОНЕЦ ВЫВОДА: RKN WATCHER PRECHECK ####################'

  echo
  echo 'Автоматически apply не выполняю: это отдельное подтверждаемое действие.'
  read -r -p 'Применить текущую конфигурацию RKN Watcher? Введите APPLY: ' answer
  [[ "$answer" == 'APPLY' ]] || { say '[INFO] Применение отменено'; return 0; }

  if command -v rkn-watcher >/dev/null 2>&1; then
    rkn-watcher apply
  elif [[ -x /opt/rkn-watcher/rkn-watcher.sh ]]; then
    /opt/rkn-watcher/rkn-watcher.sh apply
  else
    err 'RKN Watcher не установлен'
  fi
}

uninstall_rkn(){
  fetch_upstream
  (
    cd "$RKN_VENDOR_DIR"
    ./installer.sh uninstall
  )
}

main_menu(){
  while true; do
    clear || true
    echo '========================================================'
    echo ' RKN WATCHER — управление защитой от сканеров'
    echo '========================================================'
    echo ' 1) Установить / обновить RKN Watcher'
    echo ' 2) Открыть оригинальное меню RKN Watcher'
    echo ' 3) Статус'
    echo ' 4) Проверить конфиг и вручную APPLY'
    echo ' 5) Полностью удалить RKN Watcher'
    echo ' 0) Назад'
    echo
    read -r -p 'Выбор [0]: ' choice
    case "${choice:-0}" in
      1) install_or_update; read -r -p 'Enter...' _ ;;
      2) run_upstream_menu ;;
      3) show_status; read -r -p 'Enter...' _ ;;
      4) safe_apply; read -r -p 'Enter...' _ ;;
      5) uninstall_rkn; read -r -p 'Enter...' _ ;;
      0) return 0 ;;
      *) say '[WARN] Неверный пункт'; sleep 1 ;;
    esac
  done
}

main(){
  need_root
  case "${1:-menu}" in
    menu) main_menu ;;
    install|update) install_or_update ;;
    status) show_status ;;
    apply) safe_apply ;;
    uninstall) uninstall_rkn ;;
    *) err 'Использование: rkn-watcher-manager.sh [menu|install|update|status|apply|uninstall]' ;;
  esac
}

main "$@"
