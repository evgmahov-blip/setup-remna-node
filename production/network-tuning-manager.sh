#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

CONF="${CONF:-/etc/sysctl.d/99-remnanode.conf}"
LIMITS="${LIMITS:-/etc/security/limits.d/99-remnanode.conf}"
DRY_RUN="${NETWORK_TUNING_DRY_RUN:-0}"

log(){ printf '%s\n' "$*"; }
ok(){ printf '[OK] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }

mem_mib(){
  awk '/^MemTotal:/ {printf "%d\n", $2/1024}' /proc/meminfo
}

choose_profile(){
  local mib="$1"
  if (( mib < 1536 )); then
    printf 'SAFE\n'
  else
    printf 'NORMAL\n'
  fi
}

choose_cc(){
  local available
  modprobe tcp_bbr >/dev/null 2>&1 || true
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if grep -qw bbr <<<"$available"; then
    printf 'bbr\n'
  else
    printf 'cubic\n'
  fi
}

write_config(){
  local profile="$1" cc="$2"
  local somax backlog rmax wmax syn conntrack keepalive fin
  if [[ "$profile" == "SAFE" ]]; then
    somax=4096
    backlog=4096
    rmax=16777216
    wmax=16777216
    syn=4096
    conntrack=65536
    keepalive=600
    fin=30
  else
    somax=16384
    backlog=8192
    rmax=33554432
    wmax=33554432
    syn=8192
    conntrack=262144
    keepalive=300
    fin=20
  fi

  cat > "$CONF" <<EOF
# Managed by REMNANODE NEXT network-tuning-manager.sh
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $cc

fs.file-max = 1048576
vm.swappiness = 10
vm.max_map_count = 262144

net.core.somaxconn = $somax
net.core.netdev_max_backlog = $backlog
net.core.rmem_max = $rmax
net.core.wmem_max = $wmax
net.ipv4.tcp_rmem = 4096 87380 $rmax
net.ipv4.tcp_wmem = 4096 65536 $wmax
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = $fin
net.ipv4.tcp_keepalive_time = $keepalive
net.ipv4.tcp_max_syn_backlog = $syn
net.ipv4.tcp_tw_reuse = 1

net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

net.netfilter.nf_conntrack_max = $conntrack
EOF

  cat > "$LIMITS" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
}

verify_eq(){
  local key="$1" want="$2" got
  got="$(sysctl -n "$key" 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then
    ok "$key=$got"
    return 0
  fi
  warn "$key: ожидали '$want', получили '${got:-<нет>}'"
  return 1
}

show_status(){
  local mib profile
  mib="$(mem_mib)"
  profile="$(choose_profile "$mib")"
  log "RAM: ${mib} MiB"
  log "Profile by RAM: $profile"
  log "qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  log "cc: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  log "available cc: $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo '?')"
  log "rp_filter(all/default): $(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo '?')/$(sysctl -n net.ipv4.conf.default.rp_filter 2>/dev/null || echo '?')"
}

apply_tuning(){
  local mib profile cc rc=0
  mib="$(mem_mib)"
  profile="$(choose_profile "$mib")"
  cc="$(choose_cc)"

  log "RAM: ${mib} MiB"
  log "Профиль: $profile"
  if [[ "$cc" == "bbr" ]]; then
    ok "BBR доступен; делаю fq + bbr профилем по умолчанию"
  else
    warn "BBR недоступен в текущем ядре; fallback на cubic"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN: config=$CONF profile=$profile cc=$cc"
    return 0
  fi

  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Нужны права root"

  install -d -m 0755 "$(dirname "$CONF")" "$(dirname "$LIMITS")"
  [[ -f "$CONF" ]] && cp -a "$CONF" "${CONF}.bak.$(date +%Y%m%d-%H%M%S)" || true

  modprobe tcp_bbr >/dev/null 2>&1 || true
  modprobe nf_conntrack >/dev/null 2>&1 || true
  write_config "$profile" "$cc"

  local apply_log
  apply_log="$(mktemp)"
  if ! sysctl -p "$CONF" >"$apply_log" 2>&1; then
    warn "sysctl сообщил об ошибке:"
    sed 's/^/  /' "$apply_log" >&2
    rc=1
  fi
  rm -f "$apply_log"

  verify_eq net.core.default_qdisc fq || rc=1
  verify_eq net.ipv4.tcp_congestion_control "$cc" || rc=1
  verify_eq net.ipv4.conf.all.rp_filter 2 || rc=1
  verify_eq net.ipv4.conf.default.rp_filter 2 || rc=1
  verify_eq fs.file-max 1048576 || rc=1

  if [[ "$profile" == "SAFE" ]]; then
    verify_eq net.core.rmem_max 16777216 || rc=1
    verify_eq net.core.wmem_max 16777216 || rc=1
  else
    verify_eq net.core.rmem_max 33554432 || rc=1
    verify_eq net.core.wmem_max 33554432 || rc=1
  fi

  if sysctl -n net.netfilter.nf_conntrack_max >/dev/null 2>&1; then
    if [[ "$profile" == "SAFE" ]]; then
      verify_eq net.netfilter.nf_conntrack_max 65536 || rc=1
    else
      verify_eq net.netfilter.nf_conntrack_max 262144 || rc=1
    fi
  else
    warn "nf_conntrack_max пока недоступен; после загрузки nf_conntrack значение применится из $CONF"
  fi

  if (( rc == 0 )); then
    ok "Сетевой профиль применён и проверен"
  else
    warn "Профиль записан, но одна или несколько проверок не прошли"
  fi
  return "$rc"
}

case "${1:-apply}" in
  apply) apply_tuning ;;
  status) show_status ;;
  *) fail "Использование: $0 [apply|status]" ;;
esac
