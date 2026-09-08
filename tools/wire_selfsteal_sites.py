#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "setup_node_next.sh"
MANIFEST = ROOT / "production/modules.sha256"
MANAGER = ROOT / "production/selfsteal-site-manager.sh"
CI = ROOT / ".github/workflows/transport-profile-ci.yml"
MODULE_REF = "e7895ba764bcfa969abb428ef0fd04a61a3d368f"


def require(cond: bool, message: str) -> None:
    if not cond:
        raise SystemExit(message)


def patch_wrapper(manager_sha: str) -> None:
    s = WRAPPER.read_text()

    s, n = re.subn(
        r'MODULE_REF="\$\{REMNANODE_REPO_REF:-[0-9a-f]{40}\}"',
        f'MODULE_REF="${{REMNANODE_REPO_REF:-{MODULE_REF}}}"',
        s,
        count=1,
    )
    require(n == 1, "MODULE_REF replacement failed")

    module_line = f'  [production/selfsteal-site-manager.sh]="{manager_sha}"'
    if "[production/selfsteal-site-manager.sh]" not in s:
        needle = "  [production/validate-generated-profile.sh]="
        pos = s.find(needle)
        require(pos >= 0, "MODULE_SHA256 insertion point not found")
        s = s[:pos] + module_line + "\n" + s[pos:]
    else:
        s, n = re.subn(
            r'^  \[production/selfsteal-site-manager\.sh\]="[0-9a-f]{64}"$',
            module_line,
            s,
            count=1,
            flags=re.M,
        )
        require(n == 1, "SelfSteal module checksum replacement failed")

    legacy_block = '''run_selfsteal_default(){
  local f="$WORK_DIR/selfsteal-site-manager.sh"
  fetch_module "production/selfsteal-site-manager.sh" "$f" || return 1
  APP_DIR="$APP_DIR" bash "$f" ensure
}

run_selfsteal_site(){
  local f="$WORK_DIR/selfsteal-site-manager.sh"
  fetch_module "production/selfsteal-site-manager.sh" "$f" || return 1
  APP_DIR="$APP_DIR" bash "$f" choose
}

run_legacy(){
  local f="$WORK_DIR/setup_node-legacy.sh" rc
  echo -e "${GREEN}[STABLE 07.07]${NC} Запускаю зафиксированную рабочую базу."
  echo -e "${GRAY}Commit: ${LEGACY_COMMIT}${NC}"
  fetch_url "${LEGACY_RAW}/setup_node.sh" "$f" "setup_node.sh@${LEGACY_COMMIT}" "$LEGACY_SHA256" || return 1
  if bash "$f"; then
    if [[ -d /var/www/html && -f "$APP_DIR/docker-compose.yml" ]]; then
      echo -e "${GREEN}[SELFSTEAL]${NC} Применяю сохранённый сайт; если выбор ещё не делали — STREAM."
      run_selfsteal_default
    fi
  else
    rc=$?
    return "$rc"
  fi
}

run_transport(){'''

    if "run_selfsteal_default(){" not in s:
        s, n = re.subn(
            r'run_legacy\(\)\{\n.*?\n\}\n\nrun_transport\(\)\{',
            legacy_block,
            s,
            count=1,
            flags=re.S,
        )
        require(n == 1, "run_legacy replacement failed")

    if "'SelfSteal site:'" not in s:
        lines = s.splitlines()
        out: list[str] = []
        inserted = False
        for line in lines:
            out.append(line)
            if "'Reality target:'" in line and "printf" in line and not inserted:
                out.append("  printf '  %-22s %s\\n' 'SelfSteal site:' \"$(cat \"$APP_DIR/.selfsteal_site\" 2>/dev/null || echo 'stream (default)')\"")
                inserted = True
        require(inserted, "SelfSteal status insertion failed")
        s = "\n".join(out) + "\n"

    menu_item = '    echo -e "   ${WHITE}7)${NC} 🌐 SelfSteal сайт — STREAM / RADIO ${GRAY}(default: STREAM)${NC}"'
    if menu_item not in s:
        needle = '    echo -e "   ${WHITE}6)${NC} 🎭 Показать текущий SNI / target / состояние пула"\n'
        require(needle in s, "SNI menu line not found")
        s = s.replace(needle, needle + menu_item + "\n", 1)

    s = s.replace(
        '    echo -e "   ${WHITE}7)${NC} 🛡️  RKN Watcher — установка / статус / apply / удаление"',
        '    echo -e "   ${WHITE}8)${NC} 🛡️  RKN Watcher — установка / статус / apply / удаление"',
        1,
    )
    s = s.replace(
        "SelfSteal сайты, SSL, Telemt, Xray version, UFW, IPv6, логи, тесты — пункт 1.",
        "SSL, Telemt, Xray version, UFW, IPv6, логи, тесты — пункт 1.",
        1,
    )
    s = s.replace("read -r -p 'Выбери действие [0-7]: ' choice", "read -r -p 'Выбери действие [0-8]: ' choice", 1)

    old_case = "      6) show_sni ;;\n      7) run_rkn; pause ;;"
    new_case = "      6) show_sni ;;\n      7) run_selfsteal_site; pause ;;\n      8) run_rkn; pause ;;"
    if new_case not in s:
        require(old_case in s, "menu case block not found")
        s = s.replace(old_case, new_case, 1)

    require("run_selfsteal_default(){" in s, "SelfSteal default function missing")
    require("run_selfsteal_site(){" in s, "SelfSteal chooser function missing")
    require("[production/selfsteal-site-manager.sh]" in s, "SelfSteal checksum missing")
    require("Выбери действие [0-8]" in s, "menu range not updated")
    WRAPPER.write_text(s)


def patch_manifest(manager_sha: str) -> None:
    lines = [
        line
        for line in MANIFEST.read_text().splitlines()
        if not line.endswith("  production/selfsteal-site-manager.sh")
    ]
    lines.append(f"{manager_sha}  production/selfsteal-site-manager.sh")
    MANIFEST.write_text("\n".join(lines) + "\n")


def patch_ci() -> None:
    s = CI.read_text()
    if "bash -n production/selfsteal-site-manager.sh" not in s:
        needle = "          bash -n production/validate-generated-profile.sh\n"
        require(needle in s, "CI bash-n insertion point not found")
        s = s.replace(needle, needle + "          bash -n production/selfsteal-site-manager.sh\n", 1)

    if "SelfSteal default STREAM and RADIO" not in s:
        marker = "      - name: Install pinned Xray v26.7.28\n"
        require(marker in s, "CI SelfSteal step insertion point not found")
        step = '''      - name: SelfSteal default STREAM and RADIO
        run: |
          set -euo pipefail
          T="$(mktemp -d)"
          mkdir -p "$T/www"
          printf 'node.example.com\\n' > "$T/.node_domain"
          sudo env APP_DIR="$T" WWW_DIR="$T/www" bash production/selfsteal-site-manager.sh ensure
          test "$(sudo cat "$T/.selfsteal_site")" = stream
          sudo grep -q 'mstream' "$T/www/index.html"
          sudo env APP_DIR="$T" WWW_DIR="$T/www" bash production/selfsteal-site-manager.sh radio
          test "$(sudo cat "$T/.selfsteal_site")" = radio
          ADMIN="$(sudo cat "$T/.selfsteal_radio_admin")"
          sudo test -s "$T/www/$ADMIN"
          ! sudo grep -q 'Управление' "$T/www/index.html"

'''
        s = s.replace(marker, step + marker, 1)

    CI.write_text(s)


def main() -> None:
    manager_sha = hashlib.sha256(MANAGER.read_bytes()).hexdigest()
    print(f"SelfSteal manager SHA256: {manager_sha}")
    patch_wrapper(manager_sha)
    patch_manifest(manager_sha)
    patch_ci()
    print("SelfSteal wiring patched")


if __name__ == "__main__":
    main()
