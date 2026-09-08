#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
LOG_DIR="${LOG_DIR:-/var/log/remnanode}"
CERTS_DIR="${CERTS_DIR:-$APP_DIR/certs}"
WEBROOT="${WEBROOT:-/var/www/html}"
NODE_IMAGE="${NODE_IMAGE:-ghcr.io/remnawave/node:latest}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.28}"
LOG_FILE="${LOG_FILE:-/var/log/remnanode-install.log}"

log(){ printf '%s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запустите от root"; }

run_logged(){
  local title="$1"; shift
  printf '[*] %s...\n' "$title"
  mkdir -p "$(dirname "$LOG_FILE")"
  if "$@" >>"$LOG_FILE" 2>&1; then
    printf '[OK] %s\n' "$title"
  else
    printf '[ERROR] %s\n' "$title" >&2
    tail -n 80 "$LOG_FILE" 2>/dev/null || true
    return 1
  fi
}

install_dependencies(){
  export DEBIAN_FRONTEND=noninteractive
  log "ОС: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  log "Лог установки пакетов: $LOG_FILE"

  run_logged "Обновление индекса APT" apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 update -y
  run_logged "Установка системных пакетов" apt-get install -y curl wget jq unzip tar cron logrotate ufw certbot ca-certificates gnupg python3-pip perl openssl iproute2

  if ! command -v docker >/dev/null 2>&1; then
    log "Docker не найден — устанавливаю официальный Docker CE"
    install -m 0755 -d /etc/apt/keyrings
    run_logged "Загрузка Docker GPG key" bash -c "curl -fsSL --proto '=https' --tls-max 1.2 --connect-timeout 10 --max-time 60 https://download.docker.com/linux/\$(. /etc/os-release; echo \$ID)/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
    chmod a+r /etc/apt/keyrings/docker.gpg
    . /etc/os-release
    local docker_os="$ID"
    [[ "$docker_os" == ubuntu || "$docker_os" == debian ]] || fail "Docker repo: неподдерживаемая ОС $docker_os"
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
      "$(dpkg --print-architecture)" "$docker_os" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
    run_logged "Обновление APT после добавления Docker repo" apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 update -y
    run_logged "Установка Docker CE" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    run_logged "Запуск Docker" systemctl enable --now docker
  else
    log "Docker уже установлен: $(docker --version 2>/dev/null || true)"
  fi

  docker compose version >/dev/null || fail "docker compose plugin не работает"
  log "Docker Compose: $(docker compose version 2>/dev/null || true)"
}

valid_ipv4(){
  local ip="$1" IFS=. a b c d
  read -r a b c d <<< "$ip" || return 1
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}

collect_params(){
  PANEL_IP="${PANEL_IP:-}"
  NODE_DOMAIN="${NODE_DOMAIN:-}"
  NODE_PORT="${NODE_PORT:-2222}"
  SECRET_KEY="${SECRET_KEY:-}"

  while ! valid_ipv4 "$PANEL_IP"; do read -r -p "IP панели Remnawave: " PANEL_IP; done
  while [[ -z "$NODE_DOMAIN" ]]; do read -r -p "Домен ноды (node.example.com): " NODE_DOMAIN; done
  [[ "$NODE_PORT" =~ ^[0-9]+$ ]] && (( NODE_PORT >= 1 && NODE_PORT <= 65535 )) || fail "Некорректный NODE_PORT"
  if [[ -z "$SECRET_KEY" ]]; then
    printf 'Вставьте SECRET_KEY/сертификат ноды из панели Remnawave: '
    read -r SECRET_KEY
  fi
  [[ -n "$SECRET_KEY" ]] || fail "SECRET_KEY пуст"
}

extract_base_domain(){ awk -F. '{if (NF>2) print $(NF-1)"."$NF; else print $0}' <<< "$1"; }

validate_cert_pair(){
  [[ -s "$CERTS_DIR/fullchain.pem" && -s "$CERTS_DIR/privkey.pem" ]] || return 1
  openssl x509 -in "$CERTS_DIR/fullchain.pem" -noout >/dev/null 2>&1 || return 1
  openssl pkey -in "$CERTS_DIR/privkey.pem" -noout >/dev/null 2>&1 || return 1
  local a b
  a="$(openssl x509 -in "$CERTS_DIR/fullchain.pem" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256)"
  b="$(openssl pkey -in "$CERTS_DIR/privkey.pem" -pubout -outform DER 2>/dev/null | openssl sha256)"
  [[ -n "$a" && "$a" == "$b" ]]
}

install_cert_files(){
  mkdir -p "$CERTS_DIR"
  install -m 0600 "$1" "$CERTS_DIR/fullchain.pem"
  install -m 0600 "$2" "$CERTS_DIR/privkey.pem"
  validate_cert_pair || fail "Сертификат и ключ не соответствуют друг другу"
}

issue_certificate(){
  mkdir -p "$CERTS_DIR"
  if validate_cert_pair; then
    local reuse
    read -r -p "Найден действующий PEM в $CERTS_DIR. Использовать его? [Y/n]: " reuse
    case "${reuse:-Y}" in [Nn]*) : ;; *) log "Используется существующий сертификат"; return 0 ;; esac
  fi

  printf '\nSSL-сертификат нужен SelfSteal TLS1.2 и опциональному Hysteria2:\n'
  printf '  1) Certbot Standalone / HTTP-01\n  2) Cloudflare DNS-01 (wildcard)\n  3) Gcore DNS-01 (wildcard)\n  4) Готовые локальные fullchain.pem + privkey.pem\n'
  local method email base wildcard source_cert source_key active_domain
  read -r -p "Выбор [1]: " method; method=${method:-1}
  base="$(extract_base_domain "$NODE_DOMAIN")"; wildcard="*.$base"; active_domain="$NODE_DOMAIN"

  case "$method" in
    1)
      read -r -p "Email для Let's Encrypt: " email; [[ -n "$email" ]] || fail "Email обязателен"
      docker stop remnawave-nginx >/dev/null 2>&1 || true
      systemctl stop nginx >/dev/null 2>&1 || true
      ufw allow 80/tcp comment 'Certbot HTTP-01' >/dev/null 2>&1 || true
      certbot certonly --standalone -d "$NODE_DOMAIN" --email "$email" --agree-tos --non-interactive --key-type ecdsa --elliptic-curve secp384r1 || fail "Certbot Standalone завершился ошибкой"
      install_cert_files "/etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem" "/etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem"
      ;;
    2)
      apt-get install -y python3-certbot-dns-cloudflare
      local cf_token
      read -r -s -p "Cloudflare API Token: " cf_token; echo
      [[ -n "$cf_token" ]] || fail "Cloudflare token пуст"
      read -r -p "Email для Let's Encrypt: " email; [[ -n "$email" ]] || fail "Email обязателен"
      install -d -m 0700 /root/.secrets/certbot
      printf 'dns_cloudflare_api_token = %s\n' "$cf_token" > /root/.secrets/certbot/cloudflare.ini
      chmod 600 /root/.secrets/certbot/cloudflare.ini
      certbot certonly --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini --dns-cloudflare-propagation-seconds 60 -d "$base" -d "$wildcard" --email "$email" --agree-tos --non-interactive --key-type ecdsa --elliptic-curve secp384r1 || fail "Cloudflare DNS-01 завершился ошибкой"
      active_domain="$base"
      install_cert_files "/etc/letsencrypt/live/$base/fullchain.pem" "/etc/letsencrypt/live/$base/privkey.pem"
      unset cf_token
      ;;
    3)
      python3 -m pip install --break-system-packages certbot-dns-gcore >/dev/null 2>&1 || python3 -m pip install certbot-dns-gcore
      local gc_token
      read -r -s -p "Gcore API Token: " gc_token; echo
      [[ -n "$gc_token" ]] || fail "Gcore token пуст"
      read -r -p "Email для Let's Encrypt: " email; [[ -n "$email" ]] || fail "Email обязателен"
      install -d -m 0700 /root/.secrets/certbot
      printf 'dns_gcore_apitoken = %s\n' "$gc_token" > /root/.secrets/certbot/gcore.ini
      chmod 600 /root/.secrets/certbot/gcore.ini
      certbot certonly --authenticator dns-gcore --dns-gcore-credentials /root/.secrets/certbot/gcore.ini --dns-gcore-propagation-seconds 80 -d "$base" -d "$wildcard" --email "$email" --agree-tos --non-interactive --key-type ecdsa --elliptic-curve secp384r1 || fail "Gcore DNS-01 завершился ошибкой"
      active_domain="$base"
      install_cert_files "/etc/letsencrypt/live/$base/fullchain.pem" "/etc/letsencrypt/live/$base/privkey.pem"
      unset gc_token
      ;;
    4)
      read -r -p "Путь к fullchain.pem: " source_cert
      read -r -p "Путь к privkey.pem: " source_key
      [[ -r "$source_cert" && -r "$source_key" ]] || fail "Файлы сертификата не найдены"
      install_cert_files "$source_cert" "$source_key"; active_domain=""
      ;;
    *) fail "Неизвестный метод SSL" ;;
  esac

  if [[ -n "$active_domain" ]]; then
    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/copy-remnanode-certs.sh <<EOF
#!/usr/bin/env bash
set -eu
if [ -s "/etc/letsencrypt/live/$active_domain/fullchain.pem" ] && [ -s "/etc/letsencrypt/live/$active_domain/privkey.pem" ]; then
  install -m 0600 "/etc/letsencrypt/live/$active_domain/fullchain.pem" "$CERTS_DIR/fullchain.pem"
  install -m 0600 "/etc/letsencrypt/live/$active_domain/privkey.pem" "$CERTS_DIR/privkey.pem"
  docker restart remnanode >/dev/null 2>&1 || true
  docker restart remnawave-nginx >/dev/null 2>&1 || true
fi
EOF
    chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/copy-remnanode-certs.sh
  fi
}

write_compose(){
  mkdir -p "$APP_DIR" "$LOG_DIR/node" "$LOG_DIR/nginx" "$WEBROOT" "$APP_DIR/nginx-extra"
  chmod 700 "$APP_DIR"; umask 077
  cat > "$APP_DIR/.env" <<EOF
NODE_PORT=$NODE_PORT
SECRET_KEY=$SECRET_KEY
XTLS_API_PORT=61000
EOF
  chmod 600 "$APP_DIR/.env"
  cat > "$APP_DIR/docker-compose.yml" <<EOF
services:
  remnanode:
    image: $NODE_IMAGE
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    cap_add: [NET_ADMIN]
    env_file: [.env]
    volumes:
      - /dev/shm:/dev/shm:rw
      - $LOG_DIR/node:/var/log/supervisor
      - $CERTS_DIR:/etc/xray/certs:ro
  remnawave-nginx:
    image: $NGINX_IMAGE
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - $APP_DIR/nginx-extra:/etc/nginx/telemt-panel:ro
      - $WEBROOT:/var/www/html:ro
      - $LOG_DIR/nginx:/var/log/nginx
      - $CERTS_DIR:/etc/nginx/ssl:ro
EOF
  cat > "$APP_DIR/nginx.conf" <<EOF
server {
  listen 127.0.0.1:8443 ssl default_server;
  server_name $NODE_DOMAIN;
  ssl_protocols TLSv1.2;
  ssl_certificate /etc/nginx/ssl/fullchain.pem;
  ssl_certificate_key /etc/nginx/ssl/privkey.pem;
  root /var/www/html;
  location / { try_files \$uri \$uri/ /index.html; }
}
EOF
  printf '%s\n' "$PANEL_IP" > "$APP_DIR/.panel_ip"
  printf '%s\n' "$NODE_DOMAIN" > "$APP_DIR/.node_domain"
  printf '%s\n' 'xhttp-reality' > "$APP_DIR/.protocol"
  chmod 600 "$APP_DIR/.panel_ip" "$APP_DIR/.node_domain" "$APP_DIR/.protocol"
  run_logged "Проверка docker compose" bash -c "cd '$APP_DIR' && docker compose config"
  run_logged "Запуск контейнера Remnanode" bash -c "cd '$APP_DIR' && docker compose up -d remnanode"
}

configure_firewall(){
  local ssh_port=22 detected=""
  ufw default deny incoming >/dev/null || true; ufw default allow outgoing >/dev/null || true
  detected="$(ss -lntp 2>/dev/null | awk '/sshd/ {sub(/^.*:/,"",$4); print $4; exit}')"
  [[ "$detected" =~ ^[0-9]+$ ]] && ssh_port="$detected"
  ufw allow "$ssh_port"/tcp comment 'SSH' >/dev/null
  ufw allow 80/tcp comment 'HTTP Certbot' >/dev/null
  ufw allow 443/tcp comment 'XHTTP Reality' >/dev/null
  ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'Remnanode Control from Panel' >/dev/null
  ufw --force enable >/dev/null; ufw reload >/dev/null || true
}

setup_logrotate(){
  cat > /etc/logrotate.d/remnanode <<EOF
$LOG_DIR/node/*.log $LOG_DIR/nginx/*.log {
  daily
  size 50M
  rotate 7
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
}
EOF
  chmod 644 /etc/logrotate.d/remnanode
}

main(){
  echo '#################### НАЧАЛО ВЫВОДА: BASE NODE ####################'
  require_root
  install_dependencies
  collect_params
  issue_certificate
  write_compose
  configure_firewall
  setup_logrotate
  log "Base Remnanode запущена. Домен: $NODE_DOMAIN; control: $NODE_PORT; cert mount: /etc/xray/certs:ro"
  echo '#################### КОНЕЦ ВЫВОДА: BASE NODE ####################'
}

main "$@"
