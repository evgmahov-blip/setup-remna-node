#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
CERTS_DIR="${CERTS_DIR:-$APP_DIR/certs}"
WWW_DIR="${WWW_DIR:-/var/www/html}"
NODE_DOMAIN_FILE="$APP_DIR/.node_domain"
NODE_NAME_FILE="$APP_DIR/.node_name"
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
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
SELFSTEAL_SOCKET="${SELFSTEAL_SOCKET:-/dev/shm/nginx.sock}"
REALITY_MIN_CLIENT_VER="${REALITY_MIN_CLIENT_VER:-}"
XHTTP_SIGNATURE_MODE="${XHTTP_SIGNATURE_MODE:-preserve}"
HYSTERIA_CERT_MOUNT_ACTION="${HYSTERIA_CERT_MOUNT_ACTION:-}"

mkdir -p "$APP_DIR" "$PROFILE_DIR"

log(){ printf '%s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }

node_domain(){
  local d="${NODE_DOMAIN:-}"
  [[ -z "$d" && -r "$NODE_DOMAIN_FILE" ]] && d="$(tr -d '[:space:]' < "$NODE_DOMAIN_FILE")"
  if [[ -z "$d" ]]; then
    fail "Не найден домен ноды. Сначала выполни штатную установку ноды."
    return 1
  fi
  printf '%s' "$d"
}

node_name(){
  local n="${NODE_NAME:-}" detected=""
  if [[ -z "$n" && -r "$NODE_NAME_FILE" ]]; then
    n="$(head -n1 "$NODE_NAME_FILE" | tr -d '\r\n')"
  fi
  if [[ -z "$n" ]]; then
    detected="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
    n="$detected"
  fi
  if [[ -z "$n" ]]; then
    n="$(node_domain)"
    n="${n%%.*}"
  fi
  n="$(printf '%s' "$n" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
  [[ -n "$n" ]] || { fail "Не удалось определить имя сервера для inbound"; return 1; }
  printf '%s\n' "$n" > "$NODE_NAME_FILE"
  chmod 600 "$NODE_NAME_FILE"
  printf '%s' "$n"
}

inbound_name(){
  local base transport="$1"
  base="$(node_name)" || return 1
  case "$transport" in
    xhttp) printf '%s-xHTTP' "$base" ;;
    raw) printf '%s-RAW' "$base" ;;
    hysteria) printf '%s-Hysteria2' "$base" ;;
    *) fail "Неизвестный транспорт для имени inbound: $transport"; return 1 ;;
  esac
}

xray_cmd(){
  if command -v xray >/dev/null 2>&1; then
    xray "$@"
  elif command -v rw-core >/dev/null 2>&1; then
    rw-core "$@"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    if docker exec remnanode test -x /usr/local/bin/rw-core 2>/dev/null; then
      docker exec remnanode /usr/local/bin/rw-core "$@"
    elif docker exec remnanode test -x /usr/local/bin/xray 2>/dev/null; then
      docker exec remnanode /usr/local/bin/xray "$@"
    else
      fail "В контейнере remnanode не найден rw-core/xray"
      return 1
    fi
  else
    fail "Xray/rw-core не найден"
    return 1
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
        while (match($0, /[\047"][A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+[\047"]/)) {
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
  if [[ -s "$SNI_POOL_CACHE" ]]; then
    log "[WARN] Не удалось обновить SNI pool, используется предыдущий кэш"
    return 0
  fi
  cat > "$SNI_POOL_CACHE" <<'POOL'
www.microsoft.com
www.apple.com
www.amazon.com
www.samsung.com
www.yahoo.com
www.bing.com
www.cloudflare.com
POOL
  chmod 600 "$SNI_POOL_CACHE"
  log "[WARN] Используется встроенный резервный SNI pool"
}

check_sni(){
  local sni="$1" out cert
  [[ -n "$sni" ]] || return 1
  [[ "$sni" != "$(node_domain)" ]] || return 1
  out="$(timeout 10 openssl s_client -connect "$sni:443" -servername "$sni" -tls1_3 -alpn h2 </dev/null 2>&1)" || return 1
  printf '%s\n' "$out" | grep -q '^ *ALPN protocol: h2$' || return 1
  printf '%s\n' "$out" | grep -q 'Verify return code: 0 (ok)' || return 1
  cert="$(printf '%s\n' "$out" | awk '/-----BEGIN CERTIFICATE-----/{p=1} p{print} /-----END CERTIFICATE-----/{exit}')"
  [[ -n "$cert" ]] || return 1
  printf '%s\n' "$cert" | openssl x509 -noout -checkhost "$sni" 2>/dev/null | grep -q ' does match certificate$'
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
      [[ -n "$current" ]] || { fail "Не найден рабочий SNI"; return 1; }
      ;;
    3|manual)
      sni="${REALITY_SNI_INPUT:-}"
      [[ -n "$sni" ]] || read -r -p 'SNI: ' sni
      check_sni "$sni" || { fail "SNI не прошёл TLS1.3/ALPN/cert проверку: $sni"; return 1; }
      current="$sni"
      ;;
    4|refresh)
      refresh_sni_pool
      [[ -n "$current" && "$current" != "$(node_domain)" ]] || { fail "Текущий внешний SNI ещё не задан"; return 1; }
      ;;
    1|keep) ;;
    *) fail "Неизвестный выбор SNI"; return 1 ;;
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
  local mode="${CAMOUFLAGE_MODE:-}" c protocol
  if [[ -z "$mode" ]]; then
    echo
    echo 'Маскировка REALITY:'
    echo '  1) SelfSteal — старая рабочая архитектура: Xray :443 -> /dev/shm/nginx.sock'
    echo '  2) Внешний SNI — target крупного HTTPS-сайта из проверяемого пула'
    read -r -p 'Выбор [1]: ' c
    case "${c:-1}" in 1) mode=selfsteal ;; 2) mode=external ;; *) fail "Неверный режим маскировки"; return 1 ;; esac
  fi

  case "$mode" in
    selfsteal)
      [[ -s "$CERTS_DIR/fullchain.pem" && -s "$CERTS_DIR/privkey.pem" ]] || { fail "SelfSteal требует SSL сертификат ноды в $CERTS_DIR"; return 1; }
      if ! grep -Fq "listen unix:${SELFSTEAL_SOCKET} ssl proxy_protocol" "$APP_DIR/nginx.conf" 2>/dev/null; then
        protocol="$(cat "$APP_DIR/.protocol" 2>/dev/null || echo неизвестно)"
        fail "SelfSteal REALITY несовместим с текущим nginx.conf: protocol=$protocol, ${SELFSTEAL_SOCKET} слушается без ssl. Выбери external SNI либо сначала переведи ноду на штатный reality/SelfSteal nginx."
        return 1
      fi
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
    *) fail "CAMOUFLAGE_MODE должен быть selfsteal или external"; return 1 ;;
  esac
}

generate_reality_keys(){
  local private="" public="" short="" raw old_umask
  if [[ -s "$REALITY_ENV" ]]; then
    private="$(sed -n 's/^REALITY_PRIVATE_KEY=//p' "$REALITY_ENV" | head -1)"
    public="$(sed -n 's/^REALITY_PUBLIC_KEY=//p' "$REALITY_ENV" | head -1)"
    short="$(sed -n 's/^REALITY_SHORT_ID=//p' "$REALITY_ENV" | head -1)"
  fi

  if [[ -z "$private" || -z "$public" || -z "$short" ]]; then
    raw="$(xray_cmd x25519 2>/dev/null)" || { fail "Не удалось сгенерировать REALITY keypair"; return 1; }
    private="$(printf '%s\n' "$raw" | sed -nE 's/^[[:space:]]*(PrivateKey|Private key):[[:space:]]*//p' | head -1)"
    public="$(printf '%s\n' "$raw" | sed -nE 's/^[[:space:]]*(Password([[:space:]]*\([^)]*\))?|PublicKey|Public key):[[:space:]]*//p' | head -1)"
    short="$(openssl rand -hex 8)"
  fi

  [[ -n "$private" && -n "$public" && -n "$short" ]] || { fail "REALITY keys не определены"; return 1; }
  REALITY_PRIVATE_KEY="$private"
  REALITY_PUBLIC_KEY="$public"
  REALITY_SHORT_ID="$short"

  old_umask="$(umask)"
  umask 077
  cat > "$REALITY_ENV" <<KEYS
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
REALITY_SHORT_ID=$REALITY_SHORT_ID
REALITY_SERVER_NAME=$REALITY_SNI
REALITY_TARGET=$REALITY_TARGET
REALITY_XVER=$REALITY_XVER
CAMOUFLAGE_MODE=$CAMOUFLAGE_MODE
KEYS
  umask "$old_umask"
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
  cat <<'JSON'
{
  "log": {"loglevel": "warning"},
  "stats": {},
  "policy": {
    "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}},
    "system": {"statsInboundUplink": true, "statsInboundDownlink": true}
  },
  "inbounds": [
JSON
}

profile_suffix(){
  cat <<'JSON'
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
JSON
}

container_runtime_bin(){
  if docker exec remnanode test -x /usr/local/bin/rw-core 2>/dev/null; then
    printf '%s' /usr/local/bin/rw-core
  elif docker exec remnanode test -x /usr/local/bin/xray 2>/dev/null; then
    printf '%s' /usr/local/bin/xray
  else
    return 1
  fi
}

local_runtime_bin(){
  if command -v xray >/dev/null 2>&1; then
    command -v xray
  elif command -v rw-core >/dev/null 2>&1; then
    command -v rw-core
  elif [[ -x "$APP_DIR/bin/xray" ]]; then
    printf '%s' "$APP_DIR/bin/xray"
  else
    return 1
  fi
}

profile_runtime_test_impl(){
  local p="$1" verbose="${2:-0}" remote="/tmp/.remnawave-profile-test.json" bin rc
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    docker cp "$p" "remnanode:$remote" >/dev/null 2>&1 || return 1
    bin="$(container_runtime_bin)" || { docker exec remnanode rm -f "$remote" >/dev/null 2>&1 || true; return 1; }
    if (( verbose )); then
      if docker exec remnanode "$bin" run -test -c "$remote"; then rc=0; else rc=$?; fi
    else
      if docker exec remnanode "$bin" run -test -c "$remote" >/dev/null 2>&1; then rc=0; else rc=$?; fi
    fi
    docker exec remnanode rm -f "$remote" >/dev/null 2>&1 || true
    return "$rc"
  fi

  bin="$(local_runtime_bin)" || return 127
  if (( verbose )); then
    "$bin" run -test -c "$p"
  else
    "$bin" run -test -c "$p" >/dev/null 2>&1
  fi
}

profile_runtime_test(){ profile_runtime_test_impl "$1" 0; }
profile_runtime_test_verbose(){ profile_runtime_test_impl "$1" 1; }

atomic_profile_install(){
  local tmp="$1" dst="$2" rc
  if ! jq empty "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    fail "Сгенерирован некорректный JSON: $dst"
    return 1
  fi

  if profile_runtime_test "$tmp"; then
    :
  else
    rc=$?
    log "[ERROR] Профиль отклонён runtime rw-core/Xray (rc=$rc). Диагностика:"
    profile_runtime_test_verbose "$tmp" || true
    rm -f "$tmp"
    fail "$dst НЕ обновлён — предыдущая рабочая версия сохранена"
    return 1
  fi

  chmod 600 "$tmp"
  mv -f "$tmp" "$dst"
}

reality_min_client_json(){
  if [[ -n "$REALITY_MIN_CLIENT_VER" ]]; then
    printf '          "minClientVer": "%s",\n' "$REALITY_MIN_CLIENT_VER"
  fi
}

write_xhttp_profile(){
  local f="$PROFILE_DIR/xhttp-reality.json" tmp tmp2 sig="$APP_DIR/xhttp-signature.json" inbound
  inbound="$(inbound_name xhttp)" || return 1
  resolve_xhttp_path
  tmp="$(mktemp "$PROFILE_DIR/.xhttp-reality.XXXXXX.json")"
  {
    base_profile_prefix
    cat <<JSON
    {
      "tag": "$inbound",
      "listen": "$LISTEN_ADDR",
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
$(reality_min_client_json)          "privateKey": "$REALITY_PRIVATE_KEY",
          "shortIds": ["$REALITY_SHORT_ID"]
        },
        "xhttpSettings": {
          "mode": "auto",
          "path": "$XHTTP_PATH"
        }
      }
    }
JSON
    profile_suffix
  } > "$tmp"

  case "$XHTTP_SIGNATURE_MODE" in
    preserve)
      if [[ -s "$sig" ]]; then
        jq -e 'type == "object"' "$sig" >/dev/null 2>&1 || { rm -f "$tmp"; fail "Повреждена сохранённая XHTTP сигнатура: $sig"; return 1; }
        tmp2="$(mktemp "$PROFILE_DIR/.xhttp-sig.XXXXXX.json")"
        if jq --slurpfile e "$sig" '.inbounds[0].streamSettings.xhttpSettings.extra = $e[0]' "$tmp" > "$tmp2"; then
          mv -f "$tmp2" "$tmp"
          log "[OK] Сохранённая XHTTP сигнатура перенесена в новый профиль"
        else
          rm -f "$tmp" "$tmp2"
          fail "Не удалось применить сохранённую сигнатуру из $sig"
          return 1
        fi
      fi
      ;;
    none) ;;
    *) rm -f "$tmp"; fail "XHTTP_SIGNATURE_MODE должен быть preserve или none"; return 1 ;;
  esac

  atomic_profile_install "$tmp" "$f"
}

write_raw_profile(){
  local f="$PROFILE_DIR/raw-reality.json" tmp inbound
  inbound="$(inbound_name raw)" || return 1
  tmp="$(mktemp "$PROFILE_DIR/.raw-reality.XXXXXX.json")"
  {
    base_profile_prefix
    cat <<JSON
    {
      "tag": "$inbound",
      "listen": "$LISTEN_ADDR",
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
$(reality_min_client_json)          "privateKey": "$REALITY_PRIVATE_KEY",
          "shortIds": ["$REALITY_SHORT_ID"]
        },
        "rawSettings": {"header": {"type": "none"}}
      }
    }
JSON
    profile_suffix
  } > "$tmp"
  atomic_profile_install "$tmp" "$f"
}

ensure_hysteria_cert_mount(){
  local compose="$APP_DIR/docker-compose.yml" backup answer tmpc need_edit=0
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    return 0
  fi

  if docker exec remnanode test -s /etc/xray/certs/fullchain.pem 2>/dev/null \
     && docker exec remnanode test -s /etc/xray/certs/privkey.pem 2>/dev/null; then
    log "[OK] /etc/xray/certs доступен внутри remnanode"
    return 0
  fi

  [[ -f "$compose" ]] || { fail "Hysteria2 заблокирована: в remnanode нет /etc/xray/certs и отсутствует $compose"; return 1; }

  echo '[WARN] Hysteria2 требует сертификаты внутри контейнера remnanode.'
  echo '[WARN] Для reality-ноды нужно добавить cert bind и пересоздать ТОЛЬКО remnanode.'
  echo '[WARN] TCP/443 будет недоступен несколько секунд; nginx SelfSteal не пересоздаётся.'

  if [[ "$HYSTERIA_CERT_MOUNT_ACTION" != "fix" ]]; then
    if [[ -t 0 ]]; then
      read -r -p 'Для безопасного добавления bind и пересоздания remnanode введите MOUNT: ' answer
      [[ "$answer" == "MOUNT" ]] || { fail "Hysteria2 отменена до изменения docker-compose.yml"; return 1; }
    else
      fail "Нужен cert bind. Для подтверждённого неинтерактивного запуска задай HYSTERIA_CERT_MOUNT_ACTION=fix"
      return 1
    fi
  fi

  backup="$compose.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$compose" "$backup"

  if ! grep -Fq "$CERTS_DIR:/etc/xray/certs:ro" "$compose"; then
    need_edit=1
    tmpc="$(mktemp "$APP_DIR/.compose-hysteria.XXXXXX")"
    if ! awk -v bind="$CERTS_DIR:/etc/xray/certs:ro" '
      BEGIN {in_remna=0; added=0}
      /^  remnanode:[[:space:]]*$/ {in_remna=1}
      in_remna && /^  [^[:space:]][^:]*:/ && $0 !~ /^  remnanode:/ {in_remna=0}
      {print}
      in_remna && !added && $0 ~ /^[[:space:]]+- \/dev\/shm:\/dev\/shm:rw[[:space:]]*$/ {
        match($0,/^[[:space:]]*/); indent=substr($0,1,RLENGTH)
        print indent "- " bind
        added=1
      }
      END { if (!added) exit 42 }
    ' "$compose" > "$tmpc"; then
      rm -f "$tmpc"
      fail "Не удалось безопасно добавить cert bind; compose не изменён, backup: $backup"
      return 1
    fi
    mv -f "$tmpc" "$compose"
  fi

  log "[INFO] Пересоздаю только remnanode; nginx не трогаю"
  if ! ( cd "$APP_DIR" && docker compose up -d remnanode ); then
    cp -a "$backup" "$compose"
    ( cd "$APP_DIR" && docker compose up -d remnanode ) >/dev/null 2>&1 || true
    fail "Не удалось пересоздать remnanode; docker-compose.yml восстановлен из $backup"
    return 1
  fi

  if ! docker exec remnanode test -s /etc/xray/certs/fullchain.pem 2>/dev/null \
     || ! docker exec remnanode test -s /etc/xray/certs/privkey.pem 2>/dev/null; then
    if (( need_edit )); then cp -a "$backup" "$compose"; fi
    fail "После пересоздания сертификаты всё ещё не видны в /etc/xray/certs. Профиль Hysteria2 НЕ создан."
    return 1
  fi
  log "[OK] cert mount готов; backup compose: $backup"
}

hysteria_masquerade_json(){
  local sz
  if [[ -s "$WWW_DIR/index.html" ]]; then
    sz="$(stat -c%s "$WWW_DIR/index.html")"
    (( sz <= 262144 )) || { fail "index.html слишком велик для Hysteria masquerade ($sz байт; максимум 262144)"; return 1; }
    jq -Rs '{type:"string",content:.,headers:{"content-type":"text/html; charset=utf-8"},statusCode:200}' < "$WWW_DIR/index.html"
  else
    printf '%s\n' '{"type":"string","content":"<!doctype html><html><body><h1>Welcome</h1></body></html>","headers":{"content-type":"text/html; charset=utf-8"},"statusCode":200}'
  fi
}

write_hysteria_profile(){
  local f="$PROFILE_DIR/hysteria2-tls.json" masq tmp inbound
  inbound="$(inbound_name hysteria)" || return 1
  [[ -s "$CERTS_DIR/fullchain.pem" && -s "$CERTS_DIR/privkey.pem" ]] || { fail "Для Hysteria2 нужны $CERTS_DIR/fullchain.pem и privkey.pem"; return 1; }
  ensure_hysteria_cert_mount
  masq="$(hysteria_masquerade_json)" || return 1
  tmp="$(mktemp "$PROFILE_DIR/.hysteria2-tls.XXXXXX.json")"
  {
    base_profile_prefix
    cat <<JSON
    {
      "tag": "$inbound",
      "listen": "$LISTEN_ADDR",
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
JSON
    profile_suffix
  } > "$tmp"
  atomic_profile_install "$tmp" "$f"
}

write_combined_profile(){
  local x="$PROFILE_DIR/xhttp-reality.json" h="$PROFILE_DIR/hysteria2-tls.json"
  local f="$PROFILE_DIR/xhttp-hysteria2.json" tmp
  [[ -s "$x" ]] || { fail "Не найден XHTTP профиль: $x"; return 1; }
  [[ -s "$h" ]] || { fail "Не найден Hysteria2 профиль: $h"; return 1; }
  tmp="$(mktemp "$PROFILE_DIR/.xhttp-hysteria2.XXXXXX.json")"
  if ! jq --slurpfile h "$h" '.inbounds += $h[0].inbounds' "$x" > "$tmp"; then
    rm -f "$tmp"
    fail "Не удалось объединить XHTTP и Hysteria2"
    return 1
  fi
  atomic_profile_install "$tmp" "$f"
}

write_host_values(){
  local transport="$1" d minver inbound
  d="$(node_domain)"
  inbound="$(inbound_name "$transport")" || return 1
  minver="${REALITY_MIN_CLIENT_VER:-26.3.27 (дефолт Xray)}"
  case "$transport" in
    xhttp)
      cat > "$PROFILE_DIR/host-xhttp.txt" <<HOST
Remark: $inbound
Inbound: $inbound
Address: $d
Port: $PUBLIC_PORT
Security Layer: DEFAULT
SNI: $REALITY_SNI
Fingerprint: firefox
Host: пусто
Path: $XHTTP_PATH
Mode: auto
Flow: пусто
Reality keys: берутся из Inbound при Security Layer DEFAULT; вручную в Host не вводятся
Camouflage: $CAMOUFLAGE_MODE
Reality target: $REALITY_TARGET
Min client ver: $minver
HOST
      ;;
    raw)
      cat > "$PROFILE_DIR/host-raw.txt" <<HOST
Remark: $inbound
Inbound: $inbound
Address: $d
Port: $PUBLIC_PORT
Security Layer: DEFAULT
SNI: $REALITY_SNI
Fingerprint: firefox
Host: пусто
Path: пусто
Flow: пусто (осознанно: совместимость; xtls-rprx-vision не включён)
Reality keys: берутся из Inbound при Security Layer DEFAULT; вручную в Host не вводятся
Camouflage: $CAMOUFLAGE_MODE
Reality target: $REALITY_TARGET
Min client ver: $minver
HOST
      ;;
    hysteria)
      cat > "$PROFILE_DIR/host-hysteria2.txt" <<HOST
Remark: $inbound
Inbound: $inbound
Address: $d
Port: $PUBLIC_PORT
Transport: Hysteria2 / UDP
Security Layer: DEFAULT
SNI: $d
Take SNI from address: ON
ALPN: h3
Masquerade: встроенная копия текущего SelfSteal index.html
HOST
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
    combined)
      select_camouflage
      generate_reality_keys
      write_xhttp_profile
      write_host_values xhttp
      write_hysteria_profile
      write_host_values hysteria
      write_combined_profile
      ;;
    *) fail "Допустимо: xhttp | raw | hysteria | combined"; return 1 ;;
  esac
  printf '%s\n' "$transport" > "$TRANSPORT_FILE"
  chmod 600 "$TRANSPORT_FILE"
}

show_result(){
  local transport="$1" profile host host2=""
  case "$transport" in
    xhttp) profile="$PROFILE_DIR/xhttp-reality.json"; host="$PROFILE_DIR/host-xhttp.txt" ;;
    raw) profile="$PROFILE_DIR/raw-reality.json"; host="$PROFILE_DIR/host-raw.txt" ;;
    hysteria) profile="$PROFILE_DIR/hysteria2-tls.json"; host="$PROFILE_DIR/host-hysteria2.txt" ;;
    combined) profile="$PROFILE_DIR/xhttp-hysteria2.json"; host="$PROFILE_DIR/host-xhttp.txt"; host2="$PROFILE_DIR/host-hysteria2.txt" ;;
  esac
  echo '#################### НАЧАЛО ВЫВОДА: REMNAWAVE TRANSPORT PROFILE ####################'
  echo "Transport: $transport"
  echo "Profile:   $profile"
  echo "Host:      $host"
  [[ -n "$host2" ]] && echo "Host 2:    $host2"
  echo
  if [[ "${SHOW_PRIVATE_PROFILE:-0}" == "1" ]]; then
    cat "$profile"
  else
    jq '(.inbounds[]?.streamSettings.realitySettings.privateKey? // empty) = "<REDACTED_PRIVATE_KEY>"' "$profile" 2>/dev/null || cat "$profile"
    echo
    echo '[INFO] privateKey скрыт в выводе.'
    echo "[INFO] Полный профиль для копипаста: cat $profile"
  fi
  echo
  echo '[HOST]'
  cat "$host"
  if [[ -n "$host2" ]]; then
    echo
    echo '[HOST 2]'
    cat "$host2"
  fi
  echo '#################### КОНЕЦ ВЫВОДА: REMNAWAVE TRANSPORT PROFILE ####################'
}

main(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { fail "Запусти от root"; return 1; }
  local transport="${1:-}" c
  if [[ -z "$transport" ]]; then
    echo 'Выбери транспорт:'
    echo '  1) VLESS + REALITY + XHTTP (основной)'
    echo '  2) VLESS + REALITY + RAW (fallback)'
    echo '  3) Hysteria2 + TLS (UDP)'
    echo '  4) XHTTP + Hysteria2 одновременно (TCP/443 + UDP/443)'
    read -r -p 'Выбор [1]: ' c
    case "${c:-1}" in 1) transport=xhttp ;; 2) transport=raw ;; 3) transport=hysteria ;; 4) transport=combined ;; *) fail "Неверный выбор"; return 1 ;; esac
  fi
  generate_transport "$transport"
  show_result "$transport"
}

main "$@"
