#!/usr/bin/env python3
"""callsite-audit.py — 檔頭列出的「呼叫端清單」必須與掃描出來的實際呼叫端一致。

2026-09-26（qa 找到）：`scripts/lib/refresh-wait.sh` 的檔頭說
「Consumers source this file and call dispatch_refresh_and_wait:」然後列兩個
（scripts/create-worker.sh、ops-scripts/register-client），而實際上
`ops-scripts/register-provider.sh:664` 也呼叫它——**第三個**。而既有的測試是
照著檔頭寫的，所以那些測試永遠不會發現第三個呼叫端。

值得記下來的形狀：**文件錯了，測試從文件抄，於是測試的覆蓋範圍符合文件而不是
符合現實**；而文件與測試互相印證，看起來一致。抓那個缺口的唯一辦法是讓「實際
呼叫端」變成掃出來的機械事實。

判準（機械事實，不需要理解語意）：
  1. **實際呼叫端＝掃描。** 對每個被宣告的函式，找 repo 內所有**程式檔**裡
     以命令位置呼叫它的地方。覆蓋範圍見下面 SCOPE。
  2. **宣告端＝解析。** 只認一種結構化格式（見 DECL_FORMAT）。認不出來就
     老實說「這個檔案的宣告無法解析」，不當成通過。
  3. 兩邊不一致 → 紅，且指名**是哪一邊多／少了什麼**。

用法：
  callsite-audit.py <repo-root> [--verbose]
  → exit 0 全一致；exit 1 有不一致；exit 2 harness 問題

SCOPE —— 「實際呼叫端」的涵蓋範圍（這一節是判準的一部分，不是註解）：
  * 掃的檔案：git 追蹤的 **.sh / 無副檔名的 ops 腳本 / *.yml / action.yml**
    （程式檔）。.md 排除——文件是散文，不呼叫任何東西。
  * 命令位置的呼叫：允許前置的環境賦值（`GH_REPO="$REPO" dispatch_… 300`）
    與行內接續。**間接呼叫算**（呼叫被包在另一個函式裡，例如
    create-worker.sh 的 create_worker_dispatch_refresh_and_wait 只是薄包裝）。
  * 排除：定義那一行、註解（整行 # 開頭，或引號外的行尾 # 之後）、以及檔案
    自己宣告清單的那幾行（否則宣告會算成一個呼叫端）。
  * 名字邊界用「前後不可為 [A-Za-z0-9_]」，所以
    `create_worker_dispatch_refresh_and_wait` 不會被算成
    `dispatch_refresh_and_wait` 的呼叫端。
  * 局限（誠實記在這裡）：這是**文字**掃描，不是 shell 解析器。
    - 用 `eval`／變數拼出來的名字（`fn="$x"; $fn`）掃不到。
    - `command "$fn"`、陣列展開等 Indirect 形式掃不到。
    - 被 `#` 開頭但其實在 here-doc 裡的字串會被當註解（方向是漏報，不是誤報）。
    這三條都是朝「少數到」的方向，與本判準要抓的「文件多算／少算」同一個方向。

DECL_FORMAT —— 被承認的宣告格式（唯一的一種，因為 repo 裡只有一種）：
    # <任何話> Consumers ... call <FUNC>:          ← 宣告的引出行
    #   - <repo-relative-path> [(可選說明)]
    #   - <repo-relative-path> [(可選說明)]
引出行之後的清單項是「`#` + 空白 + `- `」開頭的行；再縮排的續行是上一項的
說明，不當成新項。**引出行與清單項都必須在同一個檔頭註解區塊裡。**

BACKLOG —— 通用性的誠實說明：
  這個 repo 裡，檔頭用「結構化清單」宣告呼叫端的地方**只有 refresh-wait.sh
  一處**。其他提到 consumer/caller 的檔頭（ssh.sh、tunnel-key.sh、crypto.sh、
  gh/install.sh…）都是散文，不是可解析的清單——所以掃描器是通用的，清單解析
  只在宣告符合 DECL_FORMAT 時才通用。--verbose 會把「提到 consumer/caller
  但格式不可解析」的檔案逐一列出，那份清單就是「著力點該在哪」的答案：
  要嘛把那些檔頭改成 DECL_FORMAT（那是格式決定，不是本工具該替你做的），
  要嘛承認它們不在這個判準的範圍內。兩者都比現在的「看起來一致」好。
"""
import os
import re
import subprocess
import sys

CODE_EXT = (".sh", ".yml", ".yaml")
CODE_BASENAMES = ("mlp", "preflight", "register-client", "verify-profile",
                  "register-provider.sh", "pool-residue", "register-repair-host")
MARKER_WORDS = ("consumer", "caller", "call site", "called by", "used by",
                "who calls", "sources this")

# 「宣告的引出行」：註解行裡同時出現 marker 詞、關鍵字 call、以及結尾的冒號。
DECL_INTRO = re.compile(
    r"(?i)\b(consumers?|callers?|call sites?)\b.*\bcall\b.*:\s*$")
# 清單項：'#' + 空白 + '-' + 空白 + 第一個 token（路徑）
DECL_ITEM = re.compile(r"^#\s*-\s+(\S+)")
# 呼叫：名字前後不可為識別字元
def call_re(name):
    return re.compile(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])")

DEF_LINE = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\s*\))?\s*\{")


def tracked_files(root):
    """git 追蹤的檔案。沒有 .git 時退回走檔案系統（測試的沙盒複本）。"""
    try:
        out = subprocess.run(["git", "-C", root, "ls-files", "-z"],
                             capture_output=True, check=True).stdout
        files = [f.decode() for f in out.split(b"\0") if f]
        if files:
            return files
    except (subprocess.CalledProcessError, OSError):
        pass
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for fn in filenames:
            files.append(os.path.relpath(os.path.join(dirpath, fn), root))
    return files


def is_code(path):
    if path.endswith(CODE_EXT):
        return True
    return os.path.basename(path) in CODE_BASENAMES


def header_block(lines):
    """檔頭註解區塊（到第一個非註解的非 shebang 行為止）。"""
    out = []
    for l in lines:
        s = l.strip()
        if s.startswith("#!"):
            continue
        if not s.startswith("#"):
            if out:
                break
            continue
        out.append(l)
    return out


def strip_comment(line):
    """去掉引號外的行尾註解。"""
    out = []
    quote = None
    i = 0
    while i < len(line):
        c = line[i]
        if quote:
            out.append(c)
            if c == quote and (i == 0 or line[i - 1] != "\\"):
                quote = None
        elif c in ("'", '"'):
            quote = c
            out.append(c)
        elif c == "#" and (not out or out[-1] in (" ", "\t")):
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def indent_of(line):
    """註解行「# 之後」的縮排深度。

    **要看 # 後面那一段**，不是行首。註解行的行首永遠是 '#'，所以量行首會讓
    每個縮排都是 0——而那會讓「續行比項目縮排更深」這個判斷永遠不成立，於是
    清單解析在第一項之後就停住。2026-09-26 的第一版就是這樣：declared 只收得到
    1 項，差額被誤報成「實際有、文件沒列」。**一個壞的解析器會長得像真實的不
    一致**，所以解析器本身也要能被注入釘。
    """
    i = 0
    while i < len(line) and line[i] in (" ", "\t"):
        i += 1
    if i < len(line) and line[i] == "#":
        i += 1
    n = 0
    while i < len(line):
        c = line[i]
        if c == " ":
            n += 1
        elif c == "\t":
            n += 8
        else:
            break
        i += 1
    return n


def find_declarations(path, lines):
    """回傳 [(func_name, [declared_path, ...]), ...]"""
    block = header_block(lines)
    decls = []
    i = 0
    while i < len(block):
        m = DECL_INTRO.search(block[i])
        if m:
            func = None
            fm = re.search(r"\bcall\s+([A-Za-z_][A-Za-z0-9_]*)", block[i])
            if fm:
                func = fm.group(1)
            items = []
            j = i + 1
            item_indent = None
            while j < len(block):
                raw = block[j]
                im = DECL_ITEM.match(raw)
                if im:
                    items.append(im.group(1).strip("`,.;"))
                    item_indent = indent_of(raw)
                    j += 1
                    continue
                # **續行要跳過，不是終止。** 2026-09-26 第一版在這裡 break，於是
                # 一個換行的說明（「- scripts/create-worker.sh (workflows … call it
                # via」／「create_worker_build_run_cmd's caller)」）會讓清單在
                # 第一項之後就結束——declared 數比實際少，而差額又被當成
                # 「實際有、文件沒列」。一個壞的解析器會長得像一個真實的不一致。
                if item_indent is not None and indent_of(raw) > item_indent:
                    j += 1
                    continue
                break
            # **清單被截斷要講，不要假裝它是完整的。** 如果我們停下來之後、同一個
            # 註解區塊裡還有 '- ' 項，那代表解析中途中斷了——把它說成「實際有、
            # 文件沒列」會讓一個壞的解析器**長得像一個真實的不一致**。那正是
            # 2026-09-26 第一版的下場（indent_of 量行首，縮排恆為 0，續行判定
            # 永遠不成立，declared 只收 1 項，差額被誤報成兩筆缺漏）。
            truncated = any(DECL_ITEM.match(l) for l in block[j:])
            if func and items:
                decls.append((func, items, truncated))
            i = j
            continue
        i += 1
    return decls


# 測試檔裡的呼叫是「在測這個函式」，不是「消費這個函式」。所以掃描時排除
# scripts/tests/——但**排除量必須可見**，否則就是把東西藏起來。EXCLUDED 會被
# --verbose 印出來，而每一條 MISMATCH 的訊息裡也會說明掃描範圍。
SCAN_EXCLUDE_PREFIX = ("scripts/tests/",)


def scan_callsites(root, files, name, declaring_file):
    """回傳 (實際呼叫端, 被範圍排除而沒算的呼叫端)。"""
    rx = call_re(name)
    hits = set()
    excluded = set()
    for rel in files:
        if not is_code(rel):
            continue
        try:
            lines = open(os.path.join(root, rel), encoding="utf-8").read().split("\n")
        except (OSError, UnicodeDecodeError):
            continue
        in_header = True
        for ln, line in enumerate(lines, 1):
            s = line.strip()
            if s.startswith("#!") or (in_header and s.startswith("#")):
                continue
            in_header = False
            code = strip_comment(line)
            if not code.strip():
                continue
            dm = DEF_LINE.match(code)
            if dm and dm.group(1) == name:
                continue                       # 定義那一行
            if rx.search(code):
                if rel.startswith(SCAN_EXCLUDE_PREFIX):
                    excluded.add(rel)
                else:
                    hits.add(rel)
    return sorted(hits), sorted(excluded)


def prose_backlog(root, files, parsed_files):
    """提到 consumer/caller 但不是 DECL_FORMAT 的檔頭——格式落後清單。"""
    out = []
    for rel in files:
        if not is_code(rel) or rel in parsed_files:
            continue
        try:
            lines = open(os.path.join(root, rel), encoding="utf-8").read().split("\n")
        except (OSError, UnicodeDecodeError):
            continue
        for l in header_block(lines):
            low = l.lower()
            if any(w in low for w in MARKER_WORDS):
                out.append(rel)
                break
    return sorted(out)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    verbose = "--verbose" in sys.argv
    if len(args) != 1:
        sys.stderr.write(__doc__)
        return 2
    root = args[0]
    files = tracked_files(root)

    problems = []
    checked = []
    for rel in files:
        if not is_code(rel):
            continue
        try:
            lines = open(os.path.join(root, rel), encoding="utf-8").read().split("\n")
        except (OSError, UnicodeDecodeError):
            continue
        decls = find_declarations(rel, lines)
        for func, declared, truncated in decls:
            actual, excluded = scan_callsites(root, files, func, rel)
            checked.append((rel, func, declared, actual, excluded, truncated))
            missing = sorted(set(actual) - set(declared))   # 實際有、文件沒列
            extra = sorted(set(declared) - set(actual))     # 文件列了、實際沒有
            if missing or extra:
                problems.append((rel, func, missing, extra))

    # 截斷優先於差額：宣告解析不下來的時候，下面那些差額**不是發現**，是解析器
    # 的副作用。先講這件事，否則一個壞的解析器會被讀成一個真實的不一致。
    for rel, func, declared, actual, excluded, truncated in checked:
        if truncated:
            print("DECLARATION-TRUNCATED %s :: %s —— 宣告清單在第 %d 項之後中斷，"
                  "同一個註解區塊裡還有 '- ' 項沒被解析到；下面的差額不可采信"
                  % (rel, func, len(declared)))

    for rel, func, missing, extra in problems:
        print("MISMATCH %s :: %s" % (rel, func))
        for m in missing:
            print("  undeclared-callsite %s   ← 實際會呼叫，檔頭沒列" % m)
        for e in extra:
            print("  declared-but-absent %s  ← 檔頭列了，但掃不到任何呼叫" % e)
        if excluded:
            print("  (scan scope: %s excluded as tests-in-exercising-the-function: %s)"
                  % (rel, ", ".join(excluded)))

    if verbose:
        print("CHECKED %d declaration(s):" % len(checked))
        for rel, func, declared, actual, excluded, truncated in checked:
            print("  %s :: %s declared=%d actual=%d excluded_tests=%d truncated=%s"
                  % (rel, func, len(declared), len(actual), len(excluded), truncated))
        bl = prose_backlog(root, files, {c[0] for c in checked})
        print("BACKLOG %d header(s) mention consumers/callers in prose (not DECL_FORMAT):" % len(bl))
        for b in bl:
            print("  %s" % b)
    if problems:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
