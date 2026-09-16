#!/usr/bin/env bash
# test-tunnel-identity.sh — the tunnel identity path must have exactly ONE
# definition, and every consumer must end up asking for the same key
# (RUNBOOK §7.12, third incident: the rotate probe hard-coded
# ~/.ssh/id_pool while pool-tunnel had migrated to id_tunnel, so the second
# rotate after KEY-DESIGN §8 failed with "Permission denied (publickey)").
#
# The single source is shared-configs/pool-runtime/files/tunnel-identity.sh
# (defines TUNNEL_KEY). Consumers: pool-tunnel (the real tunnel), pool-sync
# (mints and publishes the key), pool-status, and rotate's tunnel probe.
#
# Assertions:
#   1. tunnel-identity.sh is the ONLY place in the repo (outside tests and
#      docs) that DEFINES the path — references may be many, and a comment
#      mentioning the retired key is not a violation.
#   2. Behavioral: the probe command is EXECUTED the way a provider would
#      run it (fake ssh records argv, HOME set to the provider's), and the
#      path it hands to ssh must be the provider's own tunnel key. This is
#      the assertion that catches a probe referencing a variable the
#      provider does not have: the generator looks fine on the runner, but
#      on the provider the shell expands it to nothing and ssh is invoked
#      with a dangling `-i`.
#   3. Deployment: every file that sources tunnel-identity.sh must have it
#      shipped alongside. A `source` of a file that never gets installed
#      makes the consumer die at startup — worse than the hard-coded path
#      it replaced.
#   4. Injection: put a hard-coded id_pool back into the probe -> 2 reddens.
#   5. Injection: point TUNNEL_KEY at id_pool -> 1 reddens.
#
# Run: scripts/tests/test-tunnel-identity.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

ROTATE="scripts/rotate-gateway.sh"
TUNNEL_IDENTITY="shared-configs/pool-runtime/files/tunnel-identity.sh"
POOL_TUNNEL="shared-configs/pool-runtime/files/pool-tunnel"
POOL_STATUS="shared-configs/pool-runtime/files/pool-status"
POOL_SYNC="shared-configs/pool-runtime/files/pool-sync"
INSTALL_SH="shared-configs/pool-runtime/install.sh"
WORKER_DOCKERFILE="profiles/worker/default/Dockerfile"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-tunnel-identity.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/bin" "$SANDBOX/runner-home" "$SANDBOX/provider-home"

TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT="timeout 30"
fi

pass=0; fail=0; injfail=0
ok()      { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()     { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
inj_ok()  { printf '  inj ok    %s\n' "$1"; }
inj_bad() { printf '  inj FAIL  %s\n' "$1"; injfail=1; }

# Fake ssh: dumps its argv one argument per line, so the value after -i can
# be read without any real connection.
cat > "$SANDBOX/bin/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
: > "${FAKE_SSH_ARGV_LOG:?}"
for a in "$@"; do printf '%s\n' "$a" >> "$FAKE_SSH_ARGV_LOG"; done
exit 0
FAKE_SSH
chmod +x "$SANDBOX/bin/ssh"

# tunnel_key_of <script> <home> — the TUNNEL_KEY a consumer ends up with.
tunnel_key_of() {
    HOME="$2" $TIMEOUT bash -c \
        'source "$1" >/dev/null 2>&1; printf "%s" "${TUNNEL_KEY:-}"' _ "$1" 2>/dev/null
}

# probe_identity <rotate-file> <runner-home> <provider-home> <argv-log>
#   Generate the probe as the workflow does, then EXECUTE it as a provider
#   would, and print the argument passed to ssh -i. An empty print means
#   the generator failed, the execution failed, or -i had no value.
probe_identity() {
    local rotate_file="$1" runner_home="$2" provider_home="$3" log="$4"
    local cmd
    cmd="$(HOME="$runner_home" $TIMEOUT bash -c \
        'source "$1" >/dev/null 2>&1; rotate_build_tunnel_probe_cmd 203.0.113.9 sshproxy 2999 ""' \
        _ "$rotate_file" 2>/dev/null)"
    if [[ -z "$cmd" ]]; then
        printf ''
        return 1
    fi
    : > "$log"
    HOME="$provider_home" PATH="$SANDBOX/bin:$PATH" FAKE_SSH_ARGV_LOG="$log" \
        $TIMEOUT bash -c "$cmd" >/dev/null 2>&1
    awk 'prev=="-i" { print; exit } { prev=$0 }' "$log"
}

# ===========================================================================
echo "── 1. tunnel-identity.sh 是唯一定義處 ──"
if [[ ! -f "$TUNNEL_IDENTITY" ]]; then
    bad "tunnel-identity.sh 不存在（${TUNNEL_IDENTITY}）"
else
    # "Definition" = a path literal in CODE. A reference through the shared
    # variable (`-i "$TUNNEL_KEY"`) is not a definition; a comment mentioning
    # the retired key is not either (docs/README and source comments are
    # excluded, and trailing comments are stripped before matching). What IS
    # a definition: assigning the path to anything, AND hard-coding the
    # literal anywhere else in code — both are a second place to update.
    LIT="$SANDBOX/path-literals.txt"
    python3 - "$REPO_ROOT" > "$LIT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
EXCLUDE_DIRS = {".git", "docs", "node_modules"}
EXTS = (".sh", ".yml", ".yaml", ".service", ".json", ".py")
LITERAL = re.compile(r'\.ssh/id_(tunnel|pool)')

hits = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in EXCLUDE_DIRS]
    for fn in filenames:
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, root)
        if "/tests/" in ("/" + rel + "/"):
            continue
        if rel.startswith("docs/") or rel.startswith("README"):
            continue
        if not (rel.endswith(EXTS) or fn == "Dockerfile"):
            continue
        try:
            lines = open(full, encoding="utf-8", errors="replace").read().split("\n")
        except OSError:
            continue
        for i, line in enumerate(lines, 1):
            # crude trailing-comment strip: a `#` preceded by whitespace
            code = re.split(r'\s#', line, maxsplit=1)[0]
            s = code.strip()
            if not s or s.startswith("#"):
                continue
            if LITERAL.search(code):
                hits.append("%s:%d: %s" % (rel, i, s[:110]))

for h in sorted(hits):
    print(h)
PY
    DEFS="$(cat "$LIT")"
    DEFS_CNT="$(printf '%s\n' "$DEFS" | grep -c . || true)"
    if [[ "$DEFS_CNT" -eq 1 && "$DEFS" == *"$TUNNEL_IDENTITY"* ]]; then
        ok "id_tunnel 路徑在程式碼中只定義一次（${TUNNEL_IDENTITY}）"
    else
        bad "id_tunnel 路徑在程式碼中定義了 ${DEFS_CNT:-0} 處：$(printf '%s' "$DEFS" | tr '\n' ' ')"
    fi
fi

# ===========================================================================
echo "── 2. 探測指令在 provider 上真的指向那把鑰匙（行為性）──"
RUNNER_HOME="$SANDBOX/runner-home"
PROVIDER_HOME="$SANDBOX/provider-home"
# A real provider has tunnel-identity.sh installed by pool-runtime's
# install.sh; the probe sources it there. Mirror that, or the probe
# resolves $TUNNEL_KEY to empty and this suite reports a defect that
# only exists in the sandbox.
mkdir -p "$PROVIDER_HOME/.mylinuxpool/bin"
cp "$TUNNEL_IDENTITY" "$PROVIDER_HOME/.mylinuxpool/bin/tunnel-identity.sh"
SHARED_KEY_PATH="$(tunnel_key_of "$TUNNEL_IDENTITY" "$PROVIDER_HOME")"
POOL_TUNNEL_KEY_PATH="$(tunnel_key_of "$POOL_TUNNEL" "$PROVIDER_HOME")"
# The suffix BELOW a home directory ("/.ssh/id_tunnel"). SHARED_KEY_PATH was
# computed with PROVIDER_HOME as HOME, so strip that; stripping RUNNER_HOME
# would be a no-op and leave an absolute path in SHARED_SUFFIX.
SHARED_SUFFIX="${SHARED_KEY_PATH#"$PROVIDER_HOME"}"

if [[ -z "$SHARED_KEY_PATH" ]]; then
    bad "2a. tunnel-identity.sh 定義了 TUNNEL_KEY（目前沒有）"
else
    ok "2a. tunnel-identity.sh 定義了 TUNNEL_KEY（${SHARED_KEY_PATH}）"
fi
if [[ -z "$POOL_TUNNEL_KEY_PATH" ]]; then
    bad "2b. pool-tunnel 取得 TUNNEL_KEY（目前沒有；無從比對）"
elif [[ "$POOL_TUNNEL_KEY_PATH" == "$SHARED_KEY_PATH" && -n "$SHARED_KEY_PATH" ]]; then
    ok "2b. pool-tunnel 的鑰匙來自單一來源（${POOL_TUNNEL_KEY_PATH}）"
else
    bad "2b. pool-tunnel 的鑰匙與單一來源不同（pool-tunnel=${POOL_TUNNEL_KEY_PATH:-<none>}, shared=${SHARED_KEY_PATH:-<none>}）"
fi

PROBE_ID="$(probe_identity "$ROTATE" "$RUNNER_HOME" "$PROVIDER_HOME" "$SANDBOX/probe-argv.log")"
PROBE_ARGV="$(tr '\n' ' ' < "$SANDBOX/probe-argv.log" 2>/dev/null | head -c 240)"
if [[ -z "$PROBE_ID" ]]; then
    bad "2c. 探測指令在 provider 上把有效的 -i 傳給 ssh（傳出空值；fake ssh argv: ${PROBE_ARGV:-<未被呼叫>}）——產生端看起來正常，provider 端展開成空字串"
elif [[ "$PROBE_ID" == "$RUNNER_HOME"* ]]; then
    bad "2c. 探測指令帶著 runner 的家目錄（${PROBE_ID}）——provider 上不存在那個路徑"
elif [[ "$PROBE_ID" != *"$SHARED_SUFFIX" ]]; then
    bad "2c. 探測指令要的鑰匙不是單一來源定義的（probe=${PROBE_ID}, 應以 ${SHARED_SUFFIX} 結尾；pool-tunnel 用 ${POOL_TUNNEL_KEY_PATH:-<none>}）"
elif [[ "$PROBE_ID" != "$PROVIDER_HOME$SHARED_SUFFIX" && "$PROBE_ID" != /home/*"$SHARED_SUFFIX" ]]; then
    bad "2c. 探測指令的路徑在 provider 上不存在（${PROBE_ID}；預期 ${PROVIDER_HOME}${SHARED_SUFFIX} 或 /home/...${SHARED_SUFFIX}）"
else
    ok "2c. 探測指令在 provider 上指向單一來源定義的鑰匙（${PROBE_ID}）"
fi
if [[ "$PROBE_ID" == *"id_pool"* ]]; then
    bad "2d. 探測指令仍指向退役的共用鑰匙（id_pool）——第二次 rotate 正是這樣失敗的"
else
    ok "2d. 探測指令未指向退役的共用鑰匙"
fi

# ===========================================================================
echo "── 3. 每個 source tunnel-identity.sh 的檔案，都把該檔一起佈署 ──"
for consumer in "$POOL_TUNNEL" "$POOL_STATUS" "$POOL_SYNC" "$ROTATE"; do
    if [[ ! -f "$consumer" ]]; then
        bad "3. $(basename "$consumer") 不存在"
        continue
    fi
    if grep -q 'TUNNEL_KEY' "$consumer" && grep -q 'tunnel-identity\.sh' "$consumer"; then
        ok "3. $(basename "$consumer") source tunnel-identity.sh 並用 TUNNEL_KEY"
    else
        bad "3. $(basename "$consumer") 未接上單一來源（缺 TUNNEL_KEY 或 tunnel-identity.sh）"
    fi
done
# The provider-side consumers run from <home>/.mylinuxpool/bin, so the unit
# installer must copy the shared file next to them; a `source` of a file
# that is never installed kills the consumer at startup.
if [[ ! -f "$INSTALL_SH" ]]; then
    bad "3. install.sh 不存在（提供者端無法佈署單一來源）"
elif grep -q 'tunnel-identity\.sh' "$INSTALL_SH"; then
    ok "3. install.sh 會佈署 tunnel-identity.sh（provider 端才找得到）"
else
    bad "3. install.sh 沒有安裝 tunnel-identity.sh——pool-tunnel/pool-status/pool-sync 會在 provider 上 source 失敗"
fi
# The worker container runs pool-tunnel from /usr/local/bin; the Dockerfile
# must COPY the shared file there too.
if [[ ! -f "$WORKER_DOCKERFILE" ]]; then
    bad "3. worker Dockerfile 不存在（容器端無法佈署單一來源）"
elif grep -q 'tunnel-identity\.sh' "$WORKER_DOCKERFILE"; then
    ok "3. worker Dockerfile 會 COPY tunnel-identity.sh（容器端才找得到）"
else
    bad "3. worker Dockerfile 沒有 COPY tunnel-identity.sh——容器裡的 pool-tunnel 會在啟動時 source 失敗"
fi

# ===========================================================================
echo "── 4. 注入：probe 改回硬寫 id_pool → 第 2 條必須紅 ──"
INJ_ROOT="$SANDBOX/inj"
if [[ ! -f "$ROTATE" || ! -f "$POOL_TUNNEL" ]]; then
    inj_bad "4. 被測物缺失（${ROTATE} / ${POOL_TUNNEL}），無從注入"
else
    mkdir -p "$INJ_ROOT/scripts/lib" "$INJ_ROOT/shared-configs/pool-runtime/files"
    cp -R scripts/lib/. "$INJ_ROOT/scripts/lib/" 2>/dev/null
    cp -R shared-configs/pool-runtime/files/. "$INJ_ROOT/shared-configs/pool-runtime/files/" 2>/dev/null
    if python3 - "$ROTATE" "$INJ_ROOT/scripts/rotate-gateway.sh" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
# Revert the probe's identity to the old hard-coded path, whatever
# expression it currently uses between `-i ` and ` -o IdentitiesOnly`.
pat = re.compile(r'(-i\s+)(\S+)(\s+-o\s+IdentitiesOnly)', re.M)
out, n = pat.subn(lambda m: m.group(1) + r'\\$HOME/.ssh/id_pool' + m.group(3), src, count=1)
if n == 0:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(out)
PY
    then
        INJ_ID="$(probe_identity "$INJ_ROOT/scripts/rotate-gateway.sh" "$RUNNER_HOME" "$PROVIDER_HOME" "$SANDBOX/inj-argv.log")"
        if [[ -z "$INJ_ID" ]]; then
            inj_bad "4. 注入版探測沒有輸出 -i 值（harness 問題）"
        elif [[ "$INJ_ID" == "$POOL_TUNNEL_KEY_PATH" ]]; then
            inj_bad "4. 注入版仍與 pool-tunnel 相同（${INJ_ID}）——第 2 條沒有判別力"
        elif [[ "$INJ_ID" == *"/.ssh/id_pool" ]]; then
            inj_ok "4. 注入版要的是 ${INJ_ID}，pool-tunnel 用 ${POOL_TUNNEL_KEY_PATH}——第 2 條會紅"
        else
            inj_bad "4. 注入版輸出非預期路徑（${INJ_ID}）——harness 問題"
        fi
    else
        inj_bad "4. 找不到 probe 的 -i 參數可注入（needle 落空）——harness 問題"
    fi
fi

# ===========================================================================
echo "── 5. 注入：TUNNEL_KEY 指到 id_pool → 第 1 條必須紅 ──"
if [[ ! -f "$TUNNEL_IDENTITY" ]]; then
    inj_bad "5. tunnel-identity.sh 不存在，無從注入"
else
    if python3 - "$TUNNEL_IDENTITY" "$SANDBOX/identity-inj.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
out = src.replace('.ssh/id_tunnel', '.ssh/id_pool')
if out == src:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(out)
PY
    then
        if grep -qE '^[^#]*=[[:space:]]*"[^"]*\.ssh/id_tunnel"' "$SANDBOX/identity-inj.sh" 2>/dev/null; then
            inj_bad "5. 注入檔仍含 id_tunnel 定義——注入沒生效"
        else
            inj_ok "5. 注入後 id_tunnel 定義消失——第 1 條會紅"
        fi
    else
        inj_bad "5. 注入腳本沒改到檔案（needle 落空）——harness 問題"
    fi
fi

echo
printf 'passed %d / failed %d\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then exit "$fail"; fi
if [[ "$injfail" -ne 0 ]]; then exit 2; fi
exit 0
