#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

BRANCH = "fix/xhttp-raw-hysteria-from-july7"


def run(*args: str, check: bool = True, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    print("+", " ".join(args), flush=True)
    return subprocess.run(args, text=True, check=check, env=env)


def sha256(path: str | Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly 1 marker, got {count}")
    return text.replace(old, new, 1)


def patch_rkn_manager() -> None:
    p = Path("production/rkn-watcher-manager.sh")
    s = p.read_text(encoding="utf-8")
    pattern = r"activate_safe\(\)\{\n.*?\n\}\n\nrefresh_lists\(\)\{"
    replacement = r'''normalize_yes_no_answer(){
  local value="${1-}" ascii=''
  value="${value//$'\r'/}"
  value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  ascii="$(printf '%s' "$value" | tr 'A-Z' 'a-z')"
  case "$ascii" in
    ''|y|yes) printf 'yes'; return 0 ;;
    n|no) printf 'no'; return 0 ;;
  esac
  case "$value" in
    д|Д|да|Да|ДА) printf 'yes'; return 0 ;;
    н|Н|нет|Нет|НЕТ) printf 'no'; return 0 ;;
  esac
  printf 'invalid'
  return 1
}

rkn_input_selftest(){
  local failed=0 got input expected encoded
  while IFS='|' read -r encoded expected; do
    case "$encoded" in
      '<EMPTY>') input='' ;;
      '<CRY>') input=$'y\r' ;;
      *) input="$encoded" ;;
    esac
    got=''
    if got="$(normalize_yes_no_answer "$input")" && [[ "$got" == "$expected" ]]; then
      :
    else
      printf '[SELFTEST FAIL] input=%q expected=%s got=%s\n' "$input" "$expected" "${got:-ERROR}" >&2
      failed=1
    fi
  done <<'EOF_CASES'
<EMPTY>|yes
y|yes
Y|yes
 y |yes
yes|yes
YES|yes
<CRY>|yes
д|yes
ДА|yes
n|no
N|no
 no |no
нет|no
НЕТ|no
EOF_CASES
  if normalize_yes_no_answer 'maybe' >/dev/null 2>&1; then
    echo '[SELFTEST FAIL] invalid answer accepted' >&2
    failed=1
  fi
  (( failed == 0 )) && echo '[OK] RKN confirmation input selftest'
  return "$failed"
}

activate_safe(){
  local answer='no' raw=''
  [[ -x "$GUARD_SCRIPT" ]] || { err 'Scanner guard не установлен'; return 1; }
  record_safe_allow_ips
  write_safe_config
  schedule_rollback

  if ! "$GUARD_SCRIPT" apply || ! verify_guard; then
    echo '[ERROR] Проверка scanner guard не прошла; выполняю немедленный rollback.'
    "$GUARD_SCRIPT" remove || true
    cancel_rollback
    return 1
  fi

  echo
  echo '[SAFE] Защита от известных TSPU/Skipa scanners уже активна.'
  echo '[SAFE] DROP только tcp/80, tcp/443 и udp/443 для IP из TSPUIPS.'
  echo '[SAFE] Если выбрать n/No или потерять сессию, через 120 секунд guard будет снят.'

  if [[ "${RKN_ASSUME_KEEP:-0}" == '1' ]]; then
    answer='yes'
  elif [[ -t 0 ]]; then
    while true; do
      raw=''
      read -r -p 'Оставить защиту постоянно? [Y/n]: ' raw || raw='n'
      if answer="$(normalize_yes_no_answer "$raw")"; then
        break
      fi
      echo '[WARN] Неверный ответ. Введите y/yes или n/no.'
    done
  fi

  case "$answer" in
    yes)
      cancel_rollback
      "$GUARD_SCRIPT" apply
      enable_safe_autostart
      printf 'active\n' > "$ACTIVE_STATE"
      chmod 600 "$ACTIVE_STATE"
      echo '[OK] SAFE SCANNER MODE зафиксирован: boot restore + daily update включены.'
      ;;
    no)
      disable_all_autostart
      rm -f "$ACTIVE_STATE"
      echo '[INFO] Выбрано No. Автооткат оставлен; защита будет снята максимум через 120 секунд.'
      ;;
    *)
      echo '[ERROR] Внутренняя ошибка нормализации ответа; оставляю rollback активным.' >&2
      disable_all_autostart
      rm -f "$ACTIVE_STATE"
      return 1
      ;;
  esac
}

refresh_lists(){'''
    s2, n = re.subn(pattern, replacement, s, count=1, flags=re.S)
    if n != 1:
        raise RuntimeError(f"RKN activate_safe replacement count={n}")
    s = s2
    old = '''main(){
  need_root
  case "${1:-menu}" in
'''
    new = '''main(){
  if [[ "${1:-}" == 'selftest-input' ]]; then
    rkn_input_selftest
    return $?
  fi
  need_root
  case "${1:-menu}" in
'''
    s = replace_once(s, old, new, "RKN main selftest gate")
    p.write_text(s, encoding="utf-8")


def patch_rkn_ci() -> None:
    p = Path(".github/workflows/rkn-safe-ci.yml")
    s = p.read_text(encoding="utf-8")
    old = '''          grep -Fq 'Оставить защиту постоянно? [Y/n]:' "$f"
          grep -Fq 'answer="${answer:-y}"' "$f"
          grep -Fq 'y|yes)' "$f"
          ! grep -Fq "trap 'rm -rf \\\"\\$tmp\\\"' RETURN" "$f"
          grep -Fq 'rm -rf "$tmp"' "$f"
'''
    new = '''          grep -Fq 'Оставить защиту постоянно? [Y/n]:' "$f"
          grep -Fq 'normalize_yes_no_answer' "$f"
          grep -Fq "selftest-input" "$f"
          bash "$f" selftest-input
          ! grep -Fq "trap 'rm -rf \\\"\\$tmp\\\"' RETURN" "$f"
          grep -Fq 'rm -rf "$tmp"' "$f"
'''
    s = replace_once(s, old, new, "rkn-safe-ci confirmation block")
    p.write_text(s, encoding="utf-8")


def derive_patched_rkn_sha() -> str:
    with tempfile.TemporaryDirectory(prefix="remna-finalize-") as td:
        td_path = Path(td)
        rkn = td_path / "rkn.sh"
        guard = td_path / "guard.sh"
        shutil.copy2("production/rkn-watcher-manager.sh", rkn)
        shutil.copy2("production/next-runtime-guards.sh", guard)
        gs = guard.read_text(encoding="utf-8")
        gs, n = re.subn(
            r'^RKN_PATCHED_MANAGER_SHA256="[0-9a-f]{64}"$',
            'RKN_PATCHED_MANAGER_SHA256="' + ("0" * 64) + '"',
            gs,
            count=1,
            flags=re.M,
        )
        if n != 1:
            raise RuntimeError("runtime guard probe SHA marker not found")
        gs = replace_once(gs, 'main "$@"\n', ': # probe: main disabled\n', "runtime guard probe main")
        guard.write_text(gs, encoding="utf-8")
        script = f'source "{guard}"; patch_rkn_manager "{rkn}"'
        cp = subprocess.run(["bash", "-c", script], text=True, capture_output=True)
        print(cp.stdout, end="")
        print(cp.stderr, end="")
        # A SHA mismatch is expected because the probe constant is all zeros.
        rs = rkn.read_text(encoding="utf-8")
        for marker in ("validate_scanner_set", "last-good-tspu.ipset", ".safe-update-running"):
            if marker not in rs:
                raise RuntimeError(f"runtime RKN patch probe missing marker: {marker}")
        return sha256(rkn)


def patch_runtime_guard_and_manifest(patched_rkn_sha: str) -> tuple[str, str]:
    gp = Path("production/next-runtime-guards.sh")
    gs = gp.read_text(encoding="utf-8")
    gs, n = re.subn(
        r'^RKN_PATCHED_MANAGER_SHA256="[0-9a-f]{64}"$',
        f'RKN_PATCHED_MANAGER_SHA256="{patched_rkn_sha}"',
        gs,
        count=1,
        flags=re.M,
    )
    if n != 1:
        raise RuntimeError("runtime guard SHA marker not found")
    gp.write_text(gs, encoding="utf-8")

    rkn_sha = sha256("production/rkn-watcher-manager.sh")
    guard_sha = sha256(gp)
    mp = Path("production/modules.sha256")
    ms = mp.read_text(encoding="utf-8")
    ms, n1 = re.subn(
        r'^[0-9a-f]{64}  production/rkn-watcher-manager\.sh$',
        f'{rkn_sha}  production/rkn-watcher-manager.sh',
        ms,
        count=1,
        flags=re.M,
    )
    ms, n2 = re.subn(
        r'^[0-9a-f]{64}  production/next-runtime-guards\.sh$',
        f'{guard_sha}  production/next-runtime-guards.sh',
        ms,
        count=1,
        flags=re.M,
    )
    if n1 != 1 or n2 != 1:
        raise RuntimeError(f"module manifest replacements rkn={n1} guard={n2}")
    mp.write_text(ms, encoding="utf-8")
    return rkn_sha, guard_sha


def patch_wrapper(module_ref: str, rkn_sha: str, guard_sha: str) -> None:
    p = Path("setup_node_next.sh")
    s = p.read_text(encoding="utf-8")
    s, n = re.subn(
        r'^MODULE_REF="\$\{REMNANODE_REPO_REF:-[0-9a-f]{40}\}"$',
        f'MODULE_REF="${{REMNANODE_REPO_REF:-{module_ref}}}"',
        s,
        count=1,
        flags=re.M,
    )
    if n != 1:
        raise RuntimeError("wrapper MODULE_REF replacement failed")
    s, n = re.subn(
        r'^  \[production/rkn-watcher-manager\.sh\]="[0-9a-f]{64}"$',
        f'  [production/rkn-watcher-manager.sh]="{rkn_sha}"',
        s,
        count=1,
        flags=re.M,
    )
    if n != 1:
        raise RuntimeError("wrapper RKN hash replacement failed")
    s, n = re.subn(
        r'^  \[production/next-runtime-guards\.sh\]="[0-9a-f]{64}"$',
        f'  [production/next-runtime-guards.sh]="{guard_sha}"',
        s,
        count=1,
        flags=re.M,
    )
    if n != 1:
        raise RuntimeError("wrapper runtime guard hash replacement failed")

    marker = '''  ' "$f" > "$tmp"; then
    rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Не удалось безопасно адаптировать July base"; return 1
  fi
'''
    replacement = '''  ' "$f" > "$tmp"; then
    rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Не удалось безопасно адаптировать July base"; return 1
  fi
  sed -i \\
    -e 's/echo " 0) Выход"/echo " 0) ↩️ Назад в REMNANODE NEXT"/' \\
    -e 's/Вы можете запускать это меню командой: ${GREEN}remnanode${NC}/Вы можете запускать это меню командой: ${GREEN}remnanode-next${NC}/' \\
    "$tmp"
'''
    s = replace_once(s, marker, replacement, "legacy UX insertion")

    old = '''     || grep -Eq '^[[:space:]]*11\\) run_telemt_installer ;;' "$tmp" \\
     || grep -q '^    register_globally$' "$tmp"; then
'''
    new = '''     || grep -Eq '^[[:space:]]*11\\) run_telemt_installer ;;' "$tmp" \\
     || grep -q '^    register_globally$' "$tmp" \\
     || grep -Fq 'echo " 0) Выход"' "$tmp" \\
     || grep -Fq 'командой: ${GREEN}remnanode${NC}' "$tmp"; then
'''
    s = replace_once(s, old, new, "legacy UX rejection")

    check = '''  grep -Fq 'NEXT_ACTION_FILE' "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Legacy uninstall marker не применён"; return 1; }
'''
    add = '''  grep -Fq 'NEXT_ACTION_FILE' "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Legacy uninstall marker не применён"; return 1; }
  grep -Fq '0) ↩️ Назад в REMNANODE NEXT' "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Legacy пункт возврата в NEXT не применён"; return 1; }
  grep -Fq 'командой: ${GREEN}remnanode-next${NC}' "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Legacy подсказка команды remnanode-next не применена"; return 1; }
'''
    s = replace_once(s, check, add, "legacy UX verification")
    p.write_text(s, encoding="utf-8")


def verify_wrapper_against_legacy() -> None:
    with tempfile.TemporaryDirectory(prefix="remna-legacy-verify-") as td:
        td_path = Path(td)
        wrapper = td_path / "wrapper.sh"
        legacy = td_path / "legacy.sh"
        shutil.copy2("setup_node_next.sh", wrapper)
        ws = wrapper.read_text(encoding="utf-8")
        ws = replace_once(ws, 'main "$@"\n', ': # verify: main disabled\n', "wrapper verify main")
        wrapper.write_text(ws, encoding="utf-8")
        url = "https://raw.githubusercontent.com/evgmahov-blip/setup-remna-node/34aeaa99aa1a5c21fc4f9d0c976d38607d025353/setup_node.sh"
        run("curl", "-fsSL", "--proto", "=https", "--tlsv1.2", url, "-o", str(legacy))
        script = f'source "{wrapper}"; prepare_legacy_for_next "{legacy}"'
        run("bash", "-c", script)
        ls = legacy.read_text(encoding="utf-8")
        if '0) ↩️ Назад в REMNANODE NEXT' not in ls:
            raise RuntimeError("adapted legacy missing NEXT back label")
        if 'командой: ${GREEN}remnanode-next${NC}' not in ls:
            raise RuntimeError("adapted legacy missing remnanode-next hint")
        if 'echo " 0) Выход"' in ls:
            raise RuntimeError("adapted legacy still contains old exit label")


def main() -> None:
    run("git", "config", "user.name", "github-actions[bot]")
    run("git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")

    patch_rkn_manager()
    patch_rkn_ci()
    run("bash", "-n", "production/rkn-watcher-manager.sh")
    run("bash", "production/rkn-watcher-manager.sh", "selftest-input")

    patched_rkn_sha = derive_patched_rkn_sha()
    print("patched RKN SHA:", patched_rkn_sha)
    rkn_sha, guard_sha = patch_runtime_guard_and_manifest(patched_rkn_sha)
    run("bash", "-n", "production/next-runtime-guards.sh")
    run("sha256sum", "-c", "production/modules.sha256")

    run("git", "add", "production/rkn-watcher-manager.sh", "production/next-runtime-guards.sh", "production/modules.sha256", ".github/workflows/rkn-safe-ci.yml")
    run("git", "commit", "-m", "fix: harden RKN confirmation after live canary")
    run("git", "push", "origin", f"HEAD:{BRANCH}")
    module_ref = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    print("immutable module ref:", module_ref)

    patch_wrapper(module_ref, rkn_sha, guard_sha)
    run("bash", "-n", "setup_node_next.sh")
    verify_wrapper_against_legacy()

    for path in (Path(".github/workflows/finalize-canary-fixes.yml"), Path("tools/finalize_canary_fixes.py")):
        if path.exists():
            path.unlink()
    run("git", "add", "-A")
    run("git", "commit", "-m", "fix: clarify nested NEXT return and repin modules")
    run("git", "push", "origin", f"HEAD:{BRANCH}")
    print("FINAL_HEAD", subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip())


if __name__ == "__main__":
    main()
