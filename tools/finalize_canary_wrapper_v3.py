#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess
import tempfile
import shutil

BRANCH='fix/xhttp-raw-hysteria-from-july7'
MODULE_REF='5e54fd49e7b8500fe337f5df442bfa568075a147'

def run(*args):
    print('+', ' '.join(args), flush=True)
    subprocess.run(args, check=True, text=True)

def replace_once(s, old, new, label):
    n=s.count(old)
    if n != 1:
        raise RuntimeError(f'{label}: expected 1 marker, got {n}')
    return s.replace(old,new,1)

manifest={}
for line in Path('production/modules.sha256').read_text(encoding='utf-8').splitlines():
    parts=line.split()
    if len(parts)==2:
        manifest[parts[1]]=parts[0]
rkn_sha=manifest['production/rkn-watcher-manager.sh']
guard_sha=manifest['production/next-runtime-guards.sh']

p=Path('setup_node_next.sh')
s=p.read_text(encoding='utf-8')
s,n=re.subn(r'^MODULE_REF="\$\{REMNANODE_REPO_REF:-[0-9a-f]{40}\}"$', f'MODULE_REF="${{REMNANODE_REPO_REF:-{MODULE_REF}}}"', s, count=1, flags=re.M)
if n != 1: raise RuntimeError('MODULE_REF replacement failed')
s,n=re.subn(r'^  \[production/rkn-watcher-manager\.sh\]="[0-9a-f]{64}"$', f'  [production/rkn-watcher-manager.sh]="{rkn_sha}"', s, count=1, flags=re.M)
if n != 1: raise RuntimeError('RKN hash replacement failed')
s,n=re.subn(r'^  \[production/next-runtime-guards\.sh\]="[0-9a-f]{64}"$', f'  [production/next-runtime-guards.sh]="{guard_sha}"', s, count=1, flags=re.M)
if n != 1: raise RuntimeError('runtime guard hash replacement failed')

marker='''  ' "$f" > "$tmp"; then
    rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Не удалось безопасно адаптировать July base"; return 1
  fi
'''
addition='''  ' "$f" > "$tmp"; then
    rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Не удалось безопасно адаптировать July base"; return 1
  fi
  # NEXT UX: this is a nested July menu, so 0 returns to NEXT rather than leaving the SSH shell.
  sed -i \\
    -e 's/ 0) Выход/ 0) ↩️ Назад в REMNANODE NEXT/' \\
    -e 's/командой: ${CYAN}remnanode${NC}/командой: ${CYAN}remnanode-next${NC}/' \\
    "$tmp"
'''
s=replace_once(s,marker,addition,'legacy UX insertion')

verify_marker='''  grep -Fq 'NEXT_ACTION_FILE' "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Legacy uninstall marker не применён"; return 1; }
'''
verify_add='''  grep -Fq 'NEXT_ACTION_FILE' "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Legacy uninstall marker не применён"; return 1; }
  if grep -Fq ' 0) Выход' "$tmp"; then rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Legacy меню всё ещё показывает Выход вместо возврата в NEXT"; return 1; fi
  grep -Fq '0) ↩️ Назад в REMNANODE NEXT' "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Legacy пункт возврата в NEXT не применён"; return 1; }
  if grep -Fq 'командой: ${CYAN}remnanode${NC}' "$tmp"; then rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Legacy подсказка всё ещё рекламирует bypass-команду remnanode"; return 1; fi
  grep -Fq 'командой: ${CYAN}remnanode-next${NC}' "$tmp" || { rm -f "$tmp"; echo -e "${RED}[ОШИБКА]${NC} Подсказка remnanode-next не применена"; return 1; }
'''
s=replace_once(s,verify_marker,verify_add,'legacy UX verification')
p.write_text(s,encoding='utf-8')
run('bash','-n','setup_node_next.sh')

# Behavioral adapter verification against the exact immutable July base.
with tempfile.TemporaryDirectory(prefix='remna-wrapper-v3-') as td:
    td=Path(td)
    wrapper=td/'wrapper.sh'; legacy=td/'legacy.sh'
    shutil.copy2('setup_node_next.sh',wrapper)
    ws=wrapper.read_text(encoding='utf-8')
    ws=replace_once(ws,'main "$@"\n',': # verification: main disabled\n','wrapper main')
    wrapper.write_text(ws,encoding='utf-8')
    run('curl','-fsSL','--proto','=https','--tlsv1.2','https://raw.githubusercontent.com/evgmahov-blip/setup-remna-node/34aeaa99aa1a5c21fc4f9d0c976d38607d025353/setup_node.sh','-o',str(legacy))
    run('bash','-c',f'source "{wrapper}"; prepare_legacy_for_next "{legacy}"')
    out=legacy.read_text(encoding='utf-8')
    assert '0) ↩️ Назад в REMNANODE NEXT' in out
    assert ' 0) Выход' not in out
    assert 'командой: ${CYAN}remnanode-next${NC}' in out
    assert 'командой: ${CYAN}remnanode${NC}' not in out
    run('bash','-n',str(legacy))

run('git','config','user.name','github-actions[bot]')
run('git','config','user.email','41898282+github-actions[bot]@users.noreply.github.com')
run('git','add','setup_node_next.sh')
run('git','commit','-m','fix: clarify nested NEXT return and repin modules')
run('git','push','origin',f'HEAD:{BRANCH}')
print('FINAL_HEAD',subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip())
