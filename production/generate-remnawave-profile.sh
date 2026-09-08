#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
CERTS_DIR="${CERTS_DIR:-$APP_DIR/certs}"
PROFILE_FILE="${PROFILE_FILE:-$APP_DIR/config-profile.json}"
PROFILE_PUBLIC_FILE="${PROFILE_PUBLIC_FILE:-$APP_DIR/config-profile-public.txt}"
REALITY_ENV="${REALITY_ENV:-$APP_DIR/reality.env}"
NODE_DOMAIN_FILE="$APP_DIR/.node_domain"
XHTTP_PORT="${XHTTP_PORT:-443}"
HYSTERIA_PORT="${HYSTERIA_PORT:-443}"
SELFSTEAL_PORT="${SELFSTEAL_PORT:-8443}"
ENABLE_HYSTERIA2="${ENABLE_HYSTERIA2:-ask}"
XRAY_CERT_DIR="/etc/xray/certs"
XRAY_CERT_FILE="$XRAY_CERT_DIR/fullchain.pem"
XRAY_KEY_FILE="$XRAY_CERT_DIR/privkey.pem"

log(){ printf '%s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }

require_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запустите от root"
}

resolve_domain(){
  NODE_DOMAIN="${NODE_DOMAIN:-}"
  if [[ -z "$NODE_DOMAIN" && -r "$NODE_DOMAIN_FILE" ]]; then
    NODE_DOMAIN="$(tr -d '[:space:]' < "$NODE_DOMAIN_FILE")"
  fi
  if [[ -z "$NODE_DOMAIN" ]]; then
    read -r -p "Домен ноды: " NODE_DOMAIN
  fi
  [[ -n "$NODE_DOMAIN" ]] || fail "Домен ноды не определен"
}

gen_path(){
  local a b
  a="$(openssl rand -hex 4)"
  b="$(openssl rand -hex 8)"
  printf '/api/%s/%s.ts\n' "$a" "$b"
}

resolve_path(){
  XHTTP_PATH="${XHTTP_PATH:-}"
  [[ -n "$XHTTP_PATH" ]] || XHTTP_PATH="$(gen_path)"
  [[ "$XHTTP_PATH" == /* ]] || XHTTP_PATH="/$XHTTP_PATH"
  printf '%s' "$XHTTP_PATH" | grep -Eq '^/[A-Za-z0-9._~/-]+$' || fail "Недопустимый XHTTP path"
}

resolve_hysteria(){
  case "$ENABLE_HYSTERIA2" in
    1|yes|YES|true|TRUE|y|Y) ENABLE_HYSTERIA2=1 ;;
    0|no|NO|false|FALSE|n|N) ENABLE_HYSTERIA2=0 ;;
    ask)
      local answer
      printf '\nHysteria2 использует QUIC/UDP и TLS 1.3. В некоторых сетях РФ этот транспорт может фильтроваться.\n'
      read -r -p "Добавить Hysteria2 как дополнительный транспорт на UDP/443? [y/N]: " answer
      case "${answer:-N}" in [Yy]*) ENABLE_HYSTERIA2=1 ;; *) ENABLE_HYSTERIA2=0 ;; esac
      ;;
    *) fail "ENABLE_HYSTERIA2 должен быть 0/1/ask" ;;
  esac
}

find_rw_core(){
  RW_CORE="$(command -v rw-core 2>/dev/null || true)"
  [[ -x "$RW_CORE" ]] && return 0
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'remnanode'; then
    RW_CORE="docker:remnanode"
    return 0
  fi
  fail "rw-core не найден. Сначала должна быть установлена/запущена Remnawave Node"
}

generate_reality_material(){
  if [[ -s "$REALITY_ENV" ]]; then
    # shellcheck disable=SC1090
    . "$REALITY_ENV"
    [[ -n "${REALITY_PRIVATE_KEY:-}" && -n "${REALITY_PUBLIC_KEY:-}" && -n "${REALITY_SHORT_ID:-}" ]] && return 0
  fi

  local raw private public short
  if [[ "$RW_CORE" == docker:* ]]; then
    raw="$(docker exec remnanode /usr/local/bin/rw-core x25519 2>/dev/null)" || fail "Не удалось выполнить rw-core x25519 в контейнере"
  else
    raw="$("$RW_CORE" x25519 2>/dev/null)" || fail "rw-core x25519 завершился ошибкой"
  fi

  private="$(printf '%s\n' "$raw" | sed -nE 's/^[[:space:]]*(PrivateKey|Private key):[[:space:]]*//p' | head -1)"
  public="$(printf '%s\n' "$raw" | sed -nE 's/^[[:space:]]*(Password([[:space:]]*\([^)]*\))?|PublicKey|Public key):[[:space:]]*//p' | head -1)"
  short="$(openssl rand -hex 8)"
  [[ -n "$private" && -n "$public" ]] || fail "Не удалось разобрать вывод rw-core x25519"

  umask 077
  cat > "$REALITY_ENV" <<EOF
REALITY_PRIVATE_KEY=$private
REALITY_PUBLIC_KEY=$public
REALITY_SHORT_ID=$short
REALITY_SERVER_NAME=$NODE_DOMAIN
REALITY_TARGET=127.0.0.1:$SELFSTEAL_PORT
EOF
  chmod 600 "$REALITY_ENV"

  REALITY_PRIVATE_KEY="$private"
  REALITY_PUBLIC_KEY="$public"
  REALITY_SHORT_ID="$short"
  unset raw private public short
}

check_certs_for_hysteria(){
  [[ "$ENABLE_HYSTERIA2" -eq 1 ]] || return 0
  [[ -s "$CERTS_DIR/fullchain.pem" ]] || fail "Для Hysteria2 нет $CERTS_DIR/fullchain.pem"
  [[ -s "$CERTS_DIR/privkey.pem" ]] || fail "Для Hysteria2 нет $CERTS_DIR/privkey.pem"
  openssl x509 -in "$CERTS_DIR/fullchain.pem" -noout >/dev/null 2>&1 || fail "Некорректный fullchain.pem"
  openssl pkey -in "$CERTS_DIR/privkey.pem" -noout >/dev/null 2>&1 || fail "Некорректный privkey.pem"
}

ensure_cert_mount(){
  [[ "$ENABLE_HYSTERIA2" -eq 1 ]] || return 0
  [[ -f "$APP_DIR/docker-compose.yml" ]] || fail "Не найден $APP_DIR/docker-compose.yml"

  local override="$APP_DIR/docker-compose.override.yml"
  if [[ -f "$override" ]]; then
    cp -a "$override" "$override.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  cat > "$override" <<EOF
services:
  remnanode:
    volumes:
      - $CERTS_DIR:$XRAY_CERT_DIR:ro
EOF

  (
    cd "$APP_DIR"
    docker compose config >/dev/null
  ) || fail "docker-compose.override.yml с сертификатами не прошел docker compose config"

  log "Сертификаты Hysteria2 проброшены: $CERTS_DIR -> $XRAY_CERT_DIR:ro"
}

verify_cert_mount(){
  [[ "$ENABLE_HYSTERIA2" -eq 1 ]] || return 0
  command -v docker >/dev/null 2>&1 || fail "Docker не найден"

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    (
      cd "$APP_DIR"
      docker compose up -d remnanode >/dev/null
    ) || fail "Не удалось пересоздать remnanode с cert mount"

    docker exec remnanode test -s "$XRAY_CERT_FILE" || fail "В контейнере нет $XRAY_CERT_FILE"
    docker exec remnanode test -s "$XRAY_KEY_FILE" || fail "В контейнере нет $XRAY_KEY_FILE"
    log "Проверка cert mount в контейнере: OK"
  fi
}

write_profile(){
  local hysteria_block=""
  if [[ "$ENABLE_HYSTERIA2" -eq 1 ]]; then
    hysteria_block=$(cat <<EOF
,
    {
      "tag": "HYSTERIA2_TLS",
      "listen": "0.0.0.0",
      "port": $HYSTERIA_PORT,
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "users": []
      },
      "streamSettings": {
        "method": "hysteria",
        "security": "tls",
        "hysteriaSettings": {
          "version": 2,
          "udpIdleTimeout": 60,
          "masquerade": {
            "type": "proxy",
            "url": "https://127.0.0.1:$SELFSTEAL_PORT",
            "rewriteHost": true,
            "insecure": true
          }
        },
        "tlsSettings": {
          "serverName": "$NODE_DOMAIN",
          "minVersion": "1.3",
          "alpn": ["h3"],
          "certificates": [
            {
              "certificateFile": "$XRAY_CERT_FILE",
              "keyFile": "$XRAY_KEY_FILE"
            }
          ]
        }
      }
    }
EOF
)
  fi

  umask 077
  cat > "$PROFILE_FILE" <<EOF
{
  "log": {"loglevel": "warning"},
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "XHTTP_REALITY",
      "listen": "0.0.0.0",
      "port": $XHTTP_PORT,
      "protocol": "vless",
      "settings": {"clients": [], "decryption": "none"},
      "sniffing": {
        "enabled": true,
        "routeOnly": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "method": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "127.0.0.1:$SELFSTEAL_PORT",
          "xver": 0,
          "serverNames": ["$NODE_DOMAIN"],
          "privateKey": "$REALITY_PRIVATE_KEY",
          "minClientVer": "0.0.0",
          "shortIds": ["$REALITY_SHORT_ID"]
        },
        "xhttpSettings": {
          "mode": "packet-up",
          "path": "$XHTTP_PATH",
          "extra": {
            "mode": "packet-up",
            "path": "$XHTTP_PATH",
            "xmux": {"maxConcurrency": "1"},
            "seqKey": "chunk_id",
            "sessionKey": "auth",
            "sessionIDKey": "auth",
            "scMaxConcurrentPosts": 10,
            "scMinPostsIntervalMs": 5,
            "serverMaxHeaderBytes": 32768
          }
        }
      }
    }$hysteria_block
  ],
  "outbounds": [
    {"tag": "DIRECT", "protocol": "freedom"},
    {"tag": "BLOCK", "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "127.0.0.0/8",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "169.254.0.0/16",
          "224.0.0.0/4",
          "240.0.0.0/4",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "BLOCK"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "BLOCK"
      }
    ]
  }
}
EOF
  chmod 600 "$PROFILE_FILE"
}

write_public_summary(){
  umask 077
  cat > "$PROFILE_PUBLIC_FILE" <<EOF
REMNAWAVE CONFIG PROFILE
========================
Domain: $NODE_DOMAIN

Primary inbound:
  Tag: XHTTP_REALITY
  Public port: 443/TCP
  Transport: XHTTP
  Security: REALITY
  Path: $XHTTP_PATH
  SNI/serverName: $NODE_DOMAIN
  Public key: $REALITY_PUBLIC_KEY
  Short ID: $REALITY_SHORT_ID
  Fingerprint: firefox

Optional Hysteria2: $([[ "$ENABLE_HYSTERIA2" -eq 1 ]] && echo ENABLED || echo DISABLED)
$([[ "$ENABLE_HYSTERIA2" -eq 1 ]] && printf '  Tag: HYSTERIA2_TLS\n  Public port: 443/UDP\n  SNI: %s\n  Host certs: %s\n  Container certs: %s\n' "$NODE_DOMAIN" "$CERTS_DIR" "$XRAY_CERT_DIR")

Full profile with private Reality key:
  $PROFILE_FILE

Show full profile only when needed:
  cat $PROFILE_FILE
EOF
  chmod 600 "$PROFILE_PUBLIC_FILE"
}

configure_firewall(){
  command -v ufw >/dev/null 2>&1 || return 0
  ufw allow 443/tcp comment 'XHTTP Reality' >/dev/null 2>&1 || true
  if [[ "$ENABLE_HYSTERIA2" -eq 1 ]]; then
    ufw allow 443/udp comment 'Hysteria2' >/dev/null 2>&1 || true
  fi
  ufw reload >/dev/null 2>&1 || true
}

show_result(){
  echo
  echo "XHTTP + REALITY profile created: $PROFILE_FILE"
  echo "Public setup summary: $PROFILE_PUBLIC_FILE"
  echo "Primary: $NODE_DOMAIN:443/TCP, path $XHTTP_PATH"
  if [[ "$ENABLE_HYSTERIA2" -eq 1 ]]; then
    echo "Optional: $NODE_DOMAIN:443/UDP Hysteria2"
    echo "Certificates: $CERTS_DIR -> $XRAY_CERT_DIR:ro"
  fi
  echo
  read -r -p "Показать полный Config Profile сейчас? [y/N]: " answer
  case "${answer:-N}" in
    [Yy]*) cat "$PROFILE_FILE" ;;
    *) cat "$PROFILE_PUBLIC_FILE" ;;
  esac
}

main(){
  echo '#################### НАЧАЛО ВЫВОДА: REMNAWAVE PROFILE ####################'
  require_root
  resolve_domain
  resolve_path
  resolve_hysteria
  find_rw_core
  generate_reality_material
  check_certs_for_hysteria
  ensure_cert_mount
  verify_cert_mount
  write_profile
  write_public_summary
  configure_firewall
  show_result
  echo '#################### КОНЕЦ ВЫВОДА: REMNAWAVE PROFILE ####################'
}

main "$@"
