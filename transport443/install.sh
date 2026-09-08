#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="/opt/remnanode"
NGINX_MAIN="$APP_DIR/nginx-main.conf"
OVERRIDE_FILE="$APP_DIR/docker-compose.override.yml"
STATE_FILE="$APP_DIR/.transport443"
BACKUP_DIR="$APP_DIR/backups/transport443"

VISION_PORT="10443"
XHTTP_PORT="11443"
GRPC_PORT="12443"
HYSTERIA_PORT="443"

log() { printf '%s\n' "$*"; }
fail() { log "[ERROR] $*" >&2; return 1; }

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запустите скрипт от root"
}

require_node() {
    [[ -f "$APP_DIR/docker-compose.yml" ]] || fail "Не найден $APP_DIR/docker-compose.yml. Сначала установите Remnanode."
    [[ -f "$APP_DIR/nginx.conf" ]] || fail "Не найден $APP_DIR/nginx.conf"
    command -v docker >/dev/null 2>&1 || fail "Docker не найден"
}

read_node_domain() {
    local domain=""
    if [[ -r "$APP_DIR/.node_domain" ]]; then
        domain=$(tr -d '[:space:]' < "$APP_DIR/.node_domain")
    fi
    if [[ -z "$domain" ]]; then
        read -r -p "Домен ноды: " domain
    fi
    [[ -n "$domain" ]] || fail "Домен ноды не определен"
    NODE_DOMAIN="$domain"
}

prompt_sni() {
    local default_vision="vision.${NODE_DOMAIN}"
    local default_xhttp="xhttp.${NODE_DOMAIN}"
    local default_grpc="grpc.${NODE_DOMAIN}"

    read -r -p "SNI для Vision [$default_vision]: " VISION_SNI
    VISION_SNI=${VISION_SNI:-$default_vision}
    read -r -p "SNI для XHTTP [$default_xhttp]: " XHTTP_SNI
    XHTTP_SNI=${XHTTP_SNI:-$default_xhttp}
    read -r -p "SNI для gRPC [$default_grpc]: " GRPC_SNI
    GRPC_SNI=${GRPC_SNI:-$default_grpc}

    [[ "$VISION_SNI" != "$XHTTP_SNI" ]] || fail "Vision и XHTTP должны иметь разные SNI"
    [[ "$VISION_SNI" != "$GRPC_SNI" ]] || fail "Vision и gRPC должны иметь разные SNI"
    [[ "$XHTTP_SNI" != "$GRPC_SNI" ]] || fail "XHTTP и gRPC должны иметь разные SNI"
}

check_ports() {
    local p
    for p in "$VISION_PORT" "$XHTTP_PORT" "$GRPC_PORT"; do
        if ss -ltnH "sport = :$p" 2>/dev/null | grep -q .; then
            fail "TCP порт $p уже занят. Освободите его или измените внутреннюю схему."
        fi
    done

    # UDP/443 может быть уже занят только если Hysteria2 уже настроен. Не трогаем его автоматически.
    if ss -lunH 'sport = :443' 2>/dev/null | grep -q .; then
        log "[WARN] UDP/443 уже занят. Это нормально только если его слушает ваш Hysteria2/Xray."
    fi
}

backup_existing() {
    mkdir -p "$BACKUP_DIR"
    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    [[ -f "$NGINX_MAIN" ]] && cp -a "$NGINX_MAIN" "$BACKUP_DIR/nginx-main.conf.$stamp"
    [[ -f "$OVERRIDE_FILE" ]] && cp -a "$OVERRIDE_FILE" "$BACKUP_DIR/docker-compose.override.yml.$stamp"
    [[ -f "$STATE_FILE" ]] && cp -a "$STATE_FILE" "$BACKUP_DIR/.transport443.$stamp"
}

write_nginx_main() {
    cat > "$NGINX_MAIN" <<EOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /var/run/nginx.pid;

events {
    worker_connections 4096;
}

stream {
    map \$ssl_preread_server_name \$transport_backend {
        hostnames;
        ${VISION_SNI} 127.0.0.1:${VISION_PORT};
        ${XHTTP_SNI}  127.0.0.1:${XHTTP_PORT};
        ${GRPC_SNI}   127.0.0.1:${GRPC_PORT};
        default       127.0.0.1:${VISION_PORT};
    }

    server {
        listen 0.0.0.0:443 reuseport;
        proxy_pass \$transport_backend;
        ssl_preread on;
        proxy_connect_timeout 5s;
        proxy_timeout 300s;
    }
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;
    access_log /var/log/nginx/access.log;
    include /etc/nginx/conf.d/*.conf;
}
EOF
}

write_compose_override() {
    cat > "$OVERRIDE_FILE" <<'EOF'
services:
  remnawave-nginx:
    volumes:
      - ./nginx-main.conf:/etc/nginx/nginx.conf:ro
EOF
}

write_state() {
    cat > "$STATE_FILE" <<EOF
PUBLIC_TCP_PORT=443
PUBLIC_UDP_PORT=443
VISION_INTERNAL_PORT=${VISION_PORT}
VISION_SNI=${VISION_SNI}
XHTTP_INTERNAL_PORT=${XHTTP_PORT}
XHTTP_SNI=${XHTTP_SNI}
GRPC_INTERNAL_PORT=${GRPC_PORT}
GRPC_SNI=${GRPC_SNI}
HYSTERIA_UDP_PORT=${HYSTERIA_PORT}
EOF
}

configure_firewall() {
    if ! command -v ufw >/dev/null 2>&1; then
        log "[WARN] UFW не найден; правила firewall не изменены"
        return 0
    fi

    ufw allow 443/tcp comment 'Transport443 TCP mux' >/dev/null 2>&1 || true
    ufw allow 443/udp comment 'Transport443 Hysteria2' >/dev/null 2>&1 || true

    # Внутренние transport-порты должны быть доступны только локально.
    # Если они ранее были открыты скриптом как custom ports, удаляем только эти точные правила.
    local p
    for p in "$VISION_PORT" "$XHTTP_PORT" "$GRPC_PORT"; do
        ufw delete allow "$p"/tcp >/dev/null 2>&1 || true
        ufw delete allow "$p"/udp >/dev/null 2>&1 || true
        if [[ -f "$APP_DIR/.xray_ports" ]]; then
            sed -i "/^${p}$/d" "$APP_DIR/.xray_ports"
        fi
    done

    ufw reload >/dev/null 2>&1 || true
}

validate_compose() {
    (
        cd "$APP_DIR"
        docker compose config >/dev/null
    ) || fail "docker compose config не прошел проверку"
}

validate_nginx() {
    docker run --rm \
        --network host \
        -v "$NGINX_MAIN:/etc/nginx/nginx.conf:ro" \
        -v "$APP_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "$APP_DIR/nginx-extra:/etc/nginx/telemt-panel:ro" \
        -v "$APP_DIR:/opt/remnanode:ro" \
        -v "/opt/remnanode/certs:/etc/nginx/ssl:ro" \
        -v "/var/www/html:/var/www/html:ro" \
        -v "/dev/shm:/dev/shm:rw" \
        nginx:1.28 nginx -t >/dev/null || fail "nginx -t не прошел проверку"
}

apply_config() {
    (
        cd "$APP_DIR"
        docker compose up -d remnawave-nginx
    ) || fail "Не удалось применить nginx transport mux"
}

show_result() {
    cat <<EOF

==================== TRANSPORT 443 ====================
Внешние порты:
  TCP 443 -> Nginx stream SNI mux
  UDP 443 -> Hysteria2 напрямую в Xray

Внутренние TCP inbound Xray:
  Vision : 127.0.0.1:${VISION_PORT}  SNI=${VISION_SNI}
  XHTTP  : 127.0.0.1:${XHTTP_PORT}  SNI=${XHTTP_SNI}
  gRPC   : 127.0.0.1:${GRPC_PORT}  SNI=${GRPC_SNI}

Hysteria2:
  UDP 0.0.0.0:443

ВАЖНО:
  - три TCP inbound должны слушать только 127.0.0.1 на указанных внутренних портах;
  - в Remnawave Host внешний port для всех четырех транспортов указывается 443;
  - для трех TCP Host SNI должен совпадать со значениями выше;
  - SNI должны быть разными, иначе stream mux не сможет различить TCP-транспорты;
  - этот скрипт не меняет Config Profile Remnawave автоматически.
=======================================================
EOF
}

main() {
    echo '#################### НАЧАЛО ВЫВОДА: TRANSPORT443 ####################'
    require_root
    require_node
    read_node_domain
    prompt_sni
    check_ports
    backup_existing
    write_nginx_main
    write_compose_override
    write_state
    configure_firewall
    validate_compose
    validate_nginx
    apply_config
    show_result
    echo '#################### КОНЕЦ ВЫВОДА: TRANSPORT443 ####################'
}

main "$@"
