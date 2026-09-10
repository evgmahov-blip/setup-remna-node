#!/usr/bin/env bash
set -Eeuo pipefail

BASE_REF="9f995774f85ddba77826444992725a6a51e2ac20"
BASE_URL="https://raw.githubusercontent.com/evgmahov-blip/setup-remna-node/${BASE_REF}/setup_node_next.sh"
DST="/root/setup_node_next.patched.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

printf '#################### НАЧАЛО ВЫВОДА: NEXT БЕЗ LEGACY NETWORK TUNING ####################\n'

curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 3 "$BASE_URL" -o "$TMP"
bash -n "$TMP"

python3 - "$TMP" "$DST" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text()
needle = '''    BEGIN { skip_proto=0; proto_done=0; decoy_done=0; pin_url=0; pin_root=0; reg_done=0; pin_telemt=0; telemt_label=0; telemt_menu=0; uninstall_marker=0 }\n'''
insert = needle + '''    /^[[:space:]]*optimize_network[[:space:]]*$/ {\n      print "    log \\\"${INFO} NEXT: legacy SAFE/HIGHLOAD network tuning отключён; sysctl этим шагом не меняется.\\\""\n      next\n    }\n'''
if needle not in src:
    raise SystemExit('ERROR: anchor BEGIN in prepare_legacy_for_next not found')
if 'legacy SAFE/HIGHLOAD network tuning отключён' in src:
    raise SystemExit('ERROR: source already patched unexpectedly')
out = src.replace(needle, insert, 1)
Path(sys.argv[2]).write_text(out)
PY

bash -n "$DST"
chmod 0755 "$DST"
grep -q 'legacy SAFE/HIGHLOAD network tuning отключён' "$DST"

echo '[OK] Legacy optimize_network() отключён на уровне NEXT-адаптера.'
echo '[OK] Старый выбор SAFE/HIGHLOAD по объёму RAM больше не выполняется.'
echo '[OK] Запускаю исправленный NEXT.'

bash "$DST"

printf '#################### КОНЕЦ ВЫВОДА: NEXT БЕЗ LEGACY NETWORK TUNING ####################\n'
