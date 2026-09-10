#!/usr/bin/env bash
set -Eeuo pipefail

TASK_NAME="REMNA NODE FULL CLEAN + NEXT"
APP_DIR="/opt/remnanode"
OLD_SCRIPTS_DIR="/opt/remna-node-scripts"
BACKUP_ROOT="/root/remna-node-clean-backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
MODE="${1:-menu}"
ASSUME_YES="${ASSUME_YES:-0}"
NEXT_REF="${NEXT_REF:-05277579a829a977e2db103d95779f0c4d1a4b4c}"
NEXT_URL="https://raw.githubusercontent.com/evgmahov-blip/setup-remna-node/${NEXT_REF}/setup_node_next.sh"
NEXT_DST="/root/setup_node_next-${NEXT_REF:0:12}.sh"

printf '#################### НАЧАЛО ВЫВОДА: %s ####################\n' "$TASK_NAME"
finish(){ rc=$?; printf '#################### КОНЕЦ ВЫВОДА: %s ####################\n' "$TASK_NAME"; return "$rc"; }
trap finish EXIT

ok(){ printf '[OK] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }
quiet(){ "$@" >/dev/null 2>&1 || true; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { die 'Запусти от root.'; exit 1; }
TTY=/dev/tty; { [[ -r "$TTY" && -w "$TTY" ]]; } || TTY=/dev/stdin

ssh_unit(){
  systemctl list-unit-files ssh.service >/dev/null 2>&1 && { echo ssh; return; }
  systemctl list-unit-files sshd.service >/dev/null 2>&1 && { echo sshd; return; }
  echo ''
}

ssh_ok(){
  local u; u="$(ssh_unit)"
  [[ -n "$u" ]] || return 1
  systemctl is-active --quiet "$u" || return 1
  ss -lntp 2>/dev/null | grep -q 'sshd'
}

precheck(){
  command -v ss >/dev/null 2>&1 || die 'Не найден ss.'
  command -v tar >/dev/null 2>&1 || die 'Не найден tar.'
  ssh_ok || die 'SSH/sshd не в рабочем состоянии. Очистку не начинаю.'
  ip route show default 2>/dev/null | grep -q '^default ' || die 'Нет default route. Очистку не начинаю.'
  ok 'Precheck PASS: SSH активен, sshd слушает, default route есть.'
}

copy_if_exists(){
  local src="$1" rel
  [[ -e "$src" ]] || return 0
  rel="${src#/}"
  mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
  cp -a "$src" "$BACKUP_DIR/$rel" 2>/dev/null || warn "Не удалось сохранить $src"
}

backup_state(){
  umask 077
  mkdir -p "$BACKUP_DIR/state"
  for p in \
    /opt/remnanode \
    /opt/remna-protection \
    /var/log/remna-protection \
    /var/www/mstream \
    /etc/caddy/Caddyfile \
    /etc/caddy/Caddyfile.public \
    /etc/caddy/Caddyfile.reality \
    /etc/systemd/system/caddy.service.d/10-remna-topology-guard.conf \
    /etc/hysteria \
    /etc/hysteria2; do copy_if_exists "$p"; done

  systemctl list-unit-files --no-pager >"$BACKUP_DIR/state/systemd-unit-files.txt" 2>&1 || true
  ss -lntup >"$BACKUP_DIR/state/listening-ports.txt" 2>&1 || true
  ip addr show >"$BACKUP_DIR/state/ip-address.txt" 2>&1 || true
  ip route show table all >"$BACKUP_DIR/state/ip-routes.txt" 2>&1 || true
  command -v docker >/dev/null 2>&1 && docker ps -a --no-trunc >"$BACKUP_DIR/state/docker-ps.txt" 2>&1 || true
  command -v iptables-save >/dev/null 2>&1 && iptables-save >"$BACKUP_DIR/state/iptables-save.txt" 2>&1 || true
  command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save >"$BACKUP_DIR/state/ip6tables-save.txt" 2>&1 || true
  command -v ipset >/dev/null 2>&1 && ipset save >"$BACKUP_DIR/state/ipset-save.txt" 2>&1 || true
  command -v ufw >/dev/null 2>&1 && ufw status numbered >"$BACKUP_DIR/state/ufw-status.txt" 2>&1 || true

  tar -C "$BACKUP_ROOT" -czf "$BACKUP_ROOT/remna-node-clean-$STAMP.tar.gz" "$STAMP" 2>/dev/null || true
  chmod -R go-rwx "$BACKUP_DIR" "$BACKUP_ROOT/remna-node-clean-$STAMP.tar.gz" 2>/dev/null || true
  ok "Recovery bundle: $BACKUP_DIR"
}

remove_unit(){
  local u="$1"
  quiet systemctl disable --now "$u"
  rm -f "/etc/systemd/system/$u"
}

clean_units(){
  local u
  for u in \
    remna-profile-wait.service \
    remna-reality-handoff.service remna-reality-handoff.timer \
    remna-protection.service remna-protection-update.service remna-protection-update.timer \
    remnanode-rkn-scanner-boot.service remnanode-rkn-scanner-update.service remnanode-rkn-scanner-update.timer \
    remnanode-rkn-scanner-health.service remnanode-rkn-scanner-health.timer \
    remnanode-rkn-scanner-ufw.path remnanode-rkn-scanner-watch.path \
    remnanode-rkn-watcher.service remnanode-rkn-watcher.timer \
    remna-rkn-watcher.service remna-rkn-watcher.timer \
    hysteria-server.service hysteria2.service; do remove_unit "$u"; done

  rm -f /etc/systemd/system/caddy.service.d/10-remna-topology-guard.conf
  rmdir /etc/systemd/system/caddy.service.d 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
  ok 'Remna/RKN/Hysteria systemd units и старый Caddy topology drop-in удалены.'
}

clean_firewall(){
  local parent setname
  if command -v iptables >/dev/null 2>&1; then
    for parent in INPUT FORWARD OUTPUT; do
      while iptables -C "$parent" -j REMNA_GUARD >/dev/null 2>&1; do iptables -D "$parent" -j REMNA_GUARD || break; done
      while iptables -C "$parent" -j REMNA_RKN_SCANNERS >/dev/null 2>&1; do iptables -D "$parent" -j REMNA_RKN_SCANNERS || break; done
      while iptables -C "$parent" -j TSPUIPS >/dev/null 2>&1; do iptables -D "$parent" -j TSPUIPS || break; done
    done
    for setname in REMNA_GUARD REMNA_RKN_SCANNERS TSPUIPS; do
      iptables -F "$setname" >/dev/null 2>&1 || true
      iptables -X "$setname" >/dev/null 2>&1 || true
    done
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    for parent in INPUT FORWARD OUTPUT; do
      while ip6tables -C "$parent" -j REMNA_GUARD6 >/dev/null 2>&1; do ip6tables -D "$parent" -j REMNA_GUARD6 || break; done
    done
    ip6tables -F REMNA_GUARD6 >/dev/null 2>&1 || true
    ip6tables -X REMNA_GUARD6 >/dev/null 2>&1 || true
  fi
  if command -v ipset >/dev/null 2>&1; then
    for setname in REMNA_TSPU REMNA_GOV REMNA_ALLOW REMNA_DENY REMNA_COUNTRY_ALLOW TSPUIPS; do
      ipset destroy "$setname" >/dev/null 2>&1 || true
    done
  fi
  ok 'Remna/RKN firewall-объекты удалены адресно; iptables/UFW глобально НЕ сбрасывались.'
}

clean_runtime(){
  quiet systemctl stop caddy
  if command -v docker >/dev/null 2>&1; then
    if [[ -f /opt/remnanode/docker-compose.yml ]]; then
      (cd /opt/remnanode && docker compose down --remove-orphans) >/dev/null 2>&1 || true
    fi
    docker rm -f remnanode remnawave-nginx >/dev/null 2>&1 || true
  fi
  rm -rf /opt/remnanode /opt/remna-protection /var/log/remna-protection /var/www/mstream /etc/hysteria /etc/hysteria2 /opt/remna-hysteria
  rm -f /etc/caddy/Caddyfile /etc/caddy/Caddyfile.public /etc/caddy/Caddyfile.reality
  rm -f /usr/local/bin/remnanode /usr/local/bin/remnanode-next
  rm -rf /usr/local/lib/remnanode-next
  rm -f "$OLD_SCRIPTS_DIR/caddy-resilient-start.sh" "$OLD_SCRIPTS_DIR/rkn-watcher.sh" "$OLD_SCRIPTS_DIR/rkn-scanner.sh" "$OLD_SCRIPTS_DIR/remnanode-rkn-scanner.sh" "$OLD_SCRIPTS_DIR/remna-rkn-watcher.sh"
  ok 'Старый node runtime очищен. Docker как пакет и чужие контейнеры не тронуты.'
}

postcheck(){
  local fail=0
  ssh_ok || { warn 'SSH/sshd не прошёл postcheck.'; fail=1; }
  ip route show default 2>/dev/null | grep -q '^default ' || { warn 'Default route отсутствует после clean.'; fail=1; }
  if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Eq '^(remnanode|remnawave-nginx)$'; then
    warn 'Старый контейнер node stack ещё существует.'; fail=1
  fi
  if ss -lntup 2>/dev/null | grep -E ':(80|443|2222|7443|8443|18443)\b' | grep -Ei 'caddy|rw-core|xray|hysteria|nginx'; then
    warn 'Старый node stack всё ещё занимает рабочие порты.'; fail=1
  fi
  if find /etc/systemd/system -maxdepth 2 -type f \( -iname '*remna*rkn*' -o -name '10-remna-topology-guard.conf' \) -print -quit 2>/dev/null | grep -q .; then
    warn 'Остались старые RKN/Caddy systemd-файлы.'; fail=1
  fi
  [[ "$fail" -eq 0 ]] || { warn "POSTCHECK FAIL. Новую установку не запускаю. Recovery: $BACKUP_DIR"; return 1; }
  ok 'POSTCHECK PASS: SSH/сеть сохранены, старый node stack удалён, рабочие порты свободны.'
}

confirm_clean(){
  [[ "$ASSUME_YES" == 1 ]] && return 0
  printf '%s\n' 'Будет удалён старый Remnanode/RKN/Caddy/Hysteria node stack.'
  printf '%s\n' 'SSH, сеть, hostname, DNS, Docker-пакет и чужие контейнеры не удаляются.'
  printf 'Для продолжения введи CLEAN: '
  local a=''; read -r a <"$TTY" || true
  [[ "$a" == CLEAN ]] || die 'Отменено.'
}

full_clean(){
  precheck
  confirm_clean
  backup_state
  clean_units
  clean_firewall
  clean_runtime
  postcheck
}

install_next(){
  command -v curl >/dev/null 2>&1 || { apt-get update -y && apt-get install -y curl ca-certificates; }
  local tmp; tmp="$(mktemp)"
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 3 "$NEXT_URL" -o "$tmp" || { rm -f "$tmp"; die 'Не удалось скачать NEXT installer.'; return 1; }
  bash -n "$tmp" || { rm -f "$tmp"; die 'NEXT installer не прошёл bash -n.'; return 1; }
  install -o root -g root -m 0755 "$tmp" "$NEXT_DST"
  rm -f "$tmp"
  ok "NEXT installer закреплён на commit $NEXT_REF"
  ok "Запускаю: $NEXT_DST"
  bash "$NEXT_DST"
}

menu(){
  printf '%s\n' '[1] Только FULL CLEAN'
  printf '%s\n' '[2] FULL CLEAN -> актуальный NEXT installer'
  printf '%s\n' '[3] Только актуальный NEXT installer (для уже очищенной ноды)'
  printf '%s\n' '[0] Отмена'
  printf 'Выбор: '
  local c=''; read -r c <"$TTY" || true
  case "$c" in
    1) full_clean ;;
    2) full_clean && install_next ;;
    3) precheck && install_next ;;
    0|'') die 'Отменено.' ;;
    *) die "Неизвестный пункт: $c" ;;
  esac
}

case "$MODE" in
  clean) full_clean ;;
  reinstall|full-reinstall) full_clean && install_next ;;
  install|install-next) precheck && install_next ;;
  menu|'') menu ;;
  *) die "Использование: $0 [clean|reinstall|install]" ;;
esac
