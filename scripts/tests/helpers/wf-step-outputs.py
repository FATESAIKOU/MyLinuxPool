#!/usr/bin/env python3
"""wf-step-outputs.py — 每個被引用的 steps.<id>.outputs.<name> 都要真的被寫出來。

2026-09-16：把產生 read_pubkey_cmd 的程式碼插進 workflow 時貼錯了步驟——
兩個步驟的結尾剛好都是 `echo "cmd=${cmd}" >> "$GITHUB_OUTPUT"`，字串替換
抓到第一個。YAML 合法、所有步驟都成功，只有那個 output 是空字串，於是
pool-ssh 收到一條空指令才炸。GitHub 對「引用不存在的 output」不報錯，只
回空字串，所以這類錯誤只能在本地擋。

只在看得懂的情況下判斷。很多步驟把函式的 stdout 整個導進 $GITHUB_OUTPUT
（`create_worker_compute_identity ... >> "$GITHUB_OUTPUT"`）或先組成變數再
一次寫出（`echo "$output" >> "$GITHUB_OUTPUT"`）——key 不在步驟本文裡，這
種步驟一律略過而不是猜。誤報會讓人學會忽略這支檢查，比漏報更糟。

用法：wf-step-outputs.py <workflow.yml>...  有問題就印出並以 1 結束。
"""
import re, sys, yaml

REF = re.compile(r'\$\{\{\s*steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)\s*\}\}')
WRITE_LINE = re.compile(r'>>\s*"?\$(?:GITHUB_OUTPUT|\{GITHUB_OUTPUT\})"?')
# echo "name=..."  /  printf 'name=%s\n' ...  —— 字面上就看得到 key
LITERAL_KEY = re.compile(r'''(?:echo|printf)\s+(?:-[a-zA-Z]+\s+)*['"]([A-Za-z0-9_-]+)=''')


def declared_outputs(body):
    """(keys, readable) — 這個步驟寫出哪些 key，以及我們是否讀得懂全部的寫入。"""
    keys, readable = set(), True
    lines = body.split('\n')
    i = 0
    while i < len(lines):
        line = lines[i]
        if not WRITE_LINE.search(line):
            i += 1
            continue
        stripped = line.strip()
        if stripped.startswith('}'):
            # { echo a=1; echo b=2; } >> $GITHUB_OUTPUT —— 往回找到開頭的 {
            j = i
            while j >= 0 and not lines[j].strip().startswith('{'):
                j -= 1
            if j < 0:
                readable = False
            else:
                block = '\n'.join(lines[j:i + 1])
                found = LITERAL_KEY.findall(block)
                if found:
                    keys.update(found)
                else:
                    readable = False
        else:
            found = LITERAL_KEY.findall(line)
            if found:
                keys.update(found)
            else:
                # 函式輸出、變數整包寫出…… key 不在本文裡
                readable = False
        i += 1
    return keys, readable


def analyse(path):
    doc = yaml.safe_load(open(path, encoding='utf-8'))
    problems = []
    for job_name, job in (doc.get('jobs') or {}).items():
        steps = job.get('steps') or []
        by_id = {s['id']: s for s in steps if isinstance(s, dict) and s.get('id')}
        raw = yaml.safe_dump(job, default_flow_style=False, allow_unicode=True)
        for step_id, out_name in sorted(set(REF.findall(raw))):
            step = by_id.get(step_id)
            if step is None:
                problems.append(f"{path} [{job_name}]: 引用了 steps.{step_id}.outputs.{out_name}，"
                                f"但沒有 id 為 {step_id} 的步驟")
                continue
            if step.get('uses'):
                continue                      # action 自己宣告 outputs
            keys, readable = declared_outputs(step.get('run') or '')
            if not readable or out_name in keys:
                continue
            problems.append(
                f"{path} [{job_name}]: 步驟 '{step.get('name', step_id)}' (id: {step_id}) "
                f"寫出了 {sorted(keys) or '（無）'}，沒有 {out_name}，"
                f"但有地方引用 steps.{step_id}.outputs.{out_name}（GitHub 會靜靜地給空字串）")
    return problems


bad = []
for p in sys.argv[1:]:
    bad += analyse(p)
if bad:
    print('\n'.join(bad)); sys.exit(1)
sys.exit(0)
