#!/usr/bin/env bash
set -Eeuo pipefail

TASK_NAME="REMNA FULL CLEAN + NEXT V2"
BASE_REF="8b7183c0a726b22db18f0842d1ccddfbc7bd4421"
BASE="https://raw.githubusercontent.com/evgmahov-blip/setup-remna-node/${BASE_REF}/production"
CLEAN_URL="$BASE/full-clean-reinstall.sh"
NEXT_URL="$BASE/setup-node-next-no-legacy-tuning.sh"
MODE="${1:-menu}"
TMP_CLEAN="$(mktemp)"
TMP_NEXT="$(mktemp)"
trap 'rm -f "$TMP_CLEAN" "$TMP_NEXT"' EXIT

printf '#################### НАЧАЛО ВЫВОДА: %s ####################\n' "$TASK_NAME"

fetch_checked(){
  local url="$1" dst="$2"
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 3 "$url" -o "$dst"
  bash -n "$dst"
  chmod 0700 "$dst"
}

run_clean(){
  fetch_checked "$CLEAN_URL" "$TMP_CLEAN"
  bash "$TMP_CLEAN" clean
}

run_next(){
  fetch_checked "$NEXT_URL" "$TMP_NEXT"
  bash "$TMP_NEXT"
}

case "$MODE" in
  clean)
    run_clean
    ;;
  reinstall|full-reinstall)
    run_clean
    run_next
    ;;
  install|install-next)
    run_next
    ;;
  menu|'')
    printf '%s\n' '[1] Только FULL CLEAN'
    printf '%s\n' '[2] FULL CLEAN -> NEXT (без legacy SAFE/HIGHLOAD tuning)'
    printf '%s\n' '[3] Только NEXT (для уже очищенной ноды)'
    printf '%s\n' '[0] Отмена'
    printf 'Выбор: '
    read -r choice </dev/tty || true
    case "${choice:-0}" in
      1) run_clean ;;
      2) run_clean; run_next ;;
      3) run_next ;;
      0) : ;;
      *) echo '[ERROR] Неверный пункт.' >&2; exit 2 ;;
    esac
    ;;
  *)
    echo '[ERROR] Использование: full-clean-reinstall-v2.sh [clean|reinstall|install|menu]' >&2
    exit 2
    ;;
esac

printf '#################### КОНЕЦ ВЫВОДА: %s ####################\n' "$TASK_NAME"
