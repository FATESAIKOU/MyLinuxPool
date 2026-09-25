#!/usr/bin/env python3
"""wf-fn-sources.py — 每個 workflow step 呼叫的我方函式，必須被它 source 的東西定義。

2026-09-25 真線：`mlp worker new` 的 "Record the worker in POOL_WORKERS" 步驟
只 `source scripts/lib/ledger.sh`，卻呼叫 `create_worker_ledger_add`
（定義在 `scripts/create-worker.sh`）→ `command not found`、exit 127，
而那是埠已佔、image 已建、容器已起之後才炸。名字是當天 capabilities
重構時換的，source 沒跟著換。

判準（機械事實，不需理解語意）：
  1. 白名單 = repo 內所有「我方函式定義」（`^name() {`，排除 tests/）。
     這同時排除了外部指令同名造成的誤報（不在白名單就不是我方函式）。
  2. 對每個 workflow 的 `run:` 區塊，取命令位置的 token ∩ 白名單 = 被呼叫的我方函式。
  3. 可用的定義 = 該區塊 source 的檔案，遞迴展開它們自己的 `source` 行，
     聯集其中定義的函式。
  4. 被呼叫 − 可用 ≠ ∅ 就是 finding。

排除清單：**無**。跨檔 source 走「被 source 的檔案自己的 source 行」
（例如 `source scripts/create-worker.sh` 會連帶取得它 source 的
`lib/{log,profile,ledger,refresh-wait}.sh`），所以不必手寫豁免。
找不到的外部指令／同名指令不在白名單，自然不報。

已知界線（寧可漏報不誤報；誤報會讓人學會忽略檢查）：
  - 只認命令位置的形狀 `^`、`;`、`&`、`|`、`(`、`$(`、`` ` `` 後的 token，
    以及 `then/do/else` 後的第一個 token。`&&`/`||` 後、引號內的呼叫不追。
  - 只掃 workflow YAML 的 `run:`；`.github/actions/*/run.sh` 的動態
    source（`source "$SSH_LIB"`）不看。
  - 函式在字串裡被 eval 出來的情形看不到。
漏報的後果與本檢查的目標一致（exit 127），但誤報會侵蝕信任，取捨偏漏報。

用法：wf-fn-sources.py [repo-root]   有 finding 就逐行印出並以 1 結束。
"""
import glob
import os
import re
import sys

SRC = re.compile(r'^\s*(?:source|\.)\s+([^\s#;]+)', re.M)
DEF = re.compile(r'^([a-z_][a-z0-9_]*)\(\)\s*\{', re.M)
# 命令位置：行首、; & | ( $( ` 之後，或 then/do/else 之後
CMD = re.compile(r'(?:^|[;&|(]|\$\(|`)\s*([a-z_][a-z0-9_]*)\b', re.M)
KEYWORD_CALL = re.compile(r'^\s*(?:then|do|else)\s+([a-z_][a-z0-9_]*)\b', re.M)


def repo_fn_defs(root):
    """{fn: {file, ...}} for every repo file that is not a test."""
    patterns = ("scripts/*.sh", "scripts/lib/*.sh", "ops-scripts/*",
                "shared-configs/*/files/*", ".github/actions/**/*.sh")
    defs = {}
    for pat in patterns:
        for rel in glob.glob(os.path.join(root, pat), recursive=True):
            if "/tests/" in rel.replace(os.sep, "/"):
                continue
            try:
                text = open(rel, encoding="utf-8").read()
            except OSError:
                continue
            for m in DEF.finditer(text):
                defs.setdefault(m.group(1), set()).add(
                    os.path.normpath(os.path.relpath(rel, root)))
    return defs


def reachable_sources(root, path, seen=None):
    """Files reachable from `path` by following the repo's own source lines."""
    seen = seen if seen is not None else set()
    norm = os.path.normpath(path)
    if norm in seen:
        return set()
    seen.add(norm)
    full = os.path.join(root, norm)
    if not os.path.exists(full):
        return {norm}
    out = {norm}
    try:
        text = open(full, encoding="utf-8").read()
    except OSError:
        return out
    for m in SRC.finditer(text):
        target = m.group(1).strip('"\'')
        # ${SCRIPT_DIR}-relative and $()-wrapped paths cannot be resolved
        # statically; skip them rather than guess (miss over false positive).
        if "$" in target or "`" in target:
            continue
        base = os.path.dirname(norm)
        out |= reachable_sources(root, os.path.normpath(os.path.join(base, target)), seen)
    return out


def analyse(root, workflows):
    defs = repo_fn_defs(root)
    known = set(defs)
    findings = []
    try:
        import yaml
    except ImportError:
        return ["wf-fn-sources: PyYAML is required to parse workflow YAML"]
    for wf in workflows:
        try:
            doc = yaml.safe_load(open(wf, encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001 - report, never crash the check
            findings.append("%s: unreadable YAML (%s)" % (wf, exc))
            continue
        for job_name, job in (doc.get("jobs") or {}).items():
            for step in job.get("steps") or []:
                run = step.get("run") or ""
                if not run:
                    continue
                steps_label = step.get("name") or step.get("id") or "<unnamed>"
                sourced = set()
                for m in SRC.finditer(run):
                    target = m.group(1).strip('"\'')
                    if "$" in target or "`" in target:
                        continue
                    sourced |= reachable_sources(root, target)
                available = set()
                for src_file in sourced:
                    for fn, where in defs.items():
                        if src_file in where:
                            available.add(fn)
                called = set(CMD.findall(run)) | set(KEYWORD_CALL.findall(run))
                missing = sorted((called & known) - available)
                for fn in missing:
                    sources_shown = sorted(os.path.basename(s) for s in sourced) or ["<none>"]
                    findings.append(
                        "%s [%s]: step '%s' calls %s() but what it sources (%s) "
                        "does not define it — 'command not found' at runtime"
                        % (wf, job_name, steps_label, fn, ", ".join(sources_shown)))
    return findings


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    workflows = sys.argv[2:] if len(sys.argv) > 2 else sorted(
        glob.glob(os.path.join(root, ".github/workflows/*.yml")))
    findings = analyse(root, workflows)
    if findings:
        print("\n".join(findings))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
