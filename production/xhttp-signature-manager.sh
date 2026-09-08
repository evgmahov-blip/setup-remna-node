#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
PROFILE_DIR="$APP_DIR/remnawave-profiles"
PROFILE_FILE="$PROFILE_DIR/xhttp-reality.json"
HOST_FILE="$PROFILE_DIR/host-xhttp.txt"
SIGNATURE_FILE="$APP_DIR/xhttp-signature.json"

fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }

need(){ command -v "$1" >/dev/null 2>&1 || fail "Не найдено: $1"; }

random_hex(){ openssl rand -hex "$1"; }

new_signature(){
  local pick seq session pad_header pad_key pad_min pad_max max_concurrency reuse lifetime
  pick=$(( 0x$(random_hex 1) % 4 ))
  case "$pick" in
    0)
      seq="csrftoken"; session="session_id"; pad_header="X-CSRFToken"; pad_key="_t" ;;
    1)
      seq="cart_currency"; session="_shopify_session"; pad_header="X-Shopify-Token"; pad_key="_shop" ;;
    2)
      seq="device_id"; session="user_session"; pad_header="X-Profile-Token"; pad_key="_a" ;;
    3)
      seq="visitor_id"; session="auth_session"; pad_header="X-Request-Token"; pad_key="_r" ;;
  esac

  pad_min=$((96 + 0x$(random_hex 1) % 256))
  pad_max=$((pad_min + 384 + 0x$(random_hex 1) % 768))
  max_concurrency=$((1 + 0x$(random_hex 1) % 4))
  reuse=$((4 + 0x$(random_hex 1) % 13))
  lifetime=$((180000 + 0x$(random_hex 2) % 420001))

  jq -n \
    --arg seq "$seq" \
    --arg session "$session" \
    --arg pad_header "$pad_header" \
    --arg pad_key "$pad_key" \
    --arg padding "${pad_min}-${pad_max}" \
    --argjson mc "$max_concurrency" \
    --argjson reuse "$reuse" \
    --argjson life "$lifetime" \
    '{
      seqKey: $seq,
      seqPlacement: "cookie",
      sessionKey: $session,
      sessionPlacement: "cookie",
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
        cMaxReuseTimes: $reuse,
        cMaxLifetimeMs: $life
      }
    }' > "$SIGNATURE_FILE"
  chmod 600 "$SIGNATURE_FILE"
}

ensure_signature(){
  if [[ -s "$SIGNATURE_FILE" ]] && jq -e 'type == "object" and .seqKey and .sessionIDKey and .sessionIDTable and .xPaddingBytes and ((.xmux.maxConnections? // null) == null)' "$SIGNATURE_FILE" >/dev/null 2>&1; then
    return 0
  fi
  new_signature
}

patch_profile(){
  local tmp
  [[ -s "$PROFILE_FILE" ]] || fail "XHTTP profile не найден: $PROFILE_FILE"
  tmp="$(mktemp "$PROFILE_DIR/.xhttp-signature.XXXXXX")"
  jq --slurpfile extra "$SIGNATURE_FILE" \
    '.inbounds[0].streamSettings.xhttpSettings.extra = $extra[0]' \
    "$PROFILE_FILE" > "$tmp"
  jq empty "$tmp"
  install -m 600 "$tmp" "$PROFILE_FILE"
  rm -f "$tmp"
}

write_host_extra(){
  local out="$PROFILE_DIR/host-xhttp-extra.json"
  install -m 600 "$SIGNATURE_FILE" "$out"
  if [[ -f "$HOST_FILE" ]]; then
    if ! grep -q '^xHTTP extra file:' "$HOST_FILE"; then
      cat >> "$HOST_FILE" <<EOF
flow: пусто
xHTTP extra file: $out
ВАЖНО: содержимое xHTTP extra в Host должно совпадать с inbound.
EOF
    fi
  fi
}

main(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти от root"
  need jq
  need openssl
  mkdir -p "$APP_DIR" "$PROFILE_DIR"
  ensure_signature
  patch_profile
  write_host_extra

  echo '#################### НАЧАЛО ВЫВОДА: XHTTP SIGNATURE ####################'
  echo "Signature: $SIGNATURE_FILE"
  echo "Host extra: $PROFILE_DIR/host-xhttp-extra.json"
  echo 'Сигнатура сохраняется и повторно не рандомизируется.'
  echo
  cat "$SIGNATURE_FILE"
  echo '#################### КОНЕЦ ВЫВОДА: XHTTP SIGNATURE ####################'
}

main "$@"
