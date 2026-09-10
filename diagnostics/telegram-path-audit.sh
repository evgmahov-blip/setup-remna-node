#!/usr/bin/env bash

# Read-only, secret-safe comparison audit for Telegram connectivity.
# Usage: bash telegram-path-audit.sh BAD_OLD
#        bash telegram-path-audit.sh GOOD_CLEAN
# Does not print process command lines, .env, runtime Xray JSON, tokens or private keys.

LABEL="${1:-NODE}"
APP="/opt/remnanode"

printf '%s\n' '#################### НАЧАЛО ВЫВОДА: TELEGRAM PATH AUDIT ####################'
printf '[LABEL] %s\n' "$LABEL"

echo '[SYSTEM]'
printf 'hostname: '; hostname 2>/dev/null || true
if [ -r /etc/os-release ]; then
  . /etc/os-release
  printf 'os: %s\n' "${PRETTY_NAME:-unknown}"
fi
printf 'kernel: '; uname -r 2>/dev/null || true
printf 'uptime: '; uptime -p 2>/dev/null || true
printf 'date_utc: '; date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true

echo '[REMNANODE]'
if command -v docker >/dev/null 2>&1 && docker inspect remnanode >/dev/null 2>&1; then
  docker inspect remnanode --format 'container_status={{.State.Status}} image_ref={{.Config.Image}} image_id={{.Image}} network_mode={{.HostConfig.NetworkMode}} cap_add={{json .HostConfig.CapAdd}}' 2>/dev/null || true
  IMG_ID="$(docker inspect remnanode --format '{{.Image}}' 2>/dev/null || true)"
  if [ -n "$IMG_ID" ]; then
    docker image inspect "$IMG_ID" --format 'image_created={{.Created}} repo_digests={{json .RepoDigests}}' 2>/dev/null || true
  fi
  printf 'rw_core_version: '
  docker exec remnanode sh -lc '(rw-core version 2>/dev/null || xray version 2>/dev/null || /usr/local/bin/xray version 2>/dev/null || true) | head -n 1' 2>/dev/null || true
else
  echo 'remnanode container: MISSING'
fi
if [ -f "$APP/docker-compose.yml" ]; then
  printf 'compose_sha256: '; sha256sum "$APP/docker-compose.yml" 2>/dev/null | awk '{print $1}' || true
  grep -E '^[[:space:]]*(image:|network_mode:|cap_add:|restart:)' "$APP/docker-compose.yml" 2>/dev/null || true
fi
for F in .node_domain .panel_ip .protocol .transport .selfsteal_site; do
  if [ -s "$APP/$F" ]; then
    printf '%s=' "$F"
    tr -d '\r\n' < "$APP/$F" 2>/dev/null || true
    printf '\n'
  else
    printf '%s=MISSING\n' "$F"
  fi
done

echo '[RELEVANT SERVICES]'
systemctl list-unit-files --no-pager --no-legend 2>/dev/null | grep -Ei 'remna|rkn|xray|telemt|agent|beszel' || true
printf 'containers: '
docker ps --format '{{.Names}}={{.Image}}' 2>/dev/null | grep -Ei 'remna|xray|telemt|agent|beszel' | paste -sd ';' - || true

echo '[ROUTES AND MTU]'
ip -br link 2>/dev/null || true
ip -4 addr show scope global 2>/dev/null | grep -E '^[0-9]+:|inet ' || true
ip -4 route show 2>/dev/null || true
ip -4 rule show 2>/dev/null || true
ip -6 route show 2>/dev/null | head -n 40 || true
ip -6 rule show 2>/dev/null || true
printf 'ip_forward='; sysctl -n net.ipv4.ip_forward 2>/dev/null || true
printf 'rp_filter_all='; sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || true
printf 'tcp_mtu_probing='; sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || true
printf 'ipv6_disabled_all='; sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || true

echo '[DNS]'
sed -n '1,20p' /etc/resolv.conf 2>/dev/null || true
for H in api.telegram.org web.telegram.org pluto.web.telegram.org venus.web.telegram.org aurora.web.telegram.org vesta.web.telegram.org flora.web.telegram.org; do
  IPS="$(getent ahostsv4 "$H" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -)"
  printf '%s -> %s\n' "$H" "${IPS:-NO_IPV4}"
done

echo '[DIRECT TELEGRAM HTTPS FROM HOST]'
for H in api.telegram.org web.telegram.org pluto.web.telegram.org venus.web.telegram.org aurora.web.telegram.org vesta.web.telegram.org flora.web.telegram.org; do
  printf '%s: ' "$H"
  curl -4 -sS -o /dev/null --connect-timeout 4 --max-time 8 -w 'curl_rc=0 http=%{http_code} remote=%{remote_ip} connect=%{time_connect} total=%{time_total}\n' "https://${H}/" 2>/dev/null
  RC=$?
  if [ "$RC" -ne 0 ]; then
    printf 'curl_rc=%s FAILED\n' "$RC"
  fi
done

echo '[TELEGRAM DC TCP 443/5222]'
TG_IPS=""
for H in pluto.web.telegram.org venus.web.telegram.org aurora.web.telegram.org vesta.web.telegram.org flora.web.telegram.org; do
  IP="$(getent ahostsv4 "$H" 2>/dev/null | awk 'NR==1{print $1}')"
  [ -n "$IP" ] || continue
  TG_IPS="${TG_IPS}${TG_IPS:+ }${IP}"
  for P in 443 5222; do
    if timeout 3 bash -c "true > /dev/tcp/${IP}/${P}" 2>/dev/null; then
      printf '%s %s:%s PASS\n' "$H" "$IP" "$P"
    else
      printf '%s %s:%s FAIL\n' "$H" "$IP" "$P"
    fi
  done
done

echo '[ROUTE TO TELEGRAM DCS]'
for IP in $TG_IPS; do
  ip -4 route get "$IP" 2>/dev/null || true
done

echo '[UFW]'
if command -v ufw >/dev/null 2>&1; then
  ufw status verbose 2>/dev/null || true
else
  echo 'ufw: not installed'
fi

echo '[IPTABLES RELEVANT]'
if command -v iptables-save >/dev/null 2>&1; then
  iptables-save 2>/dev/null | grep -Ei '^:INPUT |^:OUTPUT |^:FORWARD |^-A (OUTPUT|FORWARD|DOCKER-USER) |DROP|REJECT|REMNA|RKN|TSPU|GOV|TELEGRAM|149\.154\.|91\.108\.' | head -n 300 || true
fi

echo '[IPTABLES MANGLE]'
iptables -t mangle -S 2>/dev/null | head -n 200 || true

echo '[NFT RELEVANT]'
if command -v nft >/dev/null 2>&1; then
  nft list ruleset 2>/dev/null | grep -Ein -B2 -A2 'hook output|hook forward|drop|reject|remna|rkn|tspu|gov|telegram|149\.154\.|91\.108\.|meta mark|ct mark' | head -n 400 || true
else
  echo 'nft: not installed'
fi

echo '[IPSET TELEGRAM MEMBERSHIP]'
if command -v ipset >/dev/null 2>&1; then
  SETS="$(ipset list -n 2>/dev/null || true)"
  printf 'sets: %s\n' "$(printf '%s\n' "$SETS" | paste -sd, -)"
  HIT=0
  for IP in $TG_IPS; do
    for S in $SETS; do
      if ipset test "$S" "$IP" >/dev/null 2>&1; then
        printf 'MATCH %s in %s\n' "$IP" "$S"
        HIT=1
      fi
    done
  done
  if [ "$HIT" -eq 0 ]; then
    echo 'no resolved Telegram DC IP is present in an ipset'
  fi
else
  echo 'ipset: not installed'
fi

echo '[TRAFFIC CONTROL]'
tc qdisc show 2>/dev/null || true
DEV="$(ip -4 route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); break}}')"
if [ -n "$DEV" ]; then
  printf 'default_dev=%s\n' "$DEV"
  tc class show dev "$DEV" 2>/dev/null || true
  echo 'tc ingress:'
  tc filter show dev "$DEV" ingress 2>/dev/null || true
  echo 'tc egress:'
  tc filter show dev "$DEV" egress 2>/dev/null || true
fi

echo '[LEGACY NETWORK ARTIFACT NAMES]'
find /etc/systemd/system /usr/local/bin /usr/local/sbin -maxdepth 2 \( -iname '*remna*' -o -iname '*rkn*' -o -iname '*tspu*' -o -iname '*telemt*' -o -iname '*xray*' \) -printf '%p\n' 2>/dev/null | sort | head -n 200 || true

echo '[SUMMARY HINT]'
if curl -4 -sS -o /dev/null --connect-timeout 4 --max-time 8 https://web.telegram.org/ 2>/dev/null; then
  echo 'HOST_TELEGRAM_HTTPS=PASS'
else
  echo 'HOST_TELEGRAM_HTTPS=FAIL'
fi
printf '%s\n' '#################### КОНЕЦ ВЫВОДА: TELEGRAM PATH AUDIT ####################'
