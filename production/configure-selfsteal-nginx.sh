#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
CERTS_DIR="${CERTS_DIR:-$APP_DIR/certs}"
WEBROOT="${WEBROOT:-/var/www/html}"
LOG_DIR="${LOG_DIR:-/var/log/remnanode}"
SELFSTEAL_PORT="${SELFSTEAL_PORT:-8443}"
XRAY_TCP_PORT="${XRAY_TCP_PORT:-10443}"
PUBLIC_TCP_PORT="${PUBLIC_TCP_PORT:-443}"
NGINX_MAIN_CONF="$APP_DIR/nginx-main.conf"
OVERRIDE_FILE="$APP_DIR/docker-compose.override.yml"
REALITY_SNI_FILE="$APP_DIR/.reality_sni"
REALITY_TARGET_FILE="$APP_DIR/.reality_target"
REALITY_ROUTE_VERSION_FILE="$APP_DIR/.reality_route_version"
REALITY_ROUTE_VERSION="2"
REALITY_SNI_MODE="${REALITY_SNI_MODE:-keep}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.28}"

log(){ printf '%s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запустите от root"; }

resolve_domain(){
  NODE_DOMAIN="${NODE_DOMAIN:-}"
  [[ -z "$NODE_DOMAIN" && -r "$APP_DIR/.node_domain" ]] && NODE_DOMAIN="$(tr -d '[:space:]' < "$APP_DIR/.node_domain")"
  [[ -n "$NODE_DOMAIN" ]] || read -r -p "Домен ноды: " NODE_DOMAIN
  [[ -n "$NODE_DOMAIN" ]] || fail "Домен не определен"
}

is_public_ipv4(){
  local ip="$1" a b
  IFS=. read -r a b _ <<< "$ip"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 1
  (( a == 10 || a == 127 || a == 0 )) && return 1
  (( a == 169 && b == 254 )) && return 1
  (( a == 192 && b == 168 )) && return 1
  (( a == 172 && b >= 16 && b <= 31 )) && return 1
  (( a >= 224 )) && return 1
  return 0
}

host_has_public_ip(){
  local ip found=1
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    if is_public_ipv4 "$ip"; then found=0; break; fi
  done < <(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u)
  return "$found"
}

probe_reality_target(){
  local host="$1" tmp
  [[ "$host" != "$NODE_DOMAIN" ]] || return 1
  host_has_public_ip "$host" || return 1

  tmp="$(mktemp)"
  if ! timeout 10 openssl s_client -connect "${host}:443" -servername "$host" -tls1_3 -alpn h2 </dev/null >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  if ! openssl x509 -in "$tmp" -noout -checkhost "$host" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  return 0
}

choose_auto_camouflage(){
  local candidates=(
    www.microsoft.com
    www.cloudflare.com
    www.apple.com
    www.amazon.com
    www.samsung.com
    www.yahoo.com
    www.bing.com
  )
  local start i candidate
  start=$((16#$(openssl rand -hex 2) % ${#candidates[@]}))
  for ((i=0; i<${#candidates[@]}; i++)); do
    candidate="${candidates[$(((start+i)%${#candidates[@]}))]}"
    if probe_reality_target "$candidate"; then
      REALITY_SNI="$candidate"
      REALITY_TARGET="${candidate}:443"
      return 0
    fi
  done
  return 1
}

resolve_reality_route(){
  REALITY_SNI="${REALITY_SNI:-}"
  REALITY_TARGET="${REALITY_TARGET:-}"
  local saved_version=""
  [[ -r "$REALITY_ROUTE_VERSION_FILE" ]] && saved_version="$(tr -d '[:space:]' < "$REALITY_ROUTE_VERSION_FILE")"

  case "$REALITY_SNI_MODE" in
    rotate)
      REALITY_SNI=''
      REALITY_TARGET=''
      ;;
    manual)
      if [[ -z "$REALITY_SNI" ]]; then
        read -r -p "REALITY camouflage SNI (например www.microsoft.com): " REALITY_SNI
      fi
      [[ -n "$REALITY_SNI" ]] || fail "Camouflage SNI пуст"
      REALITY_TARGET="${REALITY_TARGET:-${REALITY_SNI}:443}"
      probe_reality_target "$REALITY_SNI" || fail "SNI $REALITY_SNI не прошел проверку: нужен публичный HTTPS target с TLS1.3 и валидным сертификатом"
      ;;
    keep|auto)
      if [[ "$REALITY_SNI_MODE" == keep && "$saved_version" == "$REALITY_ROUTE_VERSION" ]]; then
        [[ -z "$REALITY_SNI" && -r "$REALITY_SNI_FILE" ]] && REALITY_SNI="$(tr -d '[:space:]' < "$REALITY_SNI_FILE")"
        [[ -z "$REALITY_TARGET" && -r "$REALITY_TARGET_FILE" ]] && REALITY_TARGET="$(tr -d '[:space:]' < "$REALITY_TARGET_FILE")"
      elif [[ "$REALITY_SNI_MODE" == keep && -n "$saved_version" && "$saved_version" != "$REALITY_ROUTE_VERSION" ]]; then
        warn "Формат REALITY camouflage route обновлен: подбираю target заново один раз"
      fi
      ;;
    *) fail "REALITY_SNI_MODE должен быть keep/auto/rotate/manual" ;;
  esac

  if [[ -n "$REALITY_SNI" && -n "$REALITY_TARGET" ]]; then
    if ! probe_reality_target "$REALITY_SNI"; then
      warn "Сохраненный camouflage target $REALITY_SNI больше не проходит проверку — выбираю новый"
      REALITY_SNI=''
      REALITY_TARGET=''
    fi
  fi

  if [[ -z "$REALITY_SNI" || -z "$REALITY_TARGET" ]]; then
    choose_auto_camouflage || fail "Не удалось подобрать REALITY camouflage target с TLS1.3 и валидным сертификатом"
  fi

  [[ "$REALITY_TARGET" == "${REALITY_SNI}:443" ]] || fail "Для этой схемы REALITY target должен совпадать с camouflage SNI: ${REALITY_SNI}:443"
  [[ "$REALITY_SNI" != "$NODE_DOMAIN" ]] || fail "REALITY SNI не должен совпадать с доменом SelfSteal — nginx не сможет разделить трафик"

  printf '%s\n' "$REALITY_SNI" > "$REALITY_SNI_FILE"
  printf '%s\n' "$REALITY_TARGET" > "$REALITY_TARGET_FILE"
  printf '%s\n' "$REALITY_ROUTE_VERSION" > "$REALITY_ROUTE_VERSION_FILE"
  chmod 600 "$REALITY_SNI_FILE" "$REALITY_TARGET_FILE" "$REALITY_ROUTE_VERSION_FILE"
}

check_files(){
  [[ -f "$APP_DIR/docker-compose.yml" ]] || fail "Не найден $APP_DIR/docker-compose.yml"
  [[ -s "$CERTS_DIR/fullchain.pem" ]] || fail "Нет $CERTS_DIR/fullchain.pem"
  [[ -s "$CERTS_DIR/privkey.pem" ]] || fail "Нет $CERTS_DIR/privkey.pem"
  [[ -s "$WEBROOT/index.html" ]] || fail "Нет $WEBROOT/index.html"
  openssl x509 -in "$CERTS_DIR/fullchain.pem" -noout >/dev/null 2>&1 || fail "Некорректный fullchain.pem"
  openssl pkey -in "$CERTS_DIR/privkey.pem" -noout >/dev/null 2>&1 || fail "Некорректный privkey.pem"
}

detect_stream_module(){
  local v
  v="$(docker run --rm "$NGINX_IMAGE" nginx -V 2>&1)" || fail "Не удалось проверить nginx -V"
  if grep -q -- '--with-stream=dynamic' <<< "$v"; then
    STREAM_LOAD='load_module modules/ngx_stream_module.so;'
  elif grep -q -- '--with-stream' <<< "$v"; then
    STREAM_LOAD=''
  else
    fail "В образе $NGINX_IMAGE нет nginx stream module"
  fi
}

write_nginx(){
  cat > "$NGINX_MAIN_CONF" <<EOF
${STREAM_LOAD}
worker_processes auto;
pid /var/run/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections 4096;
}

stream {
    map \$ssl_preread_server_name \$tcp_backend {
        ${REALITY_SNI} 127.0.0.1:${XRAY_TCP_PORT};
        default 127.0.0.1:${SELFSTEAL_PORT};
    }

    server {
        listen 0.0.0.0:${PUBLIC_TCP_PORT} reuseport;
        listen [::]:${PUBLIC_TCP_PORT} reuseport;
        ssl_preread on;
        proxy_connect_timeout 5s;
        proxy_timeout 300s;
        proxy_pass \$tcp_backend;
    }
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    server_tokens off;
    access_log /var/log/nginx/access.log;

    server {
        listen 127.0.0.1:${SELFSTEAL_PORT} ssl;
        server_name ${NODE_DOMAIN};

        ssl_protocols TLSv1.2;
        ssl_certificate /etc/nginx/ssl/fullchain.pem;
        ssl_certificate_key /etc/nginx/ssl/privkey.pem;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 10m;

        add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;

        root /var/www/html;
        index index.html;
        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF
  chmod 600 "$NGINX_MAIN_CONF"
}

write_override(){
  [[ -f "$OVERRIDE_FILE" ]] && cp -a "$OVERRIDE_FILE" "$OVERRIDE_FILE.bak.$(date +%Y%m%d-%H%M%S)"
  cat > "$OVERRIDE_FILE" <<EOF
services:
  remnanode:
    volumes:
      - $CERTS_DIR:/etc/xray/certs:ro

  remnawave-nginx:
    volumes:
      - ./nginx-main.conf:/etc/nginx/nginx.conf:ro
      - $WEBROOT:/var/www/html:ro
      - $CERTS_DIR:/etc/nginx/ssl:ro
      - $LOG_DIR/nginx:/var/log/nginx
EOF
}

validate(){
  (cd "$APP_DIR" && docker compose config >/dev/null) || fail "docker compose config не прошел проверку"
  docker run --rm --network host \
    -v "$NGINX_MAIN_CONF:/etc/nginx/nginx.conf:ro" \
    -v "$WEBROOT:/var/www/html:ro" \
    -v "$CERTS_DIR:/etc/nginx/ssl:ro" \
    "$NGINX_IMAGE" nginx -t >/dev/null || fail "nginx -t не прошел проверку"
}

apply(){
  (
    cd "$APP_DIR"
    docker compose stop remnanode >/dev/null 2>&1 || true
    docker compose up -d remnawave-nginx >/dev/null
    docker compose up -d remnanode >/dev/null || true
  ) || fail "Не удалось применить frontend compose"

  docker exec remnanode test -s /etc/xray/certs/fullchain.pem >/dev/null 2>&1 || warn "remnanode еще не подтверждает cert mount"
  docker exec remnanode test -s /etc/xray/certs/privkey.pem >/dev/null 2>&1 || warn "remnanode еще не подтверждает key mount"
}

verify_loopback_policy(){
  local line
  line="$(ss -lntp 2>/dev/null | awk -v p=":${XRAY_TCP_PORT}" '$4 ~ p"$" {print; exit}')"
  [[ -z "$line" ]] && return 0
  if grep -Eq '127\.0\.0\.1:' <<< "$line"; then
    log "Xray internal TCP/${XRAY_TCP_PORT}: loopback only"
  else
    fail "Xray TCP/${XRAY_TCP_PORT} слушает не только loopback: $line"
  fi
}

verify(){
  local attempt local_code public_code owner=""
  for attempt in $(seq 1 20); do
    owner="$(ss -lntp 2>/dev/null | awk -v p=":${PUBLIC_TCP_PORT}" '$4 ~ p"$" {print $0; exit}')"
    if grep -q 'nginx' <<< "$owner"; then break; fi
    sleep 1
  done
  grep -q 'nginx' <<< "$owner" || fail "TCP/${PUBLIC_TCP_PORT} не перешел под nginx frontend"

  local_code="$(curl -ksS --tls-max 1.2 --resolve "$NODE_DOMAIN:${SELFSTEAL_PORT}:127.0.0.1" -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "https://${NODE_DOMAIN}:${SELFSTEAL_PORT}/" 2>/dev/null || true)"
  [[ "$local_code" =~ ^[23][0-9][0-9]$ ]] || fail "Локальный SelfSteal backend не отвечает HTTP 2xx/3xx (код ${local_code:-000})"

  public_code="$(curl -ksS --tls-max 1.2 --resolve "$NODE_DOMAIN:${PUBLIC_TCP_PORT}:127.0.0.1" -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "https://${NODE_DOMAIN}/" 2>/dev/null || true)"
  [[ "$public_code" =~ ^[23][0-9][0-9]$ ]] || fail "Публичный SelfSteal через TCP/${PUBLIC_TCP_PORT} не отвечает (код ${public_code:-000})"

  verify_loopback_policy
  log "Public SelfSteal: https://${NODE_DOMAIN}/ -> HTTP ${public_code}"
  log "TCP/${PUBLIC_TCP_PORT}: nginx SNI frontend"
  log "REALITY camouflage route: configured (SNI скрыт в обычной диагностике)"
  log "Unknown/normal SNI -> SelfSteal TLS1.2"
  log "SelfSteal работает независимо от Config Profile Remnawave."
}

main(){
  echo '#################### НАЧАЛО ВЫВОДА: SELFSTEAL FRONTEND ####################'
  require_root
  resolve_domain
  resolve_reality_route
  check_files
  detect_stream_module
  write_nginx
  write_override
  validate
  apply
  verify
  echo '#################### КОНЕЦ ВЫВОДА: SELFSTEAL FRONTEND ####################'
}

main "$@"
