#!/usr/bin/env python3
"""ssh-port-audit.py — 對 Gateway 發 ssh/scp 時，必須明確指定埠。

2026-09-20 把 Gateway 從 22 搬到 2100，結果一個一個踩到八處沒帶埠的呼叫：
push-state、deploy bundle、provision、read host key、restore port claims、
wait for providers、live providers、worker verify。每一處都是在正式流程上
才發現的，而且每次都長一樣——「以前反正都是 22」。

規則：一個 ssh/scp 指令，如果它的目標主機是變數（也就是對池裡的機器連
線），就必須在同一個指令（含續行）裡出現 -p / -P / ProxyJump 的埠。

明確豁免要寫進 ALLOW，並附理由——豁免的是「這台機器此刻一定在 22」的情
境，例如剛開機、還沒被 provisioning 動過的新 Linode。

用法：ssh-port-audit.py <file>...
"""
import re, sys

# 每項：(檔案結尾, 指令必須包含的片段, 理由)
ALLOW = [
    ("rotate-gateway.sh", "rotate_wait_for_ssh",
     "新開的 Linode 還沒被 provisioning 動過，此刻一定在 22"),
    ("rotate-gateway.sh", "cloud-init",
     "同上，cloud-init 等待發生在 provisioning 之前"),
]

# ssh/scp 可能出現在行內任何位置：`if x="$(ssh ...`、`| ssh ...`、
# `out=$(timeout 5 ssh ...`。只在行首比對會靜靜漏掉它們，而一個有盲點卻
# 回報「乾淨」的檢查器比沒有檢查器更糟。
CMD = re.compile(r'(?:^|[\s|(`$])(ssh|scp)\s')
HOSTVAR = re.compile(r'[@:]\$\{?[A-Za-z_]')
PORT = re.compile(r'(^|\s)-[pP]\s|ProxyJump|-J\s+\S+:\d')
# 走既有 ControlMaster socket 的呼叫不會重新撥號，埠由當初開 master 的那次
# 決定，這裡再指定一次沒有意義。
# -S 單獨出現＝走既有 master（不撥號）。但 -M -S 是「建立」master，那一次
# 正是真正的撥號，必須帶埠。
REUSES = re.compile(r'(^|\s)-S\s')
CREATES_MASTER = re.compile(r'(^|\s)-M(\s|$)')


# `local -a cmd=(` / `declare -a x=(` / `opts=(` 都要認得——只認最後一種的
# 話，宣告成 local 的陣列會整段被跳過。
ARRAY_OPEN = re.compile(
    r'^\s*(?:(?:local|declare|typeset|readonly)\s+(?:-[A-Za-z]+\s+)*)?'
    r'[A-Za-z_][A-Za-z0-9_]*(?:\+)?=\(\s*$')


def gather(path):
    """把一個 ssh/scp 指令的所有行接成一段，回傳 (起始行號, 整段)。

    三種寫法都要接得起來，否則主機名在後面幾行的呼叫會被判成「沒有連池裡
    的機器」而靜靜跳過——那正是 pool-tunnel 那一處漏掉的原因：
      1. 單行
      2. 行尾反斜線續行
      3. 陣列字面值：cmd=(\n  ssh ...\n  "${USER}@${IP}"\n)
    """
    out, lines = [], open(path, encoding='utf-8').read().split('\n')
    i = 0
    while i < len(lines):
        # 陣列字面值：整塊當成一個指令
        if ARRAY_OPEN.match(lines[i]):
            start, buf, depth = i + 1, lines[i], 1
            while depth > 0 and i + 1 < len(lines):
                i += 1
                buf += '\n' + lines[i]
                depth += lines[i].count('(') - lines[i].count(')')
            if CMD.search(buf):
                out.append((start, buf))
            i += 1
            continue
        if CMD.search(lines[i]):
            start, buf = i + 1, lines[i]
            while buf.rstrip().endswith('\\') and i + 1 < len(lines):
                i += 1
                buf += '\n' + lines[i]
            out.append((start, buf))
        i += 1
    return out


bad = []
for path in sys.argv[1:]:
    try:
        cmds = gather(path)
    except FileNotFoundError:
        continue
    for lineno, cmd in cmds:
        if not HOSTVAR.search(cmd):
            continue                      # 不是連池裡的機器
        if PORT.search(cmd) or (REUSES.search(cmd) and not CREATES_MASTER.search(cmd)):
            continue                      # 有帶埠，或重用既有連線
        # 選項常常放在陣列裡（ssh "${SSH_OPTS[@]}" ...）。追進那個陣列的
        # 定義，否則看不穿的呼叫會被當成沒帶埠——或更糟，被當成沒問題。
        arrays = re.findall(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\[@\]\}', cmd)
        if arrays:
            body = open(path, encoding='utf-8').read()
            resolved = False
            for a in arrays:
                for m in re.finditer(r'\b' + a + r'(?:\+)?=\(([^)]*)\)', body, re.S):
                    if PORT.search(' ' + m.group(1)):
                        resolved = True
            if resolved:
                continue
        # 上下文：往前找最近的函式名，用來比對豁免
        ctx = cmd
        allowed = any(path.endswith(f) and frag in ctx for f, frag, _ in ALLOW)
        if allowed:
            continue
        # 函式層級的豁免：整個函式名出現在指令附近才算，太寬鬆的就不給
        src = open(path, encoding='utf-8').read().split('\n')
        fn = ""
        for k in range(lineno - 1, -1, -1):
            m = re.match(r'^([a-z_]+)\(\) \{', src[k])
            if m:
                fn = m.group(1); break
        if any(path.endswith(f) and frag == fn for f, frag, _ in ALLOW):
            continue
        bad.append(f"{path}:{lineno}: {fn or '<top level>'}() 對池裡的機器發 "
                   f"{cmd.strip().split()[0]} 但沒有指定埠\n      {cmd.strip().splitlines()[0][:96]}")

if bad:
    print('\n'.join(bad))
    sys.exit(1)
sys.exit(0)
