#!/usr/bin/env python3
"""naked-var-multibyte.py — 抓 `$識別字` 後面緊接非 ASCII 位元組。

2026-09-26 在 bash 3.2.57（macOS 內建）上實測：`$f（` 不是「`$f` 後面接一
個全形括號」，它會被解析成**變數名 `f` 加上那個多位元組字元的第一個位元組**
（`is_namechar` 吃寬字元）。於是：

    $ set -u; f=VAL; echo "$f（"
    bash: f?: unbound variable

變數本身是設好的也一樣——bash 找的是**另一個**名字（`f\xef`），那個才沒設。

規則：`$` + `[A-Za-z_][A-Za-z0-9_]*` + 一個 >= 0x80 的位元組，就報。
實測過不會誤報的形狀（它們的變數名在非 ASCII 位元組前就結束了）：
`${f}（`、`$1（`、`$2（`、`$@（`、`$#（`、`$-（`、`$(cmd)（`、`$((1+1))（`、
`$f （`、`$f-（`、`$f,（`。`$2（` 會 crash，但那是因為 `$2` 真的沒設，
不是因為名稱被汙染——訊息裡 bash 報的名字是乾淨的 `$2`。

**這個缺陷的形狀值得單獨說明，因為它躲得特別好：**

它**只出現在診斷訊息裡**。那些字串（`bad "...$f（..."`）只有在檢查「有東西
要報」時才會被求值。所以：

  * 正常的綠燈永遠碰不到它——寫完、看著它綠、推上 master。
  * 真的抓到問題的那一次，**訊息本身崩潰**，而且在 `set -u` 下把整支腳本
    帶走（`exit` 在崩潰那行，不在它本來要回報的那個問題上）。

**失敗訊息在有失敗要報的那一刻變成當機。** 而且 `bash -n` 抓不到它（語法
正確），所以 repo 裡既有的四處（當時）都活著。`docs/TESTPLAN.md` §1.7 那句
「事前沒徵兆，事後看又很明顯」在這裡成立得特別徹底：連事後的診斷都被吃
掉了，所以連「事後」都沒有。

**為什麼註解與單引號不算命中：** 那兩個位置不進行展開，所以 `$f（` 在裡面
是安全的。這是語言事實，不是例外清單——這支檢查沒有任何檔案名或樣式的
白名單。（歷史上找到的 11 處命中裡有 7 處是註解裡的散文，例如
`$GITHUB_OUTPUT」`；它們不是缺陷。`--comments` 可以把它們印出來看。）

**判準的已知極限**（寫下來是因為那是這條判準的邊界）：
  * `$(...)` 與反引號內部不做遞迴解析，所以 `$(echo # ) $f（` 這種會被
    誤判成註解而漏報。極不常見，但它是這條判準的一個洞。
  * heredoc 本文不做解析。`<<EOF`（會展開）本文裡的 `$f（` 其實是危險的，
    這支檢查不報；`<<'EOF'`（不展開）裡的則是誤報。兩種都沒報。
  * 單引號／雙引號可以跨行，所以引號狀態在行與行之間延續。這個做對了。

用法：naked-var-multibyte.py <file>...   [--comments]
"""
import re
import sys

# `$` + 識別字 + 非 ASCII。變數名只認 ASCII 字母/底線/數字——非 ASCII 的
# 那一個位元組正是被誤吃進變數名的東西，所以它不能是名字的一部分。
VAR = re.compile(rb'\$[A-Za-z_][A-Za-z0-9_]*([\x80-\xff])')

WORD_BREAK = b' \t;&|<>(){}'


def scan(data):
    """逐位元組走過整個檔案，只在「會展開」的位置找 VAR。

    為什麼不能用一行一行的 grep：判斷「會不會展開」需要知道引號狀態，而
    引號可以跨行。`x="a#b"; echo "$f（"` 那一行裡有 `#`，但它在雙引號內，
    不是註解——一行式的「這行有 # 就當註解」會漏報，而漏報是壞的方向。
    """
    hits = []          # (lineno, col, matched_bytes, 說明)
    state = 'none'     # none | single | double
    at_word_start = True
    lineno = 1
    i, n = 0, len(data)
    while i < n:
        b = data[i:i + 1]
        # 換行在最前面處理，三種狀態都要算：單雙引號可以跨行，但行號照樣要
        # 前進。（第一版把這行放在 none 狀態裡，結果 quote 跨行的檔案會整個
        # 少算行數——test-ls-states.sh 的 307 被報成 293。診斷裡的行號錯了，
        # 下一個人就得多花一次。）
        if b == b'\n':
            lineno += 1
            at_word_start = True
            i += 1
            continue
        if state == 'single':
            if b == b"'":
                state = 'none'
            i += 1
            continue
        if state == 'double':
            if b == b'\\' and data[i + 1:i + 2] in (b'$', b'`', b'"', b'\\'):
                i += 2
                continue
            if b == b'"':
                state = 'none'
                i += 1
                continue
            m = VAR.match(data, i)
            if m:
                hits.append((lineno, m.start(), m.group(0), 'double-quoted'))
                i = m.end() - 1     # 讓那個非 ASCII 位元組只報一次
            i += 1
            continue
        # state == 'none'
        if b == b'\\':
            # `\` + 換行是行接續：被吃掉的是一個換行，所以行號照樣要加。
            # 漏掉它的話，檔案裡有行接續的行數越多，行號就偏得越離譜
            # （test-ls-states.sh 少算 14 行，307 被報成 293）。
            if data[i + 1:i + 2] == b'\n':
                lineno += 1
            i += 2
            at_word_start = True
            continue
        if b == b"'":
            state = 'single'
            i += 1
            at_word_start = False
            continue
        if b == b'"':
            state = 'double'
            i += 1
            at_word_start = False
            continue
        if b == b'#' and at_word_start:
            j = data.find(b'\n', i)
            i = n if j < 0 else j          # 整行都是註解
            continue
        m = VAR.match(data, i)
        if m:
            hits.append((lineno, m.start(), m.group(0), 'unquoted'))
            i = m.end() - 1
            at_word_start = False
            continue
        at_word_start = b in WORD_BREAK
        i += 1
    return hits


def comments(data):
    """註解裡的同一種命中——不是缺陷，只是讓人知道它們存在。"""
    out = []
    for k, raw in enumerate(data.split(b'\n'), 1):
        s = raw.lstrip()
        if not s.startswith(b'#'):
            continue
        for m in VAR.finditer(raw):
            out.append((k, m.start(), m.group(0)))
    return out


def main():
    args = sys.argv[1:]
    want_comments = False
    paths = []
    for a in args:
        if a == '--comments':
            want_comments = True
        else:
            paths.append(a)
    # 沒有輸入檔時回報乾淨，就是 preflight 檔頭警告的那個形狀：掃描器什麼
    # 都沒拿到。呼叫端（preflight）應該先擋，但這裡也要自己出聲——同一個
    # 缺陷不該有「靠別人記得擋」的第二種失效方式。
    if not paths:
        print('naked-var-multibyte: 沒有輸入檔——這不是「沒有問題」，'
              '是沒有東西可檢查（列舉壞了？）')
        return 2
    bad = []
    noted = 0
    for p in paths:
        try:
            data = open(p, 'rb').read()
        except OSError as e:
            print('naked-var-multibyte: 讀不到 %s (%s)' % (p, e))
            return 2
        lines = data.split(b'\n')
        for lineno, col, tok, why in scan(data):
            # tok 是 `$` + 名字 + 那個非 ASCII 位元組。拿掉 `$` 與最後那個
            # 位元組就是變數名：單獨一個 >= 0x80 的位元組解碼出來必定是一個
            # U+FFFD，所以 `[:-1]` 剛好去掉它（不會誤吃掉名字的最後一字母）。
            name = tok[1:-1].decode('ascii')
            src = lines[lineno - 1].decode('utf-8', 'replace').strip()[:96]
            bad.append('%s:%d: `$%s` 後面緊接非 ASCII（%s）——bash 3.2 會把變數名'
                       '讀成「%s」加上那個位元組的第一個，然後在 set -u 下 '
                       'crash。改成 `${%s}`：\n      %s'
                       % (p, lineno, name, why, name, name, src))
        if want_comments:
            noted += len(comments(data))
    for b in bad:
        print(b)
    if noted:
        print('（另有 %d 處在註解裡，不進行展開，不是缺陷）' % noted)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
