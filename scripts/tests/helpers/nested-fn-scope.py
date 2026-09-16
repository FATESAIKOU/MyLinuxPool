#!/usr/bin/env python3
"""nested-fn-scope.py — 找出「定義在某個函式體內，卻被別處呼叫」的函式。

巢狀定義本身不是錯：pool-sync 刻意把所有東西包進 main()（install.sh 會
覆寫執行中的檔案，bash 依 byte offset 續讀），那些內部函式也只在 main()
內被呼叫，載入順序永遠成立。

真正的 bug 是定義的位置與呼叫的位置對不上——`mlp` 曾把
client_identity_path 貼進 open_gateway_master 的函式體內，而 do_connect
從另一條路徑呼叫它：語法合法、`mlp ls` 正常，只有 `mlp ssh <name>` 撞上
command not found，而且那裡寫了 `|| true`，錯誤被吞掉、身分靜靜變成空的。

用法：nested-fn-scope.py <file>...   有問題就逐行印出並以 1 結束。
"""
import re, sys

TOP = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{')
NESTED = re.compile(r'^\s+([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{')

def analyse(path):
    lines = open(path, encoding='utf-8').read().split('\n')
    # 以「col 0 的 name() {」到「col 0 的 }」界定 top-level 函式區塊
    blocks, cur = {}, None
    for i, ln in enumerate(lines):
        m = TOP.match(ln)
        if m and cur is None:
            cur = (m.group(1), i)
        elif cur is not None and ln == '}':
            blocks[cur[0]] = (cur[1], i)
            cur = None
    nested = {}
    for name, (s, e) in blocks.items():
        for i in range(s + 1, e):
            m = NESTED.match(lines[i])
            if m:
                nested.setdefault(m.group(1), []).append((name, i + 1))
    problems = []
    for fn, defs in nested.items():
        owners = {o for o, _ in defs}
        call = re.compile(r'(^|[\s;|&(`$])' + re.escape(fn) + r'([\s;|&)"\'`]|$)')
        for name, (s, e) in blocks.items():
            if name in owners:
                continue
            for i in range(s + 1, e):
                ln = lines[i]
                if NESTED.match(ln) or ln.lstrip().startswith('#'):
                    continue
                if call.search(ln):
                    problems.append(
                        f"{path}:{i+1}: {name}() 呼叫了 {fn}()，"
                        f"但 {fn}() 定義在 {'/'.join(sorted(owners))}() 內"
                        f"（第 {', '.join(str(l) for _, l in defs)} 行）")
        # top-level（不在任何函式內）呼叫也算
        covered = set()
        for s, e in blocks.values():
            covered.update(range(s, e + 1))
        for i, ln in enumerate(lines):
            if i in covered or NESTED.match(ln) or ln.lstrip().startswith('#'):
                continue
            if call.search(ln) and not TOP.match(ln):
                problems.append(f"{path}:{i+1}: 檔案層級呼叫了 {fn}()，"
                                f"但它定義在 {'/'.join(sorted(owners))}() 內")
    return problems

bad = []
for p in sys.argv[1:]:
    try:
        bad += analyse(p)
    except FileNotFoundError:
        continue
if bad:
    print('\n'.join(bad))
    sys.exit(1)
sys.exit(0)
