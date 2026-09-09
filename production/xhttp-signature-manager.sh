#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
PROFILE_DIR="$APP_DIR/remnawave-profiles"
PROFILE_FILE="$PROFILE_DIR/xhttp-reality.json"
HOST_FILE="$PROFILE_DIR/host-xhttp.txt"
SIGNATURE_FILE="$APP_DIR/xhttp-signature.json"

fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }
need(){ command -v "$1" >/dev/null 2>&1 || { fail "Не найдено: $1"; return 1; }; }
random_hex(){ openssl rand -hex "$1"; }

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

runtime_test_profile(){
  local p="$1" verbose="${2:-0}" remote="/tmp/.xhttp-signature-test.json" bin rc
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

new_signature(){
  local pick seq session pad_header pad_key pad_min pad_max max_concurrency reuse
  pick=$(( 0x$(random_hex 1) % 4 ))
  case "$pick" in
    0) seq="csrftoken"; session="session_id"; pad_header="X-CSRFToken"; pad_key="_t" ;;
    1) seq="cart_currency"; session="_shopify_session"; pad_header="X-Shopify-Token"; pad_key="_shop" ;;
    2) seq="device_id"; session="user_session"; pad_header="X-Profile-Token"; pad_key="_a" ;;
    3) seq="visitor_id"; session="auth_session"; pad_header="X-Request-Token"; pad_key="_r" ;;
  esac

  pad_min=$((96 + 0x$(random_hex 1) % 256))
  pad_max=$((pad_min + 384 + 0x$(random_hex 2) % 768))
  max_concurrency=$((1 + 0x$(random_hex 1) % 4))
  reuse=$((4 + 0x$(random_hex 1) % 13))

  jq -n \
    --arg seq "$seq" \
    --arg session "$session" \
    --arg pad_header "$pad_header" \
    --arg pad_key "$pad_key" \
    --arg padding "${pad_min}-${pad_max}" \
    --argjson mc "$max_concurrency" \
    --argjson reuse "$reuse" \
    '{
      seqKey: $seq,
      seqPlacement: "cookie",
      sessionIDKey: $session,
      sessionIDPlacement: "cookie",
      sessionIDTable: "Base62",
      sessionIDLength: "16-32",
      xPaddingKey: $pad_key,
      xPaddingHeader: $pad_header,
      xPaddingMethod: "tokenish",
      xPaddingPlacement: "queryInHeader",
      xPaddingObfsMode: true,
      xPaddingBytes: $padding,
      xmux: {
        maxConcurrency: $mc,
        cMaxReuseTimes: $reuse
      }
    }' > "$SIGNATURE_FILE"
  chmod 600 "$SIGNATURE_FILE"
}

normalize_signature(){
  local tmp
  tmp="$(mktemp "$APP_DIR/.xhttp-signature-normalize.XXXXXX")"
  if jq 'del(.sessionKey, .sessionPlacement, .xmux.cMaxLifetimeMs)' "$SIGNATURE_FILE" > "$tmp" \
     && jq -e 'type == "object" and .seqKey and .sessionIDKey and .sessionIDTable and .xPaddingBytes and ((.xmux.maxConnections? // null) == null)' "$tmp" >/dev/null 2>&1; then
    chmod 600 "$tmp"
    mv -f "$tmp" "$SIGNATURE_FILE"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

ensure_signature(){
  if [[ -s "$SIGNATURE_FILE" ]] && normalize_signature; then
    return 0
  fi
  new_signature
}

patch_profile(){
  local tmp rc
  [[ -s "$PROFILE_FILE" ]] || { fail "XHTTP profile не найден: $PROFILE_FILE"; return 1; }
  tmp="$(mktemp "$PROFILE_DIR/.xhttp-signature.XXXXXX.json")"
  if ! jq --slurpfile extra "$SIGNATURE_FILE" '.inbounds[0].streamSettings.xhttpSettings.extra = $extra[0]' "$PROFILE_FILE" > "$tmp"; then
    rm -f "$tmp"
    fail 'Не удалось встроить XHTTP extra в профиль'
    return 1
  fi
  jq empty "$tmp" >/dev/null
  if runtime_test_profile "$tmp"; then
    :
  else
    rc=$?
    echo "[ERROR] Runtime отклонил профиль после XHTTP signature (rc=$rc):"
    runtime_test_profile "$tmp" 1 || true
    rm -f "$tmp"
    fail 'Рабочий XHTTP профиль НЕ изменён'
    return 1
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$PROFILE_FILE"
}

write_host_extra(){
  local out="$PROFILE_DIR/host-xhttp-extra.json" tmp
  tmp="$(mktemp "$PROFILE_DIR/.host-xhttp-extra.XXXXXX")"
  cp "$SIGNATURE_FILE" "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$out"
  if [[ -f "$HOST_FILE" ]] && ! grep -q '^xHTTP extra file:' "$HOST_FILE"; then
    cat >> "$HOST_FILE" <<HOST
xHTTP extra file: $out
ВАЖНО: содержимое xHTTP extra в Host должно совпадать с inbound один-в-один.
HOST
  fi
}

revert_signature(){
  local tmp rc
  [[ -s "$PROFILE_FILE" ]] || { fail "XHTTP profile не найден: $PROFILE_FILE"; return 1; }
  tmp="$(mktemp "$PROFILE_DIR/.xhttp-revert.XXXXXX.json")"
  jq 'del(.inbounds[0].streamSettings.xhttpSettings.extra)' "$PROFILE_FILE" > "$tmp"
  jq empty "$tmp" >/dev/null
  if runtime_test_profile "$tmp"; then
    :
  else
    rc=$?
    echo "[ERROR] Runtime отклонил профиль после снятия XHTTP signature (rc=$rc):"
    runtime_test_profile "$tmp" 1 || true
    rm -f "$tmp"
    fail 'Рабочий XHTTP профиль НЕ изменён'
    return 1
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$PROFILE_FILE"
  rm -f "$PROFILE_DIR/host-xhttp-extra.json"
  if [[ -f "$HOST_FILE" ]]; then
    sed -i '/^xHTTP extra file:/d; /^ВАЖНО: содержимое xHTTP extra в Host должно совпадать с inbound один-в-один\.$/d' "$HOST_FILE"
  fi
  echo '[OK] XHTTP signature снята с профиля. Сохранённый per-node secret оставлен для возможного повторного применения.'
}

show_signature(){
  if [[ -s "$SIGNATURE_FILE" ]]; then
    cat "$SIGNATURE_FILE"
  else
    echo 'Сохранённой XHTTP signature пока нет.'
  fi
}

main(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { fail "Запусти от root"; return 1; }
  need jq
  need openssl
  mkdir -p "$APP_DIR" "$PROFILE_DIR"

  case "${1:-apply}" in
    apply)
      ensure_signature
      patch_profile
      write_host_extra
      echo '#################### НАЧАЛО ВЫВОДА: XHTTP SIGNATURE ####################'
      echo "Signature: $SIGNATURE_FILE"
      echo "Host extra: $PROFILE_DIR/host-xhttp-extra.json"
      echo 'Сигнатура стабильная между запусками и является общим секретом клиента/сервера.'
      echo '#################### КОНЕЦ ВЫВОДА: XHTTP SIGNATURE ####################'
      ;;
    revert)
      revert_signature
      ;;
    show)
      show_signature
      ;;
    *) fail 'Использование: xhttp-signature-manager.sh [apply|revert|show]'; return 1 ;;
  esac
}

main "$@"
