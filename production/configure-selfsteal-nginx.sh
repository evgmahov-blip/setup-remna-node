#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
CERTS_DIR="${CERTS_DIR:-$APP_DIR/certs}"
WEBROOT="${WEBROOT:-/var/www/html}"
LOG_DIR="${LOG_DIR:-/var/log/remnanode}"
SELFSTEAL_PORT="${SELFSTEAL_PORT:-8443}"
NGINX_CONF="$APP_DIR/nginx-selfsteal.conf"
OVERRIDE_FILE="$APP_DIR/docker-compose.override.yml"

log(){ printf '%s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запустите от root"; }

resolve_domain(){
  NODE_DOMAIN="${NODE_DOMAIN:-}"
  [[ -z "$NODE_DOMAIN" && -r "$APP_DIR/.node_domain" ]] && NODE_DOMAIN="$(tr -d '[:space:]' < "$APP_DIR/.node_domain")"
  [[ -n "$NODE_DOMAIN" ]] || read -r -p "Домен ноды: " NODE_DOMAIN
  [[ -n "$NODE_DOMAIN" ]] || fail "Домен не определен"
}

check_files(){
  [[ -f "$APP_DIR/docker-compose.yml" ]] || fail "Не найден $APP_DIR/docker-compose.yml"
  [[ -s "$CERTS_DIR/fullchain.pem" ]] || fail "Нет $CERTS_DIR/fullchain.pem"
  [[ -s "$CERTS_DIR/privkey.pem" ]] || fail "Нет $CERTS_DIR/privkey.pem"
  [[ -s "$WEBROOT/index.html" ]] || fail "Нет $WEBROOT/index.html"
}

write_nginx(){
  cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:${SELFSTEAL_PORT} ssl default_server;
    server_name ${NODE_DOMAIN};

    ssl_protocols TLSv1.2;
    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    server_tokens off;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
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
      - ./nginx-selfsteal.conf:/etc/nginx/conf.d/default.conf:ro
      - $WEBROOT:/var/www/html:ro
      - $CERTS_DIR:/etc/nginx/ssl:ro
      - $LOG_DIR/nginx:/var/log/nginx
EOF
}

validate(){
  (
    cd "$APP_DIR"
    docker compose config >/dev/null
  ) || fail "docker compose config не прошел проверку"

  docker run --rm --network host \
    -v "$NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" \
    -v "$WEBROOT:/var/www/html:ro" \
    -v "$CERTS_DIR:/etc/nginx/ssl:ro" \
    nginx:1.28 nginx -t >/dev/null || fail "nginx -t не прошел проверку"
}

apply(){
  (
    cd "$APP_DIR"
    docker compose up -d remnanode remnawave-nginx >/dev/null
  ) || fail "Не удалось применить compose"

  docker exec remnanode test -s /etc/xray/certs/fullchain.pem || fail "Сертификат не проброшен в remnanode"
  docker exec remnanode test -s /etc/xray/certs/privkey.pem || fail "Ключ не проброшен в remnanode"
}

verify(){
  local i
  for i in $(seq 1 20); do
    if ss -lntH 2>/dev/null | grep -q "127.0.0.1:${SELFSTEAL_PORT}"; then
      log "SelfSteal backend: 127.0.0.1:${SELFSTEAL_PORT} TLS1.2"
      log "Hysteria2 cert mount: $CERTS_DIR -> /etc/xray/certs:ro"
      return 0
    fi
    sleep 1
  done
  fail "Nginx не начал слушать 127.0.0.1:${SELFSTEAL_PORT}"
}

main(){
  echo '#################### НАЧАЛО ВЫВОДА: SELFSTEAL BACKEND ####################'
  require_root
  resolve_domain
  check_files
  write_nginx
  write_override
  validate
  apply
  verify
  echo '#################### КОНЕЦ ВЫВОДА: SELFSTEAL BACKEND ####################'
}

main "$@"
