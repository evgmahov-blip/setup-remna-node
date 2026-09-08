#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
CERTS_DIR="${CERTS_DIR:-$APP_DIR/certs}"
PROFILE_FILE="${PROFILE_FILE:-$APP_DIR/config-profile.json}"
PROFILE_PUBLIC_FILE="${PROFILE_PUBLIC_FILE:-$APP_DIR/config-profile-public.txt}"
READY_FILE="${READY_FILE:-$APP_DIR/remnawave-ready.txt}"
EXTERNAL_SNIPPET_FILE="${EXTERNAL_SNIPPET_FILE:-$APP_DIR/external-json-inject-snippet.json}"
MAPPER_FILE="${MAPPER_FILE:-$APP_DIR/remnawave-host-mapper.json}"
REALITY_ENV="${REALITY_ENV:-$APP_DIR/reality.env}"
NODE_DOMAIN_FILE="$APP_DIR/.node_domain"
XHTTP_PATH_FILE="$APP_DIR/.xhttp_path"
HYSTERIA_STATE_FILE="$APP_DIR/.hysteria2-enabled"
REALITY_SNI_FILE="$APP_DIR/.reality_sni"
REALITY_TARGET_FILE="$APP_DIR/.reality_target"
PUBLIC_TCP_PORT="${PUBLIC_TCP_PORT:-443}"
XRAY_TCP_PORT="${XRAY_TCP_PORT:-10443}"
HYSTERIA_PORT="${HYSTERIA_PORT:-443}"
SELFSTEAL_PORT="${SELFSTEAL_PORT:-8443}"
ENABLE_HYSTERIA2="${ENABLE_HYSTERIA2:-ask}"
XRAY_CERT_DIR="/etc/xray/certs"
XRAY_CERT_FILE="$XRAY_CERT_DIR/fullchain.pem"
XRAY_KEY_FILE="$XRAY_CERT_DIR/privkey.pem"

log(){ printf '%s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запустите от root"; }

resolve_domain(){
  NODE_DOMAIN="${NODE_DOMAIN:-}"
  [[ -z "$NODE_DOMAIN" && -r "$NODE_DOMAIN_FILE" ]] && NODE_DOMAIN="$(tr -d '[:space:]' < "$NODE_DOMAIN_FILE")"
  [[ -n "$NODE_DOMAIN" ]] || read -r -p "Домен ноды: " NODE_DOMAIN
  [[ -n "$NODE_DOMAIN" ]] || fail "Домен ноды не определен"
  local first
  first="${NODE_DOMAIN%%.*}"
  HOST_REMARK="${HOST_REMARK:-${first^^}-XHTTP}"
}

resolve_reality_route(){
  REALITY_SNI="${REALITY_SNI:-}"
  REALITY_TARGET="${REALITY_TARGET:-}"
  [[ -z "$REALITY_SNI" && -r "$REALITY_SNI_FILE" ]] && REALITY_SNI="$(tr -d '[:space:]' < "$REALITY_SNI_FILE")"
  [[ -z "$REALITY_TARGET" && -r "$REALITY_TARGET_FILE" ]] && REALITY_TARGET="$(tr -d '[:space:]' < "$REALITY_TARGET_FILE")"
  [[ -n "$REALITY_SNI" && -n "$REALITY_TARGET" ]] || fail "REALITY camouflage route еще не создан. Сначала настрой SelfSteal frontend."
  [[ "$REALITY_TARGET" == "${REALITY_SNI}:443" ]] || fail "Неконсистентный REALITY route: target должен быть ${REALITY_SNI}:443"
  [[ "$REALITY_SNI" != "$NODE_DOMAIN" ]] || fail "REALITY camouflage SNI не должен совпадать с доменом SelfSteal"
}

gen_path(){ printf '/api/%s/%s.ts\n' "$(openssl rand -hex 4)" "$(openssl rand -hex 8)"; }

resolve_path(){
  XHTTP_PATH="${XHTTP_PATH:-}"
  [[ -z "$XHTTP_PATH" && -r "$XHTTP_PATH_FILE" ]] && XHTTP_PATH="$(tr -d '\r\n\t ' < "$XHTTP_PATH_FILE")"
  [[ -n "$XHTTP_PATH" ]] || XHTTP_PATH="$(gen_path)"
  [[ "$XHTTP_PATH" == /* ]] || XHTTP_PATH="/$XHTTP_PATH"
  printf '%s' "$XHTTP_PATH" | grep -Eq '^/[A-Za-z0-9._~/-]+$' || fail "Недопустимый XHTTP path"
  printf '%s\n' "$XHTTP_PATH" > "$XHTTP_PATH_FILE"
  chmod 600 "$XHTTP_PATH_FILE"
}

resolve_hysteria(){
  case "$ENABLE_HYSTERIA2" in
    1|yes|YES|true|TRUE|y|Y) ENABLE_HYSTERIA2=1 ;;
    0|no|NO|false|FALSE|n|N) ENABLE_HYSTERIA2=0 ;;
    keep)
      if [[ -r "$HYSTERIA_STATE_FILE" ]]; then ENABLE_HYSTERIA2="$(tr -d '[:space:]' < "$HYSTERIA_STATE_FILE")"; else ENABLE_HYSTERIA2=0; fi
      ;;
    ask)
      local answer
      printf '\nHysteria2 = UDP/443 + QUIC + TLS1.3. В РФ может фильтроваться; основной XHTTP+REALITY от нее не зависит.\n'
      read -r -p "Добавить Hysteria2 как дополнительный транспорт? [y/N]: " answer
      case "${answer:-N}" in [Yy]*) ENABLE_HYSTERIA2=1 ;; *) ENABLE_HYSTERIA2=0 ;; esac
      ;;
    *) fail "ENABLE_HYSTERIA2 должен быть 0/1/ask/keep" ;;
  esac
  printf '%s\n' "$ENABLE_HYSTERIA2" > "$HYSTERIA_STATE_FILE"
  chmod 600 "$HYSTERIA_STATE_FILE"
}

find_rw_core(){
  RW_CORE="$(command -v rw-core 2>/dev/null || true)"
  [[ -x "$RW_CORE" ]] && return 0
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then RW_CORE="docker:remnanode"; return 0; fi
  fail "rw-core не найден"
}

generate_reality_material(){
  local private="" public="" short="" raw
  if [[ -s "$REALITY_ENV" ]]; then
    private="$(sed -n 's/^REALITY_PRIVATE_KEY=//p' "$REALITY_ENV" | head -1)"
    public="$(sed -n 's/^REALITY_PUBLIC_KEY=//p' "$REALITY_ENV" | head -1)"
    short="$(sed -n 's/^REALITY_SHORT_ID=//p' "$REALITY_ENV" | head -1)"
  fi
  if [[ -z "$private" || -z "$public" || -z "$short" ]]; then
    if [[ "$RW_CORE" == docker:* ]]; then
      raw="$(docker exec remnanode /usr/local/bin/rw-core x25519 2>/dev/null)" || fail "rw-core x25519 завершился ошибкой"
    else
      raw="$("$RW_CORE" x25519 2>/dev/null)" || fail "rw-core x25519 завершился ошибкой"
    fi
    private="$(printf '%s\n' "$raw" | sed -nE 's/^[[:space:]]*(PrivateKey|Private key):[[:space:]]*//p' | head -1)"
    public="$(printf '%s\n' "$raw" | sed -nE 's/^[[:space:]]*(Password([[:space:]]*\([^)]*\))?|PublicKey|Public key):[[:space:]]*//p' | head -1)"
    short="$(openssl rand -hex 8)"
  fi
  [[ -n "$private" && -n "$public" && -n "$short" ]] || fail "Не удалось получить Reality keys"

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
EOF
  chmod 600 "$REALITY_ENV"
}

check_hysteria(){
  [[ "$ENABLE_HYSTERIA2" -eq 1 ]] || return 0
  [[ -s "$CERTS_DIR/fullchain.pem" && -s "$CERTS_DIR/privkey.pem" ]] || fail "Для Hysteria2 нет сертификатов в $CERTS_DIR"
  openssl x509 -in "$CERTS_DIR/fullchain.pem" -noout >/dev/null 2>&1 || fail "Некорректный fullchain.pem"
  openssl pkey -in "$CERTS_DIR/privkey.pem" -noout >/dev/null 2>&1 || fail "Некорректный privkey.pem"
  (cd "$APP_DIR" && docker compose config | grep -q '/etc/xray/certs') || fail "Cert mount /etc/xray/certs отсутствует"
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
      "settings": {"version": 2, "users": []},
      "streamSettings": {
        "network": "hysteria",
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
          "certificates": [{"certificateFile": "$XRAY_CERT_FILE", "keyFile": "$XRAY_KEY_FILE"}]
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
      "listen": "127.0.0.1",
      "port": $XRAY_TCP_PORT,
      "protocol": "vless",
      "settings": {"clients": [], "decryption": "none"},
      "sniffing": {"enabled": true, "routeOnly": true, "destOverride": ["http", "tls", "quic"]},
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$REALITY_TARGET",
          "xver": 0,
          "serverNames": ["$REALITY_SNI"],
          "privateKey": "$REALITY_PRIVATE_KEY",
          "minClientVer": "0.0.0",
          "shortIds": ["$REALITY_SHORT_ID"],
          "limitFallbackUpload": {
            "afterBytes": 10485760,
            "bytesPerSec": 2097152,
            "burstBytesPerSec": 5242880
          },
          "limitFallbackDownload": {
            "afterBytes": 10485760,
            "bytesPerSec": 2097152,
            "burstBytesPerSec": 5242880
          }
        },
        "xhttpSettings": {
          "mode": "packet-up",
          "path": "$XHTTP_PATH"
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
      {"type": "field", "ip": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4", "240.0.0.0/4", "::1/128", "fc00::/7", "fe80::/10"], "outboundTag": "BLOCK"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK"}
    ]
  }
}
EOF
  chmod 600 "$PROFILE_FILE"
  jq empty "$PROFILE_FILE" || fail "Сгенерированный Config Profile невалидный JSON"
}

write_external_snippet(){
  cat > "$EXTERNAL_SNIPPET_FILE" <<EOF
{
  "remnawave": {
    "injectHosts": [
      {
        "selector": {
          "type": "remarkRegex",
          "pattern": "^${HOST_REMARK}$"
        },
        "selectFrom": "ALL",
        "tagPrefix": "proxy"
      }
    ]
  }
}
EOF
  chmod 600 "$EXTERNAL_SNIPPET_FILE"
}

write_optional_mapper(){
  cat > "$MAPPER_FILE" <<EOF
{
  "xrayJson": [
    {
      "op": "set",
      "value": "reality",
      "to": "streamSettings.security"
    },
    {
      "op": "set",
      "value": {
        "serverName": "$REALITY_SNI",
        "publicKey": "$REALITY_PUBLIC_KEY",
        "shortId": "$REALITY_SHORT_ID",
        "fingerprint": "firefox"
      },
      "to": "streamSettings.realitySettings"
    }
  ],
  "mihomo": [],
  "base64": []
}
EOF
  chmod 600 "$MAPPER_FILE"
  jq empty "$MAPPER_FILE" || fail "Сгенерированный Mapper невалидный JSON"
}

write_summaries(){
  cat > "$READY_FILE" <<EOF
REMNAWAVE — ЧТО СОЗДАТЬ В ПАНЕЛИ
================================

1. MANAGEMENT -> CONFIG PROFILES -> CREATE CONFIG PROFILE
   Вставить целиком содержимое:
   $PROFILE_FILE

2. Назначить этот Config Profile ноде $NODE_DOMAIN.
   Inbound XHTTP_REALITY слушает ВНУТРИ ноды 127.0.0.1:$XRAY_TCP_PORT.
   Это намеренно: публичный TCP/$PUBLIC_TCP_PORT принадлежит SelfSteal frontend.

3. MANAGEMENT -> HOSTS -> CREATE HOST
   Remark:          $HOST_REMARK
   Inbound:         XHTTP_REALITY
   Address:         $NODE_DOMAIN
   Port:            $PUBLIC_TCP_PORT
   Security Layer:  DEFAULT / НЕ ПЕРЕОПРЕДЕЛЯТЬ
   SNI:             $REALITY_SNI
   Host:            ОСТАВИТЬ ПУСТЫМ / НЕ ПЕРЕОПРЕДЕЛЯТЬ
   Path:            $XHTTP_PATH
   Fingerprint:     firefox

ВАЖНО: в Host НЕ выбирай Security Layer = TLS.
Inbound уже имеет streamSettings.security = reality, поэтому Host должен наследовать REALITY из inbound.
Public Key и Short ID также наследуются из realitySettings выбранного inbound:
   Public key:      $REALITY_PUBLIC_KEY
   Short ID:        $REALITY_SHORT_ID

XHTTP СЕЙЧАС НАМЕРЕННО МИНИМАЛЬНЫЙ
----------------------------------
В серверном Config Profile остаются только:
  mode: packet-up
  path: $XHTTP_PATH

Поля extra/xmux/sessionKey/sessionIDKey/scMaxConcurrentPosts/scMinPostsIntervalMs удалены,
чтобы не создавать лишнюю зависимость от конкретной версии Xray-клиента.

OPTIONAL HOST MAPPER
--------------------
Mapper НЕ нужен в штатной конфигурации, если Remnawave уже выдает security=reality + publicKey + shortId.
Он сохранен только как аварийный/диагностический вариант:
  $MAPPER_FILE

ВАЖНО ПО REALITY CAMOUFLAGE
---------------------------
SNI и target — одна и та же проверенная внешняя HTTPS-цель:
  SNI:    $REALITY_SNI
  target: $REALITY_TARGET

Клиент подключается к $NODE_DOMAIN:$PUBLIC_TCP_PORT, а camouflage SNI используется для nginx SNI routing и REALITY.

EXTERNAL XRAY_JSON
------------------
Файл совместимого injectHosts-фрагмента:
  $EXTERNAL_SNIPPET_FILE

Он выбирает Host по Remark = $HOST_REMARK и создает outbound с tagPrefix=proxy.
Если в твоем External XRAY_JSON уже есть корневой объект "remnawave", НЕ заменять весь JSON — добавить эту injectHosts-группу в существующий объект.

SELFSTEAL
---------
Public URL: https://$NODE_DOMAIN/
Frontend: TCP/$PUBLIC_TCP_PORT nginx SNI mux
REALITY camouflage route -> 127.0.0.1:$XRAY_TCP_PORT
Website route: остальные SNI -> 127.0.0.1:$SELFSTEAL_PORT TLS1.2
SelfSteal не зависит от наличия/назначения Config Profile.

HYSTERIA2
---------
Enabled: $ENABLE_HYSTERIA2
$([[ "$ENABLE_HYSTERIA2" -eq 1 ]] && printf 'Inbound: HYSTERIA2_TLS\nPublic: %s:443/UDP\nCerts in container: /etc/xray/certs/fullchain.pem + privkey.pem\n' "$NODE_DOMAIN")
EOF
  chmod 600 "$READY_FILE"

  cat > "$PROFILE_PUBLIC_FILE" <<EOF
Domain: $NODE_DOMAIN
Public site: https://$NODE_DOMAIN/
XHTTP public: $NODE_DOMAIN:$PUBLIC_TCP_PORT/TCP
XHTTP internal inbound: 127.0.0.1:$XRAY_TCP_PORT
REALITY camouflage route: CONFIGURED (use Host-values menu to reveal SNI)
XHTTP mode: packet-up (minimal profile, no extra/xmux/session overrides)
XHTTP path: $XHTTP_PATH
Host Remark: $HOST_REMARK
Host Security Layer: DEFAULT (inherit REALITY)
Optional Host Mapper: $MAPPER_FILE
Hysteria2: $ENABLE_HYSTERIA2
EOF
  chmod 600 "$PROFILE_PUBLIC_FILE"
}

configure_firewall(){
  command -v ufw >/dev/null 2>&1 || return 0
  ufw allow "$PUBLIC_TCP_PORT"/tcp comment 'SelfSteal + XHTTP frontend' >/dev/null 2>&1 || true
  ufw --force delete allow "$XRAY_TCP_PORT"/tcp >/dev/null 2>&1 || true
  if [[ "$ENABLE_HYSTERIA2" -eq 1 ]]; then ufw allow 443/udp comment 'Hysteria2' >/dev/null 2>&1 || true; fi
  ufw reload >/dev/null 2>&1 || true
}

show_result(){
  echo
  echo '#################### НАЧАЛО ВЫВОДА: COPY-PASTE REMNAWAVE CONFIG PROFILE ####################'
  cat "$PROFILE_FILE"
  echo '#################### КОНЕЦ ВЫВОДА: COPY-PASTE REMNAWAVE CONFIG PROFILE ####################'
  echo
  echo '#################### НАЧАЛО ВЫВОДА: REMNAWAVE HOST VALUES ####################'
  cat "$READY_FILE"
  echo '#################### КОНЕЦ ВЫВОДА: REMNAWAVE HOST VALUES ####################'
}

main(){
  echo '#################### НАЧАЛО ВЫВОДА: REMNAWAVE PROFILE GENERATOR ####################'
  require_root
  resolve_domain
  resolve_reality_route
  resolve_path
  resolve_hysteria
  find_rw_core
  generate_reality_material
  check_hysteria
  write_profile
  write_external_snippet
  write_optional_mapper
  write_summaries
  configure_firewall
  show_result
  echo '#################### КОНЕЦ ВЫВОДА: REMNAWAVE PROFILE GENERATOR ####################'
}

main "$@"
