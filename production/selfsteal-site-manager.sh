#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
WWW_DIR="${WWW_DIR:-/var/www/html}"
STATE_FILE="$APP_DIR/.selfsteal_site"
RADIO_ADMIN_FILE="$APP_DIR/.selfsteal_radio_admin"
STREAM_SALT_FILE="$APP_DIR/.selfsteal_stream_salt"
STREAM_AUDIO_CACHE="${STREAM_AUDIO_CACHE:-$APP_DIR/stream-audio-cache}"
STREAM_AUDIO_FIXTURE_DIR="${STREAM_AUDIO_FIXTURE_DIR:-}"
STREAM_AUDIO_MIN_BYTES="${STREAM_AUDIO_MIN_BYTES:-32768}"
STREAM_AUDIO_MAX_BYTES="${STREAM_AUDIO_MAX_BYTES:-8388608}"

STREAM_REF="ec5ffa5c26e57c6f6b2060bbf6743d3921c05500"
STREAM_URL="https://raw.githubusercontent.com/evgmahov-blip/setup-remna-node/${STREAM_REF}/selfsteal/stream/index.html"
STREAM_BRANDS=(wavecast airtone nordbeat sonora tuneline pulsar lumen radiogram)

declare -A STREAM_AUDIO_SHA256=(
  [tolstoy-teachings-ch01.mp3]="d71d3070a7790898121e7cbe4c0d67af41eb93964ff449dbec5abe570435e994"
  [tolstoy-childhood-ch01.mp3]="ac399678d5b408f08864e9e7f5c40da039a090a66eba73d4852c570dbb44d8fe"
  [anna-karenina-ch01.mp3]="40f93935542d995092bfde517f919ab7efb8b46afa75284184f281ca0e5201e5"
  [beethoven-moonlight.mp3]="01e2b9902a4a0f3f73af4ffd9eac9769391065fd8fafe48fb49f929454e0ce86"
  [chopin-nocturne.mp3]="f65c98447a4212afe77878771e5279f230cfe74173139721dd0fe412982058f2"
  [bach-air.mp3]="e9bbe80f87e98c0b263208cb8e333f644662d2f607a1436798f9981138783c27"
)

TOLSTOY_TEACHINGS_URL="https://www.archive.org/download/teachingsofchrist_1204_librivox/teachingsofchrist_1_tolstoy_64kb.mp3"
TOLSTOY_CHILDHOOD_URL="https://www.archive.org/download/childhood_russian_librivox/Leo-Tolstoy-Detstvo-RUSSIAN-01-Karl-Ivanych_64kb.mp3"
ANNA_KARENINA_URL="https://www.archive.org/download/firstchaptercollection002_1501_librivox/firstchapter002_annakarenina_tolstoy_mt_64kb.mp3"
BEETHOVEN_URL="https://upload.wikimedia.org/wikipedia/commons/transcoded/d/d0/Moonlight_Sonata.ogg/Moonlight_Sonata.ogg.mp3?download="
CHOPIN_URL="https://upload.wikimedia.org/wikipedia/commons/transcoded/0/04/Chopin_Nocturne_No._2_in_E_Flat_Major%2C_Op._9.ogg/Chopin_Nocturne_No._2_in_E_Flat_Major%2C_Op._9.ogg.mp3?download="
BACH_URL="https://upload.wikimedia.org/wikipedia/commons/transcoded/1/1e/Air_%28Bach%29.ogg/Air_%28Bach%29.ogg.mp3?download="

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
  if ! curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$url" -o "$tmp"; then
    rm -f "$tmp"; fail "Не удалось скачать $url"; return 1
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; fail "Пустой файл: $url"; return 1; }
  mv -f "$tmp" "$dst"
}

validate_www_dir(){
  local normalized
  [[ -n "$WWW_DIR" && "$WWW_DIR" == /* ]] || { fail 'WWW_DIR должен быть непустым абсолютным путём'; return 1; }
  normalized="$(readlink -m -- "$WWW_DIR" 2>/dev/null)" || { fail 'Не удалось нормализовать WWW_DIR'; return 1; }
  [[ -n "$normalized" && "$normalized" != / ]] || { fail 'WWW_DIR не может указывать на /'; return 1; }
  WWW_DIR="$normalized"
}

prepare_www(){
  validate_www_dir || return 1
  mkdir -p "$APP_DIR" "$WWW_DIR"
  find "$WWW_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

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
  shift 2
  command -v unzip >/dev/null 2>&1 || return 1
  tmpdir="$(mktemp -d)"
  zip="$tmpdir/templates.zip"
  if fetch_static "$TEMPLATES_ARCHIVE" "$zip" \
     && unzip -q "$zip" -d "$tmpdir/unpack" 2>/dev/null; then
    root="$(find "$tmpdir/unpack" -mindepth 1 -maxdepth 1 -type d -name 'node-templates-*' -print -quit)"
    if [[ -n "$root" && -x "$root/uniquify-theme.sh" ]] \
       && bash "$root/uniquify-theme.sh" -s "$src" -o "$dst" \
            --seed "$(openssl rand -hex 16)" --no-zip --no-install-deps "$@" >/dev/null 2>&1; then
      rc=0
    fi
  fi
  rm -rf -- "$tmpdir"
  return "$rc"
}

stream_salt(){
  local salt tmp
  mkdir -p "$APP_DIR"
  if [[ -r "$STREAM_SALT_FILE" ]]; then
    salt="$(tr -d '\r\n' < "$STREAM_SALT_FILE")"
    [[ "$salt" =~ ^[0-9a-f]{8}$ ]] || { fail "Некорректная STREAM salt: $STREAM_SALT_FILE"; return 1; }
    printf '%s' "$salt"
    return 0
  fi
  tmp="$(mktemp "$APP_DIR/.selfsteal_stream_salt.XXXXXX")" || { fail 'Не удалось создать временный STREAM salt'; return 1; }
  if ! salt="$(openssl rand -hex 4)"; then
    rm -f -- "$tmp"; fail 'Не удалось сгенерировать STREAM salt'; return 1
  fi
  [[ "$salt" =~ ^[0-9a-f]{8}$ ]] || { rm -f -- "$tmp"; fail 'Сгенерирован некорректный STREAM salt'; return 1; }
  printf '%s\n' "$salt" > "$tmp"
  chmod 0600 "$tmp"
  if ! mv -f -- "$tmp" "$STREAM_SALT_FILE"; then
    rm -f -- "$tmp"; fail 'Не удалось сохранить STREAM salt'; return 1
  fi
  printf '%s' "$salt"
}

stream_audio_size(){ stat -c %s -- "$1" 2>/dev/null || printf '0'; }

valid_stream_audio(){
  local file="$1" name="${2:-}" size want got
  [[ -s "$file" ]] || return 1
  size="$(stream_audio_size "$file")"
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  (( size >= STREAM_AUDIO_MIN_BYTES && size <= STREAM_AUDIO_MAX_BYTES )) || return 1
  if head -c 1024 "$file" 2>/dev/null | LC_ALL=C grep -aEqi '<!doctype|<html|<body'; then return 1; fi
  if [[ -z "$STREAM_AUDIO_FIXTURE_DIR" ]]; then
    [[ -n "$name" ]] || return 1
    want="${STREAM_AUDIO_SHA256[$name]:-}"
    [[ -n "$want" ]] || return 1
    got="$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)" || return 1
    [[ "$got" == "$want" ]] || return 1
  fi
  return 0
}

fetch_stream_audio(){
  local name="$1" url="$2" dst="$3" fixture part
  mkdir -p "$STREAM_AUDIO_CACHE"
  if valid_stream_audio "$dst" "$name"; then
    log "[OK] STREAM audio cache: $name ($(stream_audio_size "$dst") bytes)"
    return 0
  fi
  if [[ -n "$STREAM_AUDIO_FIXTURE_DIR" ]]; then
    fixture="${STREAM_AUDIO_FIXTURE_DIR%/}/$name"
    [[ -r "$fixture" ]] || { fail "STREAM fixture отсутствует: $fixture"; return 1; }
    cp -f -- "$fixture" "$dst"
    valid_stream_audio "$dst" "$name" || { rm -f "$dst"; fail "STREAM fixture не прошёл validation: $name"; return 1; }
    return 0
  fi
  part="${dst}.part"
  rm -f -- "$part"
  log "[INFO] Загружаю локальный STREAM audio: $name"
  if ! curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --connect-timeout 15 --max-time 600 --retry 2 --retry-delay 2 \
      --max-filesize "$STREAM_AUDIO_MAX_BYTES" \
      "$url" -o "$part"; then
    rm -f -- "$part"; fail "Не удалось скачать STREAM audio: $name"; return 1
  fi
  if ! valid_stream_audio "$part" "$name"; then
    rm -f -- "$part"; fail "Скачанный STREAM audio не прошёл validation: $name"; return 1
  fi
  chmod 0644 "$part"
  mv -f -- "$part" "$dst"
  log "[OK] STREAM audio: $name ($(stream_audio_size "$dst") bytes)"
}

prepare_stream_audio(){
  [[ "$STREAM_AUDIO_MIN_BYTES" =~ ^[0-9]+$ && "$STREAM_AUDIO_MAX_BYTES" =~ ^[0-9]+$ ]] \
    || { fail 'Некорректные STREAM audio size limits'; return 1; }
  (( STREAM_AUDIO_MIN_BYTES >= 1 && STREAM_AUDIO_MAX_BYTES > STREAM_AUDIO_MIN_BYTES )) \
    || { fail 'Некорректные STREAM audio size limits'; return 1; }
  mkdir -p "$STREAM_AUDIO_CACHE"
  fetch_stream_audio 'tolstoy-teachings-ch01.mp3' "$TOLSTOY_TEACHINGS_URL" "$STREAM_AUDIO_CACHE/tolstoy-teachings-ch01.mp3" || return 1
  fetch_stream_audio 'tolstoy-childhood-ch01.mp3' "$TOLSTOY_CHILDHOOD_URL" "$STREAM_AUDIO_CACHE/tolstoy-childhood-ch01.mp3" || return 1
  fetch_stream_audio 'anna-karenina-ch01.mp3' "$ANNA_KARENINA_URL" "$STREAM_AUDIO_CACHE/anna-karenina-ch01.mp3" || return 1
  fetch_stream_audio 'beethoven-moonlight.mp3' "$BEETHOVEN_URL" "$STREAM_AUDIO_CACHE/beethoven-moonlight.mp3" || return 1
  fetch_stream_audio 'chopin-nocturne.mp3' "$CHOPIN_URL" "$STREAM_AUDIO_CACHE/chopin-nocturne.mp3" || return 1
  fetch_stream_audio 'bach-air.mp3' "$BACH_URL" "$STREAM_AUDIO_CACHE/bach-air.mp3" || return 1
}

write_stream_catalog(){
  local out="$1" salt="$2"
  [[ "$salt" =~ ^[0-9a-f]{8}$ ]] || { fail 'Некорректная STREAM salt для каталога'; return 1; }
  cat > "$out" <<EOF_JSON
{
  "generated": $(date +%s),
  "mounts": {
    "/audio/tolstoy-teachings-ch01-${salt}.mp3": {
      "status": "Active",
      "listener_count": 0,
      "format": {"bitrate": 64, "content_type": "audio/mpeg"},
      "metadata": {"now_playing": "Лев Толстой — Учение Христа, изложенное для детей"}
    },
    "/audio/tolstoy-childhood-ch01-${salt}.mp3": {
      "status": "Active",
      "listener_count": 0,
      "format": {"bitrate": 64, "content_type": "audio/mpeg"},
      "metadata": {"now_playing": "Лев Толстой — Детство · Карл Иваныч"}
    },
    "/audio/anna-karenina-ch01-${salt}.mp3": {
      "status": "Active",
      "listener_count": 0,
      "format": {"bitrate": 64, "content_type": "audio/mpeg"},
      "metadata": {"now_playing": "Лев Толстой — Анна Каренина · глава 1"}
    },
    "/audio/beethoven-moonlight-${salt}.mp3": {
      "status": "Active",
      "listener_count": 0,
      "format": {"bitrate": 128, "content_type": "audio/mpeg"},
      "metadata": {"now_playing": "Beethoven — Moonlight Sonata"}
    },
    "/audio/chopin-nocturne-${salt}.mp3": {
      "status": "Active",
      "listener_count": 0,
      "format": {"bitrate": 128, "content_type": "audio/mpeg"},
      "metadata": {"now_playing": "Chopin — Nocturne No. 2 in E-flat Major"}
    },
    "/audio/bach-air-${salt}.mp3": {
      "status": "Active",
      "listener_count": 0,
      "format": {"bitrate": 128, "content_type": "audio/mpeg"},
      "metadata": {"now_playing": "J. S. Bach — Air"}
    }
  }
}
EOF_JSON
  if command -v jq >/dev/null 2>&1; then
    jq -e '(.mounts|length)==6 and ([.mounts|keys[]|startswith("/audio/")]|all) and ([.mounts[].listener_count]|all(.==0))' "$out" >/dev/null \
      || { fail 'Сгенерирован некорректный локальный streams.json'; return 1; }
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$out" >/dev/null 2>&1 || { fail 'Сгенерирован некорректный streams.json'; return 1; }
  else
    fail 'Для проверки streams.json нужен jq или python3'; return 1
  fi
}

stream_has_legacy_external_dependency(){
  local path="$1"
  grep -RqiE 'stream\.deepbeat\.ru|/api/deepbeat-(health|history)|bookradio\.hostingradio\.ru' "$path"
}

validate_stream_runtime(){
  local root="$1" salt="$2" flat catalog history
  [[ "$salt" =~ ^[0-9a-f]{8}$ ]] || return 1
  catalog="$root/data/streams-${salt}.json"
  history="$root/data/history-${salt}.json"
  [[ -s "$root/index.html" && -s "$catalog" && -s "$history" ]] || return 1
  grep -Fq "const HEALTH_API = \"/data/streams-${salt}.json\";" "$root/index.html" || return 1
  grep -Fq "const HISTORY_API = \"/data/history-${salt}.json\";" "$root/index.html" || return 1
  grep -Fq 'const STREAM_ORIGIN = window.location.origin;' "$root/index.html" || return 1
  grep -Fq 'state.sort === "listeners"' "$root/index.html" || return 1
  flat="$(tr '\n' ' ' < "$root/index.html")"
  printf '%s' "$flat" | grep -Eq '\$\{[[:space:]]*active[[:space:]]*\?' || return 1
  if printf '%s' "$flat" | grep -Eq '\$\{[[:space:]]*u[0-9a-f]{6,16}[[:space:]]*\?'; then return 1; fi
  if command -v jq >/dev/null 2>&1; then
    jq -e '(.mounts|length)==6 and ([.mounts|keys[]|startswith("/audio/")]|all)' "$catalog" >/dev/null || return 1
  fi
  stream_has_legacy_external_dependency "$root" && return 1
  return 0
}

deploy_stream(){
  local tmpdir brand src uq f salt catalog_name history_name public_name
  tmpdir="$(mktemp -d)"
  src="$tmpdir/site"
  uq="$tmpdir/uq"
  mkdir -p "$src/data" "$uq"

  salt="$(stream_salt)" || { rm -rf -- "$tmpdir"; return 1; }
  catalog_name="streams-${salt}.json"
  history_name="history-${salt}.json"

  fetch_static "$STREAM_URL" "$src/index.html" || { rm -rf -- "$tmpdir"; return 1; }
  grep -Eqi '<!doctype|<html' "$src/index.html" || { rm -rf -- "$tmpdir"; fail 'STREAM index.html не похож на HTML'; return 1; }

  brand="${STREAM_BRANDS[$((RANDOM % ${#STREAM_BRANDS[@]}))]}-$(openssl rand -hex 2)"
  sed -i "s#const HEALTH_API = \"/api/deepbeat-health\";#const HEALTH_API = \"/data/${catalog_name}\";#" "$src/index.html"
  sed -i "s#const HISTORY_API = \"/api/deepbeat-history\";#const HISTORY_API = \"/data/${history_name}\";#" "$src/index.html"
  sed -i 's#const STREAM_ORIGIN = "https://stream.deepbeat.ru:8443";#const STREAM_ORIGIN = window.location.origin;#' "$src/index.html"
  sed -i "s/mstream/${brand}/g" "$src/index.html"

  if stream_has_legacy_external_dependency "$src"; then
    rm -rf -- "$tmpdir"; fail 'В STREAM осталась legacy внешняя зависимость'; return 1
  fi
  grep -Fq "const HEALTH_API = \"/data/${catalog_name}\";" "$src/index.html" || { rm -rf -- "$tmpdir"; fail 'Не удалось перевести STREAM на локальный каталог'; return 1; }
  grep -Fq "const HISTORY_API = \"/data/${history_name}\";" "$src/index.html" || { rm -rf -- "$tmpdir"; fail 'Не удалось перевести STREAM history на локальный каталог'; return 1; }
  grep -Fq 'const STREAM_ORIGIN = window.location.origin;' "$src/index.html" || { rm -rf -- "$tmpdir"; fail 'Не удалось включить same-origin STREAM'; return 1; }

  prepare_stream_audio || { rm -rf -- "$tmpdir"; return 1; }
  write_stream_catalog "$src/data/$catalog_name" "$salt" || { rm -rf -- "$tmpdir"; return 1; }
  printf '{"history":[]}\n' > "$src/data/$history_name"

  if uniquify_dir "$src" "$uq" --exclude 'active,listeners'; then
    log '[OK] STREAM уникализирован через pinned uniquify-theme (runtime tokens protected)'
  else
    rm -rf -- "$tmpdir"
    fail 'uniquify-theme не применился; немутированный STREAM публиковать запрещено'
    return 1
  fi

  find "$uq" -mindepth 1 \( -name '.uniquify-manifest.txt' -o -name 'README.md' -o -name 'README.MD' \) -delete
  [[ -s "$uq/index.html" ]] || { rm -rf -- "$tmpdir"; fail 'STREAM: пустой index.html после сборки'; return 1; }

  mkdir -p "$uq/audio"
  for f in \
    tolstoy-teachings-ch01.mp3 \
    tolstoy-childhood-ch01.mp3 \
    anna-karenina-ch01.mp3 \
    beethoven-moonlight.mp3 \
    chopin-nocturne.mp3 \
    bach-air.mp3; do
    valid_stream_audio "$STREAM_AUDIO_CACHE/$f" "$f" || { rm -rf -- "$tmpdir"; fail "STREAM cache повреждён: $f"; return 1; }
    public_name="${f%.mp3}-${salt}.mp3"
    install -m 0644 "$STREAM_AUDIO_CACHE/$f" "$uq/audio/$public_name"
  done

  validate_stream_runtime "$uq" "$salt" || { rm -rf -- "$tmpdir"; fail 'STREAM runtime validation после uniquify не пройдена'; return 1; }

  prepare_www || { rm -rf -- "$tmpdir"; return 1; }
  cp -a "$uq"/. "$WWW_DIR"/
  find "$WWW_DIR" -type d -exec chmod 0755 {} +
  find "$WWW_DIR" -type f -exec chmod 0644 {} +
  rm -rf -- "$tmpdir"
  finish_site stream
  log "[OK] SelfSteal сайт: STREAM (pinned $STREAM_REF, 6 LOCAL same-origin каналов, salt $salt)"
  log '[OK] STREAM audio: 3 русских LibriVox + Beethoven + Chopin + Bach; runtime внешних origin нет'
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
  prepare_www || { rm -rf -- "$tmpdir"; return 1; }
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
  prepare_www || { rm -rf -- "$tmpdir"; return 1; }
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
  echo '  1) STREAM — локальные аудиокниги/музыка, без runtime внешних origin'
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
