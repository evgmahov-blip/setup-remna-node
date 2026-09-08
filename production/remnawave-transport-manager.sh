#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
CERTS_DIR="${CERTS_DIR:-$APP_DIR/certs}"
WWW_DIR="${WWW_DIR:-/var/www/html}"
NODE_DOMAIN_FILE="$APP_DIR/.node_domain"
TRANSPORT_FILE="$APP_DIR/.transport"
CAMOUFLAGE_FILE="$APP_DIR/.camouflage_mode"
REALITY_ENV="$APP_DIR/reality.env"
REALITY_SNI_FILE="$APP_DIR/.reality_sni"
REALITY_TARGET_FILE="$APP_DIR/.reality_target"
XHTTP_PATH_FILE="$APP_DIR/.xhttp_path"
SNI_POOL_CACHE="$APP_DIR/reality-targets.cache"
SNI_POOL_REF="${SNI_POOL_REF:-c85e2950ea73f01639aa6243732b3622ed1bdbf5}"
SNI_POOL_SOURCE="${SNI_POOL_SOURCE:-https://raw.githubusercontent.com/evkir/reality-probe/${SNI_POOL_REF}/reality_probe.py}"
PROFILE_DIR="$APP_DIR/remnawave-profiles"
PUBLIC_PORT="${PUBLIC_PORT:-443}"
SELFSTEAL_SOCKET="${SELFSTEAL_SOCKET:-/dev/shm/nginx.sock}"

mkdir -p "$APP_DIR" "$PROFILE_DIR"

log(){ printf '%s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }

node_domain(){
  local d="${NODE_DOMAIN:-}"
  [[ -z "$d" && -r "$NODE_DOMAIN_FILE" ]] && d="$(tr -d '[:space:]' < "$NODE_DOMAIN_FILE")"
  [[ -n "$d" ]] || fail "Не найден домен ноды. Сначала выполни штатную установку ноды."
  printf '%s' "$d"
}

xray_cmd(){
  if command -v xray >/dev/null 2>&1; then
    xray "$@"
  elif command -v rw-core >/dev/null 2>&1; then
    rw-core "$@"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    if docker exec remnanode test -x /usr/local/bin/rw-core 2>/dev/null; then
      docker exec remnanode /usr/local/bin/rw-core "$@"
    else
      docker exec remnanode /usr/local/bin/xray "$@"
    fi
  else
    fail "Xray/rw-core не найден"
  fi
}

refresh_sni_pool(){
  local tmp count
  tmp="$(mktemp)"
  if curl -fsSL --proto '=https' --connect-timeout 8 --max-time 20 "$SNI_POOL_SOURCE" -o "$tmp"; then
    awk '
      /BUILTIN_DOMAINS[[:space:]]*=/ {inside=1; next}
      inside && /^]/ {exit}
      inside {
        while (match($0, /[\047\"][A-Za-z0-9.-]+\.[A-Za-z]{2,}[\047\"]/)) {
          s=substr($0,RSTART+1,RLENGTH-2); print s; $0=substr($0,RSTART+RLENGTH)
        }
      }
    ' "$tmp" | awk '!seen[$0]++' > "$tmp.pool"
    count="$(wc -l < "$tmp.pool" | tr -d ' ')"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count >= 20 )); then
      install -m 0600 "$tmp.pool" "$SNI_POOL_CACHE"
      log "[OK] SNI pool обновлен: $count доменов (pinned $SNI_POOL_REF)"
      rm -f "$tmp" "$tmp.pool"
      return 0
    fi
  fi
  rm -f "$tmp" "$tmp.pool" 2>/dev/null || true
  [[ -s "$SNI_POOL_CACHE" ]] && { log "[WARN] Не удалось обновить SNI pool, используется кэш"; return 0; }
  cat > "$SNI_POOL_CACHE" <<'EOF'
www.microsoft.com
www.apple.com
www.amazon.com
www.samsung.com
www.yahoo.com
www.bing.com
www.cloudflare.com
EOF
  chmod 600 "$SNI_POOL_CACHE"
  log "[WARN] Используется встроенный резервный SNI pool"
}

check_sni(){
  local sni="$1"
  [[ -n "$sni" ]] || return 1
  [[ "$sni" != "$(node_domain)" ]] || return 1
  timeout 8 openssl s_client -connect "$sni:443" -servername "$sni" -tls1_3 -alpn h2 </dev/null 2>/dev/null |
    openssl x509 -noout -checkhost "$sni" >/dev/null 2>&1
}

select_external_sni(){
  local current="" sni choice="${SNI_MODE:-}"
  [[ -r "$REALITY_SNI_FILE" ]] && current="$(tr -d '[:space:]' < "$REALITY_SNI_FILE")"

  if [[ -z "$choice" ]]; then
    echo
    echo 'ВНЕШНИЙ REALITY SNI:'
    [[ -n "$current" ]] && echo "  Текущий: $current"
    echo '  1) Оставить текущий'
    echo '  2) Выбрать автоматически из проверяемого списка'
    echo '  3) Указать вручную'
    echo '  4) Только обновить список SNI (текущий НЕ менять)'
    read -r -p 'Выбор [1]: ' choice
    choice="${choice:-1}"
  fi

  case "$choice" in
    1|keep)
      if [[ -z "$current" || "$current" == "$(node_domain)" ]]; then
        choice="2"
      fi
      ;;
  esac

  case "$choice" in
    2|auto)
      refresh_sni_pool
      current=""
      while IFS= read -r sni; do
        [[ -n "$sni" ]] || continue
        if check_sni "$sni"; then
          current="$sni"
          break
        fi
      done < <(shuf "$SNI_POOL_CACHE")
      [[ -n "$current" ]] || fail "Не найден рабочий SNI"
      ;;
    3|manual)
      sni="${REALITY_SNI_INPUT:-}"
      [[ -n "$sni" ]] || read -r -p 'SNI: ' sni
      check_sni "$sni" || fail "SNI не прошёл TLS1.3/cert проверку: $sni"
      current="$sni"
      ;;
    4|refresh)
      refresh_sni_pool
      [[ -n "$current" && "$current" != "$(node_domain)" ]] || fail "Текущий внешний SNI ещё не задан"
      ;;
    1|keep) ;;
    *) fail "Неизвестный выбор SNI" ;;
  esac

  REALITY_SNI="$current"
  REALITY_TARGET="$current:443"
  REALITY_XVER=0
  CAMOUFLAGE_MODE="external"
  printf '%s\n' "$REALITY_SNI" > "$REALITY_SNI_FILE"
  printf '%s\n' "$REALITY_TARGET" > "$REALITY_TARGET_FILE"
  printf '%s\n' "$CAMOUFLAGE_MODE" > "$CAMOUFLAGE_FILE"
  chmod 600 "$REALITY_SNI_FILE" "$REALITY_TARGET_FILE" "$CAMOUFLAGE_FILE"
}

select_camouflage(){
  local mode="${CAMOUFLAGE_MODE:-}"
  if [[ -z "$mode" ]]; then
    echo
    echo 'Маскировка REALITY:'
    echo '  1) SelfSteal — старая рабочая архитектура: Xray :443 -> /dev/shm/nginx.sock'
    echo '  2) Внешний SNI — target крупного HTTPS-сайта из проверяемого пула'
    read -r -p 'Выбор [1]: ' c
    case "${c:-1}" in 1) mode=selfsteal ;; 2) mode=external ;; *) fail "Неверный режим маскировки" ;; esac
  fi

  case "$mode" in
    selfsteal)
      [[ -s "$CERTS_DIR/fullchain.pem" && -s "$CERTS_DIR/privkey.pem" ]] || fail "SelfSteal требует SSL сертификат ноды в $CERTS_DIR"
      REALITY_SNI="$(node_domain)"
      REALITY_TARGET="$SELFSTEAL_SOCKET"
      REALITY_XVER=1
      CAMOUFLAGE_MODE="selfsteal"
      printf '%s\n' "$REALITY_SNI" > "$REALITY_SNI_FILE"
      printf '%s\n' "$REALITY_TARGET" > "$REALITY_TARGET_FILE"
      printf '%s\n' "$CAMOUFLAGE_MODE" > "$CAMOUFLAGE_FILE"
      chmod 600 "$REALITY_SNI_FILE" "$REALITY_TARGET_FILE" "$CAMOUFLAGE_FILE"
      log "[OK] SelfSteal: SNI=$REALITY_SNI target=$REALITY_TARGET xver=$REALITY_XVER"
      ;;
    external)
      select_external_sni
      ;;
    *) fail "CAMOUFLAGE_MODE должен быть selfsteal или external" ;;
  esac
}

generate_reality_keys(){
  local private="" public="" short="" raw
  if [[ -s "$REALITY_ENV" ]]; then
    private="$(sed -n 's/^REALITY_PRIVATE_KEY=//p' "$REALITY_ENV" | head -1)"
    public="$(sed -n 's/^REALITY_PUBLIC_KEY=//p' "$REALITY_ENV" | head -1)"
    short="$(sed -n 's/^REALITY_SHORT_ID=//p' "$REALITY_ENV" | head -1)"
  fi

  if [[ -z "$private" || -z "$public" || -z "$short" ]]; then
    raw="$(xray_cmd x25519 2>/dev/null)" || fail "Не удалось сгенерировать REALITY keypair"
    private="$(printf '%s\n' "$raw" | sed -nE 's/^[[:space:]]*(PrivateKey|Private key):[[:space:]]*//p' | head -1)"
    public="$(printf '%s\n' "$raw" | sed -nE 's/^[[:space:]]*(Password([[:space:]]*\([^)]*\))?|PublicKey|Public key):[[:space:]]*//p' | head -1)"
    short="$(openssl rand -hex 8)"
  fi

  [[ -n "$private" && -n "$public" && -n "$short" ]] || fail "REALITY keys не определены"
  REALITY_PRIVATE_KEY="$private"
  REALITY_PUBLIC_KEY="$public"
  REALITY_SHORT_ID="$short"

  umask 077
  cat > "$REALITY_ENV" <<EOF
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
REALITY_SHORT_ID=$REALITY_SHORT_ID
REALITY_SERVER_NAME=$REALITY_SNI
REALITY_TARGET=$REALITY_TARGET
REALITY_XVER=$REALITY_XVER
CAMOUFLAGE_MODE=$CAMOUFLAGE_MODE
EOF
}

resolve_xhttp_path(){
  local p=""
  [[ -r "$XHTTP_PATH_FILE" ]] && p="$(tr -d '[:space:]' < "$XHTTP_PATH_FILE")"
  if [[ -z "$p" ]]; then
    p="/api/$(openssl rand -hex 4)/$(openssl rand -hex 8).ts"
    printf '%s\n' "$p" > "$XHTTP_PATH_FILE"
    chmod 600 "$XHTTP_PATH_FILE"
  fi
  XHTTP_PATH="$p"
}

base_profile_prefix(){
  cat <<'EOF'
{
  "log": {"loglevel": "warning"},
  "stats": {},
  "policy": {
    "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}},
    "system": {"statsInboundUplink": true, "statsInboundDownlink": true}
  },
  "inbounds": [
EOF
}

profile_suffix(){
  cat <<'EOF'
  ],
  "outbounds": [
    {"tag": "DIRECT", "protocol": "freedom"},
    {"tag": "BLOCK", "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK"}
    ]
  }
}
EOF
}

atomic_profile_install(){
  local tmp="$1" dst="$2"
  jq empty "$tmp" || { rm -f "$tmp"; fail "Сгенерирован некорректный JSON: $dst"; }
  install -m 600 "$tmp" "$dst"
  rm -f "$tmp"
}

write_xhttp_profile(){
  local f="$PROFILE_DIR/xhttp-reality.json" tmp
  resolve_xhttp_path
  tmp="$(mktemp "$PROFILE_DIR/.xhttp-reality.XXXXXX")"
  {
    base_profile_prefix
    cat <<EOF
    {
      "tag": "XHTTP_REALITY",
      "listen": "0.0.0.0",
      "port": $PUBLIC_PORT,
      "protocol": "vless",
      "settings": {"clients": [], "decryption": "none"},
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$REALITY_TARGET",
          "xver": $REALITY_XVER,
          "serverNames": ["$REALITY_SNI"],
          "privateKey": "$REALITY_PRIVATE_KEY",
          "shortIds": ["$REALITY_SHORT_ID"]
        },
        "xhttpSettings": {
          "mode": "packet-up",
          "path": "$XHTTP_PATH"
        }
      }
    }
EOF
    profile_suffix
  } > "$tmp"
  atomic_profile_install "$tmp" "$f"
}

write_raw_profile(){
  local f="$PROFILE_DIR/raw-reality.json" tmp
  tmp="$(mktemp "$PROFILE_DIR/.raw-reality.XXXXXX")"
  {
    base_profile_prefix
    cat <<EOF
    {
      "tag": "RAW_REALITY",
      "listen": "0.0.0.0",
      "port": $PUBLIC_PORT,
      "protocol": "vless",
      "settings": {"clients": [], "decryption": "none"},
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$REALITY_TARGET",
          "xver": $REALITY_XVER,
          "serverNames": ["$REALITY_SNI"],
          "privateKey": "$REALITY_PRIVATE_KEY",
          "shortIds": ["$REALITY_SHORT_ID"]
        },
        "rawSettings": {"header": {"type": "none"}}
      }
    }
EOF
    profile_suffix
  } > "$tmp"
  atomic_profile_install "$tmp" "$f"
}

hysteria_masquerade_json(){
  if [[ -s "$WWW_DIR/index.html" ]]; then
    jq -Rs '{type:"string",content:.,headers:{"content-type":"text/html; charset=utf-8"},statusCode:200}' < "$WWW_DIR/index.html"
  else
    printf '%s\n' '{"type":"string","content":"<!doctype html><html><body><h1>Welcome</h1></body></html>","headers":{"content-type":"text/html; charset=utf-8"},"statusCode":200}'
  fi
}

write_hysteria_profile(){
  local f="$PROFILE_DIR/hysteria2-tls.json" masq tmp
  [[ -s "$CERTS_DIR/fullchain.pem" && -s "$CERTS_DIR/privkey.pem" ]] || fail "Для Hysteria2 нужны $CERTS_DIR/fullchain.pem и privkey.pem"
  masq="$(hysteria_masquerade_json)"
  tmp="$(mktemp "$PROFILE_DIR/.hysteria2-tls.XXXXXX")"
  {
    base_profile_prefix
    cat <<EOF
    {
      "tag": "HYSTERIA2_TLS",
      "listen": "0.0.0.0",
      "port": $PUBLIC_PORT,
      "protocol": "hysteria",
      "settings": {"version": 2, "users": []},
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "hysteriaSettings": {
          "version": 2,
          "udpIdleTimeout": 60,
          "masquerade": $masq
        },
        "tlsSettings": {
          "serverName": "$(node_domain)",
          "minVersion": "1.3",
          "alpn": ["h3"],
          "certificates": [
            {"certificateFile": "/etc/xray/certs/fullchain.pem", "keyFile": "/etc/xray/certs/privkey.pem"}
          ]
        }
      }
    }
EOF
    profile_suffix
  } > "$tmp"
  atomic_profile_install "$tmp" "$f"
}

write_host_values(){
  local transport="$1" d
  d="$(node_domain)"
  case "$transport" in
    xhttp)
      cat > "$PROFILE_DIR/host-xhttp.txt" <<EOF
Remark: XHTTP-REALITY
Inbound: XHTTP_REALITY
Address: $d
Port: $PUBLIC_PORT
Security Layer: DEFAULT
SNI: $REALITY_SNI
Fingerprint: firefox
Host: пусто
Path: $XHTTP_PATH
Flow: пусто
Public key: $REALITY_PUBLIC_KEY
Short ID: $REALITY_SHORT_ID
Camouflage: $CAMOUFLAGE_MODE
Reality target: $REALITY_TARGET
EOF
      ;;
    raw)
      cat > "$PROFILE_DIR/host-raw.txt" <<EOF
Remark: RAW-REALITY
Inbound: RAW_REALITY
Address: $d
Port: $PUBLIC_PORT
Security Layer: DEFAULT
SNI: $REALITY_SNI
Fingerprint: firefox
Host: пусто
Path: пусто
Flow: пусто
Public key: $REALITY_PUBLIC_KEY
Short ID: $REALITY_SHORT_ID
Camouflage: $CAMOUFLAGE_MODE
Reality target: $REALITY_TARGET
EOF
      ;;
    hysteria)
      cat > "$PROFILE_DIR/host-hysteria2.txt" <<EOF
Remark: HYSTERIA2-TLS
Inbound: HYSTERIA2_TLS
Address: $d
Port: $PUBLIC_PORT/UDP
Security Layer: DEFAULT
SNI: $d
ALPN: h3
Masquerade: встроенная копия текущего SelfSteal index.html
EOF
      ;;
  esac
  chmod 600 "$PROFILE_DIR"/host-*.txt 2>/dev/null || true
}

generate_transport(){
  local transport="$1"
  case "$transport" in
    xhttp)
      select_camouflage
      generate_reality_keys
      write_xhttp_profile
      write_host_values xhttp
      ;;
    raw)
      select_camouflage
      generate_reality_keys
      write_raw_profile
      write_host_values raw
      ;;
    hysteria)
      write_hysteria_profile
      write_host_values hysteria
      ;;
    *) fail "Допустимо: xhttp | raw | hysteria" ;;
  esac
  printf '%s\n' "$transport" > "$TRANSPORT_FILE"
  chmod 600 "$TRANSPORT_FILE"
}

show_result(){
  local transport="$1" profile host
  case "$transport" in
    xhttp) profile="$PROFILE_DIR/xhttp-reality.json"; host="$PROFILE_DIR/host-xhttp.txt" ;;
    raw) profile="$PROFILE_DIR/raw-reality.json"; host="$PROFILE_DIR/host-raw.txt" ;;
    hysteria) profile="$PROFILE_DIR/hysteria2-tls.json"; host="$PROFILE_DIR/host-hysteria2.txt" ;;
  esac
  echo '#################### НАЧАЛО ВЫВОДА: REMNAWAVE TRANSPORT PROFILE ####################'
  echo "Transport: $transport"
  echo "Profile:   $profile"
  echo "Host:      $host"
  echo
  cat "$profile"
  echo
  cat "$host"
  echo '#################### КОНЕЦ ВЫВОДА: REMNAWAVE TRANSPORT PROFILE ####################'
}

main(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти от root"
  local transport="${1:-}"
  if [[ -z "$transport" ]]; then
    echo 'Выбери транспорт:'
    echo '  1) VLESS + REALITY + XHTTP'
    echo '  2) VLESS + REALITY + RAW'
    echo '  3) Hysteria2 + TLS'
    read -r -p 'Выбор [1]: ' c
    case "${c:-1}" in 1) transport=xhttp ;; 2) transport=raw ;; 3) transport=hysteria ;; *) fail "Неверный выбор" ;; esac
  fi
  generate_transport "$transport"
  show_result "$transport"
}

main "$@"
