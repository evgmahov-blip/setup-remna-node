#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
WWW_DIR="${WWW_DIR:-/var/www/html}"
NGINX_CONF="${NGINX_CONF:-$APP_DIR/nginx.conf}"
NGINX_CONTAINER="${NGINX_CONTAINER:-remnawave-nginx}"
NGINX_SOCKET="${NGINX_SOCKET:-/dev/shm/nginx.sock}"
CACHE_DIR="${CACHE_DIR:-$APP_DIR/stream-audio-cache}"
SOURCE_MANIFEST="${SOURCE_MANIFEST:-$APP_DIR/stream-audio-sources.txt}"
STREAM_AUDIO_FIXTURE_DIR="${STREAM_AUDIO_FIXTURE_DIR:-}"
STREAM_SKIP_NGINX_PROXY="${STREAM_SKIP_NGINX_PROXY:-0}"
STREAM_AUDIO_MIN_BYTES="${STREAM_AUDIO_MIN_BYTES:-32768}"
STREAM_AUDIO_MAX_BYTES="${STREAM_AUDIO_MAX_BYTES:-104857600}"

RADIOBOOK_HOST="bookradio.hostingradio.ru"
RADIOBOOK_PORT="8069"
RADIOBOOK_PATH="/fm"
RADIOBOOK_URL="https://${RADIOBOOK_HOST}:${RADIOBOOK_PORT}${RADIOBOOK_PATH}"

TOLSTOY_TEACHINGS_URL="https://www.archive.org/download/teachingsofchrist_1204_librivox/teachingsofchrist_1_tolstoy_64kb.mp3"
TOLSTOY_CHILDHOOD_URL="https://www.archive.org/download/childhood_russian_librivox/Leo-Tolstoy-Detstvo-RUSSIAN-01-Karl-Ivanych_64kb.mp3"
BEETHOVEN_URL="https://upload.wikimedia.org/wikipedia/commons/transcoded/d/d0/Moonlight_Sonata.ogg/Moonlight_Sonata.ogg.mp3?download="
CHOPIN_URL="https://upload.wikimedia.org/wikipedia/commons/transcoded/0/04/Chopin_Nocturne_No._2_in_E_Flat_Major%2C_Op._9.ogg/Chopin_Nocturne_No._2_in_E_Flat_Major%2C_Op._9.ogg.mp3?download="
BACH_URL="https://upload.wikimedia.org/wikipedia/commons/transcoded/1/1e/Air_%28Bach%29.ogg/Air_%28Bach%29.ogg.mp3?download="

MARK_BEGIN="# BEGIN REMNANODE STREAM RADIOBOOK"
MARK_END="# END REMNANODE STREAM RADIOBOOK"

log(){ printf '%s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { fail 'Запусти от root'; return 1; }; }

validate_limits(){
  [[ "$STREAM_AUDIO_MIN_BYTES" =~ ^[0-9]+$ ]] || { fail 'STREAM_AUDIO_MIN_BYTES должен быть целым числом'; return 1; }
  [[ "$STREAM_AUDIO_MAX_BYTES" =~ ^[0-9]+$ ]] || { fail 'STREAM_AUDIO_MAX_BYTES должен быть целым числом'; return 1; }
  (( STREAM_AUDIO_MIN_BYTES >= 1 && STREAM_AUDIO_MAX_BYTES > STREAM_AUDIO_MIN_BYTES )) || { fail 'Некорректные лимиты размера audio'; return 1; }
  [[ "$STREAM_SKIP_NGINX_PROXY" == 0 || "$STREAM_SKIP_NGINX_PROXY" == 1 ]] || { fail 'STREAM_SKIP_NGINX_PROXY допустим только 0 или 1'; return 1; }
}

node_domain(){
  local d
  d="$(tr -d '[:space:]' < "$APP_DIR/.node_domain" 2>/dev/null || true)"
  [[ "$d" =~ ^[A-Za-z0-9.-]+$ ]] || { fail 'Не удалось определить безопасный домен ноды из .node_domain'; return 1; }
  printf '%s' "$d"
}

file_size(){ stat -c %s -- "$1" 2>/dev/null || printf '0'; }

valid_audio_file(){
  local f="$1" size
  [[ -s "$f" ]] || return 1
  size="$(file_size "$f")"
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  (( size >= STREAM_AUDIO_MIN_BYTES && size <= STREAM_AUDIO_MAX_BYTES )) || return 1
  if head -c 1024 "$f" 2>/dev/null | LC_ALL=C grep -aEqi '<!doctype|<html|<body'; then return 1; fi
  return 0
}

fetch_audio(){
  local name="$1" url="$2" dst="$3" fixture part
  mkdir -p "$CACHE_DIR"
  fixture="${STREAM_AUDIO_FIXTURE_DIR%/}/$name"
  if [[ -n "$STREAM_AUDIO_FIXTURE_DIR" ]]; then
    [[ -r "$fixture" ]] || { fail "CI fixture отсутствует: $fixture"; return 1; }
    cp -f -- "$fixture" "$dst"
    valid_audio_file "$dst" || { rm -f "$dst"; fail "CI fixture не прошёл audio validation: $name"; return 1; }
    return 0
  fi
  if valid_audio_file "$dst"; then log "[OK] audio cache: $name ($(file_size "$dst") bytes)"; return 0; fi
  part="${dst}.part"
  rm -f -- "$part"
  log "[INFO] Загружаю локальный audio asset: $name"
  if ! curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --connect-timeout 15 --max-time 600 --retry 2 --retry-delay 2 \
      "$url" -o "$part"; then
    rm -f -- "$part"; fail "Не удалось скачать audio asset: $name"; return 1
  fi
  if ! valid_audio_file "$part"; then rm -f "$part"; fail "Скачанный файл не похож на допустимый audio asset: $name"; return 1; fi
  chmod 0644 "$part"
  mv -f -- "$part" "$dst"
  log "[OK] audio asset: $name ($(file_size "$dst") bytes)"
}

prepare_audio_cache(){
  mkdir -p "$CACHE_DIR"
  fetch_audio 'tolstoy-teachings-ch01.mp3' "$TOLSTOY_TEACHINGS_URL" "$CACHE_DIR/tolstoy-teachings-ch01.mp3" || return 1
  fetch_audio 'tolstoy-childhood-ch01.mp3' "$TOLSTOY_CHILDHOOD_URL" "$CACHE_DIR/tolstoy-childhood-ch01.mp3" || return 1
  fetch_audio 'beethoven-moonlight.mp3' "$BEETHOVEN_URL" "$CACHE_DIR/beethoven-moonlight.mp3" || return 1
  fetch_audio 'chopin-nocturne.mp3' "$CHOPIN_URL" "$CACHE_DIR/chopin-nocturne.mp3" || return 1
  fetch_audio 'bach-air.mp3' "$BACH_URL" "$CACHE_DIR/bach-air.mp3" || return 1
}

patch_frontend(){
  local file="$1"
  command -v python3 >/dev/null 2>&1 || { fail 'Для безопасного STREAM frontend patch нужен python3'; return 1; }
  python3 - "$file" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1]); s=p.read_text(encoding="utf-8")
s,n1=re.subn(r'const\s+HEALTH_API\s*=\s*"[^"]*"\s*;','const HEALTH_API = "/data/streams.json";',s,count=1)
s,n2=re.subn(r'const\s+HISTORY_API\s*=\s*"[^"]*"\s*;','const HISTORY_API = "/data/history.json";',s,count=1)
s,n3=re.subn(r'const\s+STREAM_ORIGIN\s*=\s*[^;]+;','const STREAM_ORIGIN = window.location.origin;',s,count=1)
if not (n1 and n2 and n3): raise SystemExit("missing STREAM API/origin markers")
if "information.stream_url" not in s:
    old='url: STREAM_ORIGIN + normalizedMount,'
    new='''url:\n                        typeof information.stream_url === "string" &&\n                        information.stream_url.trim()\n                            ? information.stream_url.trim()\n                            : STREAM_ORIGIN + normalizedMount,'''
    if old not in s: raise SystemExit("missing STREAM url marker")
    s=s.replace(old,new,1)
rx=re.compile(r'(class="[^"]*\$\{\s*)u[0-9a-f]{6,16}(\s*\?\s*"\s+active"\s*:\s*""\s*\})',re.S)
s=rx.sub(r'\1active\2',s,count=1)
if 'data-sort="listeners"' in s and 'state.sort === "listeners"' not in s:
    s=re.sub(r'(state\.sort\s*===\s*)"u[0-9a-f]{6,16}"',r'\1"listeners"',s,count=1)
p.write_text(s,encoding="utf-8")
PY
}

write_catalog(){
  local out="$1"
  command -v jq >/dev/null 2>&1 || { fail 'Для STREAM нужен jq'; return 1; }
  jq -n --argjson generated "$(date +%s)" '
    {generated:$generated,mounts:{
      "/radio-book":{status:"Active",listener_count:0,format:{bitrate:256,content_type:"audio/mpeg"},metadata:{now_playing:"Радио Книга — прямой литературный эфир"},stream_url:"/audio/radio-book"},
      "/tolstoy-teachings":{status:"Active",listener_count:0,format:{bitrate:64,content_type:"audio/mpeg"},metadata:{now_playing:"Лев Толстой — Учение Христа, изложенное для детей · главы 1–3"},stream_url:"/audio/tolstoy-teachings-ch01.mp3"},
      "/tolstoy-childhood":{status:"Active",listener_count:0,format:{bitrate:64,content_type:"audio/mpeg"},metadata:{now_playing:"Лев Толстой — Детство · Карл Иваныч"},stream_url:"/audio/tolstoy-childhood-ch01.mp3"},
      "/beethoven-moonlight":{status:"Active",listener_count:0,format:{bitrate:128,content_type:"audio/mpeg"},metadata:{now_playing:"Beethoven — Moonlight Sonata"},stream_url:"/audio/beethoven-moonlight.mp3"},
      "/chopin-nocturne":{status:"Active",listener_count:0,format:{bitrate:128,content_type:"audio/mpeg"},metadata:{now_playing:"Chopin — Nocturne No. 2 in E-flat Major"},stream_url:"/audio/chopin-nocturne.mp3"},
      "/bach-air":{status:"Active",listener_count:0,format:{bitrate:128,content_type:"audio/mpeg"},metadata:{now_playing:"J. S. Bach — Air"},stream_url:"/audio/bach-air.mp3"}
    }}' > "$out"
}

validate_staged_site(){
  local root="$1" f
  command -v jq >/dev/null 2>&1 || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  [[ -s "$root/index.html" && -s "$root/data/streams.json" && -s "$root/data/history.json" ]] || return 1
  jq -e '(.mounts|length)==6 and ([.mounts[].stream_url|startswith("/audio/")]|all) and ([.mounts[].stream_url|contains("://")|not]|all) and ([.mounts[].listener_count]|all(.==0))' "$root/data/streams.json" >/dev/null || return 1
  jq -e '.history == []' "$root/data/history.json" >/dev/null || return 1
  if ! python3 - "$root/index.html" <<'PY'
from pathlib import Path
import re, sys
s=Path(sys.argv[1]).read_text(encoding="utf-8")
for item in ['const HEALTH_API = "/data/streams.json";','const HISTORY_API = "/data/history.json";','const STREAM_ORIGIN = window.location.origin;','information.stream_url','state.sort === "listeners"']:
    if item not in s: raise SystemExit(f"missing frontend invariant: {item}")
if not re.search(r'\$\{\s*active\s*\?',s,re.S): raise SystemExit('dynamic active JS expression missing')
if re.search(r'\$\{\s*u[0-9a-f]{6,16}\s*\?',s,re.S): raise SystemExit('mutated JS runtime token remains')
PY
  then return 1; fi
  if grep -Eqi 'deepbeat|bookradio\.hostingradio\.ru|archive\.org|upload\.wikimedia\.org' "$root/index.html" "$root/data/streams.json"; then return 1; fi
  for f in tolstoy-teachings-ch01.mp3 tolstoy-childhood-ch01.mp3 beethoven-moonlight.mp3 chopin-nocturne.mp3 bach-air.mp3; do valid_audio_file "$root/audio/$f" || return 1; done
}

remove_managed_nginx_block(){
  local file="$1"
  python3 - "$file" "$MARK_BEGIN" "$MARK_END" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1]); begin,end=sys.argv[2],sys.argv[3]
s=p.read_text(encoding="utf-8")
s=re.sub(r'\n?[ \t]*'+re.escape(begin)+r'.*?'+re.escape(end)+r'[ \t]*\n?','\n',s,flags=re.S)
p.write_text(s,encoding="utf-8")
PY
}

probe_radio_book_proxy(){
  local domain="$1" hdr body rc status ctype bytes sample
  command -v curl >/dev/null 2>&1 || { fail 'curl не найден для fail-closed Radio Book probe'; return 1; }
  [[ -S "$NGINX_SOCKET" ]] || { fail "nginx unix socket не найден: $NGINX_SOCKET"; return 1; }
  hdr="$(mktemp)"; body="$(mktemp)"
  if curl -sS --unix-socket "$NGINX_SOCKET" --connect-timeout 3 --max-time 6 \
      -H "Host: $domain" -D "$hdr" -o "$body" 'http://localhost/audio/radio-book'; then
    rc=0
  else
    rc=$?
  fi
  status="$(awk 'toupper($1) ~ /^HTTP\// {code=$2} END{print code}' "$hdr" 2>/dev/null || true)"
  ctype="$(awk -F': *' 'tolower($1)=="content-type" {v=$2} END{gsub(/\r/,"",v); print tolower(v)}' "$hdr" 2>/dev/null || true)"
  bytes="$(wc -c < "$body" 2>/dev/null || printf '0')"
  if [[ "$status" == 200 && "$ctype" == audio/* && "$bytes" =~ ^[0-9]+$ ]] && (( bytes >= 1024 )); then
    rm -f -- "$hdr" "$body"
    log "[OK] Radio Book proxy probe: HTTP $status, $ctype, ${bytes} bytes через $NGINX_SOCKET"
    return 0
  fi
  sample="$(head -c 256 "$body" 2>/dev/null | tr '\r\n' '  ' | tr -cd '[:print:] ' || true)"
  rm -f -- "$hdr" "$body"
  fail "Radio Book proxy probe FAIL: curl_rc=$rc http=${status:-none} type=${ctype:-none} bytes=${bytes:-0} body=${sample:-empty}"
  return 1
}

ensure_radio_book_proxy(){
  local domain backup tmp
  [[ "$STREAM_SKIP_NGINX_PROXY" == 1 ]] && { log '[CI] nginx Radio Book proxy skipped'; return 0; }
  command -v docker >/dev/null 2>&1 || { fail 'docker не найден'; return 1; }
  command -v python3 >/dev/null 2>&1 || { fail 'python3 не найден'; return 1; }
  [[ -s "$NGINX_CONF" ]] || { fail "nginx config не найден: $NGINX_CONF"; return 1; }
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$NGINX_CONTAINER" || { fail "nginx container не запущен: $NGINX_CONTAINER"; return 1; }
  docker exec "$NGINX_CONTAINER" test -r /etc/ssl/certs/ca-certificates.crt || { fail 'В nginx container нет CA bundle; TLS verify отключать не буду'; return 1; }
  domain="$(node_domain)" || return 1
  backup="${NGINX_CONF}.safe-audio.bak.$(date +%Y%m%d-%H%M%S)"; tmp="${NGINX_CONF}.safe-audio.tmp"
  cp -a -- "$NGINX_CONF" "$backup"; cp -a -- "$NGINX_CONF" "$tmp"; remove_managed_nginx_block "$tmp"
  if ! python3 - "$tmp" "$domain" "$MARK_BEGIN" "$MARK_END" "$RADIOBOOK_HOST" "$RADIOBOOK_PORT" "$RADIOBOOK_PATH" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1]); domain,begin,end,host,port,path=sys.argv[2:]; s=p.read_text(encoding="utf-8")
target=None
for m in re.finditer(r'(?ms)^server\s*\{.*?^\}',s):
    if re.search(r'(?m)^\s*server_name\s+'+re.escape(domain)+r'\s*;',m.group(0)): target=m; break
if target is None: raise SystemExit(f"domain server block not found: {domain}")
block=target.group(0); loc=re.search(r'(?m)^([ \t]*)location\s+/\s*\{',block)
if not loc: raise SystemExit("location / not found in domain server block")
indent=loc.group(1); inner=indent+"    "
managed=f'''{indent}{begin}\n{indent}location = /audio/radio-book {{\n{inner}proxy_pass https://{host}:{port}{path};\n{inner}proxy_http_version 1.1;\n{inner}proxy_pass_request_headers off;\n{inner}proxy_set_header Host {host}:{port};\n{inner}proxy_set_header Connection "";\n{inner}proxy_set_header User-Agent "Mozilla/5.0 (compatible; RemnanodeAudio/1.0)";\n{inner}proxy_set_header Referer "";\n{inner}proxy_set_header Origin "";\n{inner}proxy_set_header Cookie "";\n{inner}proxy_set_header Authorization "";\n{inner}proxy_ssl_server_name on;\n{inner}proxy_ssl_name {host};\n{inner}proxy_ssl_verify on;\n{inner}proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;\n{inner}proxy_buffering off;\n{inner}proxy_request_buffering off;\n{inner}proxy_cache off;\n{inner}proxy_hide_header Location;\n{inner}proxy_hide_header Refresh;\n{inner}proxy_hide_header Set-Cookie;\n{inner}proxy_read_timeout 1h;\n{inner}proxy_send_timeout 1h;\n{inner}add_header Cache-Control "no-store" always;\n{inner}add_header X-Content-Type-Options "nosniff" always;\n{indent}}}\n{indent}{end}\n\n'''
pos=target.start()+loc.start(); s=s[:pos]+managed+s[pos:]; p.write_text(s,encoding="utf-8")
PY
  then rm -f -- "$tmp"; fail 'Не удалось безопасно вставить Radio Book proxy в доменный server block'; return 1; fi
  mv -f -- "$tmp" "$NGINX_CONF"
  if ! docker exec "$NGINX_CONTAINER" nginx -t >/dev/null 2>&1; then cp -a -- "$backup" "$NGINX_CONF"; docker exec "$NGINX_CONTAINER" nginx -t >/dev/null 2>&1 || true; fail "nginx -t не прошёл; восстановлен backup $backup"; return 1; fi
  if ! docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null 2>&1; then cp -a -- "$backup" "$NGINX_CONF"; docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null 2>&1 || true; fail "nginx reload не прошёл; восстановлен backup $backup"; return 1; fi
  if ! probe_radio_book_proxy "$domain"; then
    cp -a -- "$backup" "$NGINX_CONF"
    docker exec "$NGINX_CONTAINER" nginx -t >/dev/null 2>&1 || true
    docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null 2>&1 || true
    fail "Radio Book proxy не прошёл live-probe; восстановлен backup $backup"
    return 1
  fi
  log '[OK] Radio Book: same-origin reverse proxy /audio/radio-book, upstream TLS verify=ON, Host включает :8069, client headers stripped'
  log "[INFO] nginx backup: $backup"
}

write_source_manifest(){
  mkdir -p "$APP_DIR"
  cat > "$SOURCE_MANIFEST" <<EOF
REMNANODE STREAM SAFE AUDIO SOURCES
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Browser-visible URLs are same-origin /audio/* only.
External source URLs below are server-side acquisition/proxy sources and are NOT published in streams.json or index.html.

LIVE RADIO
Radio Book: $RADIOBOOK_URL
Note: technical same-origin proxy only; redistribution/rebroadcast rights are not asserted by this script.

LOCAL AUDIOBOOK CACHE
Лев Толстой — Учение Христа, изложенное для детей, главы 1–3 (LibriVox / Internet Archive):
$TOLSTOY_TEACHINGS_URL
LibriVox recordings are public domain in the USA; check local copyright status where applicable.

Лев Толстой — Детство, Карл Иваныч (LibriVox / Internet Archive):
$TOLSTOY_CHILDHOOD_URL
LibriVox recordings are public domain in the USA; check local copyright status where applicable.

LOCAL MUSIC CACHE
Beethoven — Moonlight Sonata (Wikimedia Commons public-domain source):
$BEETHOVEN_URL

Chopin — Nocturne No. 2 (Wikimedia Commons source):
$CHOPIN_URL

J. S. Bach — Air (Wikimedia Commons public-domain source):
$BACH_URL
EOF
  chmod 0600 "$SOURCE_MANIFEST"
}

publish_staged_site(){
  local staged="$1" backup tmp f
  backup="$APP_DIR/stream-safe-backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$backup" "$WWW_DIR/data" "$WWW_DIR/audio"
  [[ -e "$WWW_DIR/index.html" ]] && cp -a -- "$WWW_DIR/index.html" "$backup/index.html"
  [[ -e "$WWW_DIR/data/streams.json" ]] && cp -a -- "$WWW_DIR/data/streams.json" "$backup/streams.json"
  [[ -e "$WWW_DIR/data/history.json" ]] && cp -a -- "$WWW_DIR/data/history.json" "$backup/history.json"
  tmp="$WWW_DIR/.index.html.safe-audio.tmp"; install -m 0644 "$staged/index.html" "$tmp"; mv -f -- "$tmp" "$WWW_DIR/index.html"
  for f in streams.json history.json; do tmp="$WWW_DIR/data/.${f}.safe-audio.tmp"; install -m 0644 "$staged/data/$f" "$tmp"; mv -f -- "$tmp" "$WWW_DIR/data/$f"; done
  for f in tolstoy-teachings-ch01.mp3 tolstoy-childhood-ch01.mp3 beethoven-moonlight.mp3 chopin-nocturne.mp3 bach-air.mp3; do tmp="$WWW_DIR/audio/.${f}.safe-audio.tmp"; install -m 0644 "$staged/audio/$f" "$tmp"; mv -f -- "$tmp" "$WWW_DIR/audio/$f"; done
  log "[OK] STREAM safe-audio опубликован; backup предыдущих frontend/data: $backup"
}

install_safe_audio(){
  local staged f
  validate_limits || return 1
  [[ -s "$WWW_DIR/index.html" ]] || { fail "Текущий STREAM index.html не найден: $WWW_DIR/index.html"; return 1; }
  prepare_audio_cache || return 1
  staged="$(mktemp -d)"; mkdir -p "$staged/data" "$staged/audio"
  if ! cp -a -- "$WWW_DIR/index.html" "$staged/index.html" || ! patch_frontend "$staged/index.html" || ! write_catalog "$staged/data/streams.json"; then rm -rf -- "$staged"; fail 'Не удалось собрать staged safe-audio site'; return 1; fi
  printf '{"history":[]}\n' > "$staged/data/history.json"
  for f in tolstoy-teachings-ch01.mp3 tolstoy-childhood-ch01.mp3 beethoven-moonlight.mp3 chopin-nocturne.mp3 bach-air.mp3; do if ! cp -a -- "$CACHE_DIR/$f" "$staged/audio/$f"; then rm -rf -- "$staged"; fail "Не удалось staged-copy: $f"; return 1; fi; done
  if ! validate_staged_site "$staged"; then rm -rf -- "$staged"; fail 'Staged safe-audio site не прошёл fail-closed validation'; return 1; fi
  if ! ensure_radio_book_proxy; then rm -rf -- "$staged"; return 1; fi
  if ! publish_staged_site "$staged"; then rm -rf -- "$staged"; return 1; fi
  rm -rf -- "$staged"; write_source_manifest
  printf '%s\n' 'safe-audio' > "$APP_DIR/.stream_audio_mode"; chmod 0600 "$APP_DIR/.stream_audio_mode"
  log '[OK] Browser policy: только same-origin /data/* и /audio/*; внешних audio/API origin в frontend/catalog нет'
  log '[OK] 6 каналов: 1 Radio Book proxy + 2 локальных русских LibriVox + 3 локальных public-domain/Commons music'
}

status_safe_audio(){
  local bad=0 f
  echo 'STREAM SAFE AUDIO STATUS'
  if [[ -s "$WWW_DIR/data/streams.json" ]] && jq -e '(.mounts|length)==6 and ([.mounts[].stream_url|startswith("/audio/")]|all) and ([.mounts[].stream_url|contains("://")|not]|all)' "$WWW_DIR/data/streams.json" >/dev/null 2>&1; then echo '[OK] streams.json: 6 same-origin channels'; else echo '[FAIL] streams.json'; bad=1; fi
  if grep -Eqi 'deepbeat|bookradio\.hostingradio\.ru|archive\.org|upload\.wikimedia\.org' "$WWW_DIR/index.html" "$WWW_DIR/data/streams.json" 2>/dev/null; then echo '[FAIL] frontend/catalog содержит внешний origin'; bad=1; else echo '[OK] frontend/catalog: external origins отсутствуют'; fi
  for f in tolstoy-teachings-ch01.mp3 tolstoy-childhood-ch01.mp3 beethoven-moonlight.mp3 chopin-nocturne.mp3 bach-air.mp3; do if valid_audio_file "$WWW_DIR/audio/$f"; then echo "[OK] local: $f"; else echo "[FAIL] local: $f"; bad=1; fi; done
  if [[ "$STREAM_SKIP_NGINX_PROXY" == 1 ]]; then echo '[CI] nginx proxy status skipped'; elif grep -Fq "$MARK_BEGIN" "$NGINX_CONF" 2>/dev/null && grep -Fq 'proxy_ssl_verify on;' "$NGINX_CONF" 2>/dev/null && grep -Fq 'proxy_pass_request_headers off;' "$NGINX_CONF" 2>/dev/null && grep -Fq "proxy_set_header Host ${RADIOBOOK_HOST}:${RADIOBOOK_PORT};" "$NGINX_CONF" 2>/dev/null; then echo '[OK] Radio Book same-origin nginx proxy configured, TLS verify=ON, Host=:8069, client headers stripped'; else echo '[FAIL] Radio Book nginx proxy missing/incomplete'; bad=1; fi
  return "$bad"
}

main(){
  require_root || return 1
  case "${1:-status}" in
    install) install_safe_audio ;;
    status) validate_limits && status_safe_audio ;;
    *) fail 'Допустимо: install | status'; return 1 ;;
  esac
}

main "$@"
