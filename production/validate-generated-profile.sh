#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/remnanode}"
PROFILE_DIR="$APP_DIR/remnawave-profiles"

fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }

resolve_profile(){
  local arg="${1:-}" transport
  if [[ -n "$arg" ]]; then
    [[ -s "$arg" ]] || fail "Файл не найден: $arg"
    printf '%s' "$arg"
    return 0
  fi
  transport="$(cat "$APP_DIR/.transport" 2>/dev/null || true)"
  case "$transport" in
    xhttp) printf '%s' "$PROFILE_DIR/xhttp-reality.json" ;;
    raw) printf '%s' "$PROFILE_DIR/raw-reality.json" ;;
    hysteria) printf '%s' "$PROFILE_DIR/hysteria2-tls.json" ;;
    *) fail 'Не удалось определить профиль. Передай путь первым аргументом.' ;;
  esac
}

validate_in_container(){
  local profile="$1" remote="/tmp/remnawave-profile-validate.json" bin=""
  docker cp "$profile" "remnanode:$remote" >/dev/null
  if docker exec remnanode test -x /usr/local/bin/rw-core; then
    bin=/usr/local/bin/rw-core
  elif docker exec remnanode test -x /usr/local/bin/xray; then
    bin=/usr/local/bin/xray
  else
    docker exec remnanode rm -f "$remote" >/dev/null 2>&1 || true
    fail 'В контейнере remnanode не найден rw-core/xray'
  fi

  echo "Runtime binary: $bin"
  docker exec remnanode "$bin" version 2>/dev/null | head -3 || true
  echo

  if docker exec remnanode "$bin" run -test -c "$remote"; then
    docker exec remnanode rm -f "$remote" >/dev/null 2>&1 || true
    return 0
  fi

  echo '[INFO] Команда run -test не прошла; проверяю legacy CLI форму.'
  if docker exec remnanode "$bin" -test -c "$remote"; then
    docker exec remnanode rm -f "$remote" >/dev/null 2>&1 || true
    return 0
  fi

  docker exec remnanode rm -f "$remote" >/dev/null 2>&1 || true
  return 1
}

validate_local(){
  local profile="$1" bin=""
  if command -v xray >/dev/null 2>&1; then
    bin="$(command -v xray)"
  elif command -v rw-core >/dev/null 2>&1; then
    bin="$(command -v rw-core)"
  elif [[ -x "$APP_DIR/bin/xray" ]]; then
    bin="$APP_DIR/bin/xray"
  else
    fail 'Не найден локальный Xray/rw-core и контейнер remnanode не запущен'
  fi
  echo "Runtime binary: $bin"
  "$bin" version 2>/dev/null | head -3 || true
  "$bin" run -test -c "$profile"
}

main(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Запусти от root'
  command -v jq >/dev/null 2>&1 || fail 'Не найден jq'
  local profile
  profile="$(resolve_profile "${1:-}")"
  [[ -s "$profile" ]] || fail "Профиль не найден: $profile"

  echo '#################### НАЧАЛО ВЫВОДА: REMNAWAVE PROFILE VALIDATION ####################'
  echo "Profile: $profile"
  jq empty "$profile"
  echo '[OK] JSON syntax'
  echo

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    if validate_in_container "$profile"; then
      echo '[OK] Runtime rw-core/Xray принял профиль'
      echo '#################### КОНЕЦ ВЫВОДА: REMNAWAVE PROFILE VALIDATION ####################'
      return 0
    fi
  else
    if validate_local "$profile"; then
      echo '[OK] Local Xray принял профиль'
      echo '#################### КОНЕЦ ВЫВОДА: REMNAWAVE PROFILE VALIDATION ####################'
      return 0
    fi
  fi

  echo '[ERROR] Runtime validator отклонил профиль'
  echo '#################### КОНЕЦ ВЫВОДА: REMNAWAVE PROFILE VALIDATION ####################'
  return 1
}

main "$@"
