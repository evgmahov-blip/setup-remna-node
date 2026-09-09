#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
WWW_DIR="${WWW_DIR:-/var/www/html}"
STATE_FILE="$APP_DIR/.selfsteal_site"
RADIO_ADMIN_FILE="$APP_DIR/.selfsteal_radio_admin"

STREAM_REF="ec5ffa5c26e57c6f6b2060bbf6743d3921c05500"
STREAM_URL="https://raw.githubusercontent.com/evgmahov-blip/setup-remna-node/${STREAM_REF}/selfsteal/stream/index.html"
STREAM_AUDIO_MODE="${STREAM_AUDIO_MODE:-local}"
STREAM_PUBLIC_ORIGIN="${STREAM_PUBLIC_ORIGIN:-}"
STREAM_BRANDS=(wavecast airtone nordbeat sonora tuneline pulsar lumen radiogram)
STREAM_MOUNTS=(ambient-night deep-space lofi-cafe jazz-club retro-wave city-pulse morning-drive night-shift chillhop synth-lab acoustic-room dub-techno soul-kitchen indie-mix classic-fm bass-lab)
STREAM_ARTISTS=("Alva Noto" "Bonobo" "Tycho" "Kiasmos" "Nils Frahm" "Emancipator" "Jon Hopkins" "Rival Consoles" "Olafur Arnalds" "Floating Points")
STREAM_TITLES=("Xerrox" "Kerala" "Awake" "Blurred" "Says" "Minor Cause" "Emerald Rush" "Recovery" "Saman" "Silhouettes")
RADIO_REF="276908d5fed3faaadfb3a331ab7acad18824a9b9"
RADIO_BASE="https://raw.githubusercontent.com/Balbuto/radio-stub-site/${RADIO_REF}"
TEMPLATES_REF="845187fbee8fff72f66d1570af436438e859e40d"
TEMPLATES_ARCHIVE="https://github.com/Mrvibecodic/node-templates/archive/${TEMPLATES_REF}.zip"
TEMPLATES=(endless-verify esports-stream-template levelup-hub playza-game-catalog rybaliti-2.0 screenwire-digest vibrai-photo-editor worldzoo-stream-template)
TEMPLATES_RU=(
  "Страница верификации (endless-verify)"
  "Киберспортивный портал (esports-stream-template)"
  "Игровой хаб для геймеров (levelup-hub)"
  "Каталог онлайн-игр (playza-game-catalog)"
  "Блог/форум о рыбалке (rybaliti-2.0)"
  "Новостной IT-дайджест (screenwire-digest)"
  "Онлайн-фоторедактор (vibrai-photo-editor)"
  "Стримы из зоопарков (worldzoo-stream-template)"
)

log(){ printf '%s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { fail 'Запусти от root'; return 1; }; }

fetch_static(){
  local url="$1" dst="$2" tmp
  tmp="${dst}.part"
  rm -f "$tmp"
  if ! curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$url" -o "$tmp"; then
    rm -f "$tmp"; fail "Не удалось скачать $url"; return 1
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; fail "Пустой файл: $url"; return 1; }
  mv -f "$tmp" "$dst"
}

prepare_www(){ mkdir -p "$APP_DIR" "$WWW_DIR"; find "$WWW_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; }
restart_nginx(){
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnawave-nginx; then
    log '[OK] Статические файлы обновлены без рестарта remnawave-nginx'
  fi
}
set_state(){ printf '%s\n' "$1" > "$STATE_FILE"; chmod 600 "$STATE_FILE"; }

template_allowed(){
  local wanted="$1" item
  for item in "${TEMPLATES[@]}"; do
    [[ "$item" == "$wanted" ]] && return 0
  done
  return 1
}

finish_site(){
  local selected="$1"
  set_state "$selected"
  [[ "$selected" == radio ]] || rm -f "$RADIO_ADMIN_FILE"
  restart_nginx
}

uniquify_dir(){
  local src="$1" dst="$2" tmpdir zip root rc=1
  command -v unzip >/dev/null 2>&1 || return 1
  tmpdir="$(mktemp -d)"
  zip="$tmpdir/templates.zip"
  if fetch_static "$TEMPLATES_ARCHIVE" "$zip" \
     && unzip -q "$zip" -d "$tmpdir/unpack" 2>/dev/null; then
    root="$(find "$tmpdir/unpack" -mindepth 1 -maxdepth 1 -type d -name 'node-templates-*' -print -quit)"
    if [[ -n "$root" && -x "$root/uniquify-theme.sh" ]] \
       && bash "$root/uniquify-theme.sh" -s "$src" -o "$dst" \
            --seed "$(openssl rand -hex 16)" --no-zip --no-install-deps >/dev/null 2>&1; then
      rc=0
    fi
  fi
  rm -rf -- "$tmpdir"
  return "$rc"
}

write_stream_catalog(){
  local out="$1" n name br lc ar ti first=1
  local -a picked=()
  n=$((4 + RANDOM % 5))
  mapfile -t picked < <(shuf -n "$n" -e "${STREAM_MOUNTS[@]}")
  {
    printf '{\n  "generated": %s,\n  "mounts": {\n' "$(date +%s)"
    for name in "${picked[@]}"; do
      br="$(shuf -n1 -e 96 128 160 192 320)"
      lc=$((3 + RANDOM % 180))
      ar="${STREAM_ARTISTS[$((RANDOM % ${#STREAM_ARTISTS[@]}))]}"
      ti="${STREAM_TITLES[$((RANDOM % ${#STREAM_TITLES[@]}))]}"
      if (( first )); then first=0; else printf ',\n'; fi
      printf '    "/%s": {\n' "$name"
      printf '      "status": "Active",\n'
      printf '      "listener_count": %s,\n' "$lc"
      printf '      "format": {"bitrate": %s, "content_type": "audio/mpeg"},\n' "$br"
      printf '      "metadata": {"now_playing": "%s - %s"}\n' "$ar" "$ti"
      printf '    }'
    done
    printf '\n  }\n}\n'
  } > "$out"
  if command -v jq >/dev/null 2>&1; then
    jq empty "$out" >/dev/null 2>&1 || { fail 'Сгенерирован некорректный streams.json'; return 1; }
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$out" >/dev/null 2>&1 || { fail 'Сгенерирован некорректный streams.json'; return 1; }
  else
    fail 'Для проверки streams.json нужен jq или python3'; return 1
  fi
}

stream_origin(){
  local d origin
  case "$STREAM_AUDIO_MODE" in
    public)
      origin="${STREAM_PUBLIC_ORIGIN%/}"
      [[ "$origin" =~ ^https://[A-Za-z0-9._:-]+$ ]] || { fail 'STREAM_AUDIO_MODE=public требует корректный STREAM_PUBLIC_ORIGIN=https://host[:port]'; return 1; }
      printf '%s' "$origin"
      ;;
    local)
      d="$(cat "$APP_DIR/.node_domain" 2>/dev/null || hostname -f 2>/dev/null || hostname)"
      [[ "$d" =~ ^[A-Za-z0-9.-]+$ ]] || { fail 'Не удалось определить безопасный домен для STREAM'; return 1; }
      printf 'https://%s' "$d"
      ;;
    *) fail 'STREAM_AUDIO_MODE допустим только local или public'; return 1 ;;
  esac
}

deploy_stream(){
  local tmpdir brand origin src uq
  tmpdir="$(mktemp -d)"
  src="$tmpdir/site"
  uq="$tmpdir/uq"
  mkdir -p "$src/data" "$uq"
  fetch_static "$STREAM_URL" "$src/index.html" || { rm -rf -- "$tmpdir"; return 1; }
  grep -Eqi '<!doctype|<html' "$src/index.html" || { rm -rf -- "$tmpdir"; fail 'STREAM index.html не похож на HTML'; return 1; }
  origin="$(stream_origin)" || { rm -rf -- "$tmpdir"; return 1; }
  brand="${STREAM_BRANDS[$((RANDOM % ${#STREAM_BRANDS[@]}))]}-$(openssl rand -hex 2)"
  sed -i 's#const HEALTH_API = "/api/deepbeat-health";#const HEALTH_API = "/data/streams.json";#' "$src/index.html"
  sed -i 's#const HISTORY_API = "/api/deepbeat-history";#const HISTORY_API = "/data/history.json";#' "$src/index.html"
  sed -i "s#const STREAM_ORIGIN = \"https://stream.deepbeat.ru:8443\";#const STREAM_ORIGIN = \"${origin}\";#" "$src/index.html"
  sed -i "s/mstream/${brand}/g" "$src/index.html"
  if grep -Eqi '(2rdp\.ru|deepbeat)' "$src/index.html"; then
    rm -rf -- "$tmpdir"; fail 'В STREAM осталась внешняя зависимость'; return 1
  fi
  grep -Fq 'const HEALTH_API = "/data/streams.json";' "$src/index.html" || { rm -rf -- "$tmpdir"; fail 'Не удалось перевести STREAM на локальный каталог'; return 1; }
  grep -Fq 'const HISTORY_API = "/data/history.json";' "$src/index.html" || { rm -rf -- "$tmpdir"; fail 'Не удалось перевести STREAM history на локальный каталог'; return 1; }
  write_stream_catalog "$src/data/streams.json" || { rm -rf -- "$tmpdir"; return 1; }
  printf '{"history":[]}\n' > "$src/data/history.json"
  if uniquify_dir "$src" "$uq"; then
    log '[OK] STREAM уникализирован через pinned uniquify-theme'
  else
    rm -rf -- "$tmpdir"
    fail 'uniquify-theme не применился; немутированный STREAM публиковать запрещено'
    return 1
  fi
  find "$uq" -mindepth 1 \( -name '.uniquify-manifest.txt' -o -name 'README.md' -o -name 'README.MD' \) -delete
  [[ -s "$uq/index.html" ]] || { rm -rf -- "$tmpdir"; fail 'STREAM: пустой index.html после сборки'; return 1; }
  if grep -RqiE 'deepbeat|2rdp\.ru' "$uq"; then
    rm -rf -- "$tmpdir"; fail 'STREAM после уникализации содержит внешнюю зависимость'; return 1
  fi
  prepare_www
  cp -a "$uq"/. "$WWW_DIR"/
  find "$WWW_DIR" -type d -exec chmod 0755 {} +
  find "$WWW_DIR" -type f -exec chmod 0644 {} +
  rm -rf -- "$tmpdir"
  finish_site stream
  log "[OK] SelfSteal сайт: STREAM (pinned $STREAM_REF, self-contained, audio=$STREAM_AUDIO_MODE)"
}

deploy_radio(){
  local tmpdir admin_name domain
  tmpdir="$(mktemp -d)"
  fetch_static "$RADIO_BASE/index.html" "$tmpdir/index.html" || { rm -rf -- "$tmpdir"; return 1; }
  fetch_static "$RADIO_BASE/admin.html" "$tmpdir/admin.html" || { rm -rf -- "$tmpdir"; return 1; }
  grep -Eqi '<!doctype|<html' "$tmpdir/index.html" || { rm -rf -- "$tmpdir"; fail 'RADIO index.html не похож на HTML'; return 1; }
  grep -Eqi '<!doctype|<html' "$tmpdir/admin.html" || { rm -rf -- "$tmpdir"; fail 'RADIO admin.html не похож на HTML'; return 1; }
  if [[ -r "$RADIO_ADMIN_FILE" ]]; then admin_name="$(tr -d '\r\n' < "$RADIO_ADMIN_FILE")"; else admin_name="manage-$(openssl rand -hex 12).html"; fi
  [[ "$admin_name" =~ ^manage-[0-9a-f]{24}\.html$ ]] || admin_name="manage-$(openssl rand -hex 12).html"
  sed '/<div class="toggle-bar">/,/<\/div>/d' "$tmpdir/index.html" > "$tmpdir/index.public.html"
  prepare_www
  install -m 0644 "$tmpdir/index.public.html" "$WWW_DIR/index.html"
  install -m 0644 "$tmpdir/admin.html" "$WWW_DIR/$admin_name"
  printf '%s\n' "$admin_name" > "$RADIO_ADMIN_FILE"; chmod 600 "$RADIO_ADMIN_FILE"
  set_state radio
  rm -rf -- "$tmpdir"
  restart_nginx
  domain="$(cat "$APP_DIR/.node_domain" 2>/dev/null || hostname -f 2>/dev/null || hostname)"
  log "[OK] SelfSteal сайт: RADIO (pinned $RADIO_REF)"
  log "[INFO] Скрытая админка: https://${domain}/${admin_name}"
}

deploy_template(){
  local template="$1" tmpdir zip root out
  template_allowed "$template" || { fail "Неизвестный шаблон: $template"; return 1; }
  command -v unzip >/dev/null 2>&1 || { fail 'Для старых шаблонов нужен пакет unzip'; return 1; }
  tmpdir="$(mktemp -d)"; zip="$tmpdir/templates.zip"; out="$tmpdir/out"
  fetch_static "$TEMPLATES_ARCHIVE" "$zip" || { rm -rf -- "$tmpdir"; return 1; }
  unzip -q "$zip" -d "$tmpdir/unpack" || { rm -rf -- "$tmpdir"; fail 'Не удалось распаковать node-templates'; return 1; }
  root="$(find "$tmpdir/unpack" -mindepth 1 -maxdepth 1 -type d -name 'node-templates-*' -print -quit)"
  [[ -n "$root" && -d "$root/$template" ]] || { rm -rf -- "$tmpdir"; fail "Шаблон $template отсутствует в pinned archive"; return 1; }
  mkdir -p "$out"
  if [[ -x "$root/uniquify-theme.sh" ]] \
     && bash "$root/uniquify-theme.sh" -s "$root/$template" -o "$out" --seed "$(openssl rand -hex 16)" --no-zip --no-install-deps >/dev/null 2>&1; then
    log "[OK] uniquify-theme применён: $template"
  else
    rm -rf -- "$tmpdir"
    fail 'uniquify-theme не применился; немутированный шаблон публиковать запрещено'
    return 1
  fi
  [[ -s "$out/index.html" ]] || { rm -rf -- "$tmpdir"; fail "У $template нет index.html"; return 1; }
  find "$out" -mindepth 1 \( -name '.uniquify-manifest.txt' -o -name 'README.md' -o -name 'README.MD' \) -delete
  prepare_www
  cp -a "$out"/. "$WWW_DIR"/
  find "$WWW_DIR" -type d -exec chmod 0755 {} +
  find "$WWW_DIR" -type f -exec chmod 0644 {} +
  finish_site "template:$template"
  rm -rf -- "$tmpdir"
  log "[OK] SelfSteal шаблон: $template (pinned $TEMPLATES_REF)"
}

deploy_random_template(){ local idx=$((RANDOM % ${#TEMPLATES[@]})); deploy_template "${TEMPLATES[$idx]}"; }

ensure_site(){
  local selected='random' template
  [[ -r "$STATE_FILE" ]] && selected="$(tr -d '\r\n' < "$STATE_FILE")"
  case "$selected" in
    stream) deploy_stream ;;
    radio) deploy_radio ;;
    random) deploy_random_template ;;
    template:*) template="${selected#template:}"; deploy_template "$template" ;;
    *) log "[WARN] Неизвестное сохранённое значение '$selected'; ставлю RANDOM"; deploy_random_template ;;
  esac
}

choose_site(){
  local current choice idx
  current="$(cat "$STATE_FILE" 2>/dev/null || echo 'не выбран (default=random)')"
  echo
  echo 'SELFSTEAL SITE:'
  echo "  Текущий: $current"
  echo '  1) STREAM — самодостаточный стрим-сайт'
  echo '  2) RADIO — радио со скрытой админкой'
  for idx in "${!TEMPLATES[@]}"; do printf ' %2d) %s\n' "$((idx+3))" "${TEMPLATES_RU[$idx]}"; done
  echo ' 11) СЛУЧАЙНЫЙ из старых профессиональных шаблонов'
  echo '  0) Назад'
  read -r -p 'Выбор [1]: ' choice
  case "${choice:-1}" in
    1) deploy_stream ;;
    2) deploy_radio ;;
    3|4|5|6|7|8|9|10) idx=$((choice-3)); deploy_template "${TEMPLATES[$idx]}" ;;
    11) deploy_random_template ;;
    0) return 0 ;;
    *) fail 'Неверный выбор'; return 1 ;;
  esac
}

show_status(){
  local selected admin domain
  selected="$(cat "$STATE_FILE" 2>/dev/null || echo 'не выбран (default=random)')"
  echo "SelfSteal site: $selected"
  if [[ "$selected" == radio && -r "$RADIO_ADMIN_FILE" ]]; then
    admin="$(tr -d '\r\n' < "$RADIO_ADMIN_FILE")"; domain="$(cat "$APP_DIR/.node_domain" 2>/dev/null || hostname -f 2>/dev/null || hostname)"
    echo "Radio admin: https://${domain}/${admin}"
  fi
}

main(){
  require_root || return 1
  case "${1:-ensure}" in
    ensure) ensure_site ;;
    choose) choose_site ;;
    stream) deploy_stream ;;
    radio) deploy_radio ;;
    random) deploy_random_template ;;
    template) [[ -n "${2:-}" ]] || { fail 'Укажи имя шаблона'; return 1; }; deploy_template "$2" ;;
    status) show_status ;;
    *) fail 'Допустимо: ensure | choose | stream | radio | random | template NAME | status'; return 1 ;;
  esac
}

main "$@"
