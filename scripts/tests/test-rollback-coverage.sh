#!/usr/bin/env bash
# test-rollback-coverage.sh — create-worker 失敗回滾必須讓池側不宣告那個 worker。
#
# 2026-09-26 實測（throwaway 分支，run 36202314872）：把 create 打到
# `Verify worker is actually reachable` 失敗，容器／POOL_WORKERS／placeholder／
# 在聽的埠**四邊逐字無變化**（回滾收得乾淨），但 Gateway 的
# `/var/lib/mylinuxpool/state.json` 留下一筆 port=2304、serial 9→10、
# source=create-worker#36202314872。根因：create-worker.yml 的順序是
# 「Record the worker in POOL_WORKERS → Push the state cache → Verify（失敗）」，
# 而四個 `if: failure()` 步驟（抓 log／刪容器／放埠／刪帳本項目）沒有重推快取。
# 對照 delete-worker.yml：刪完帳本（:124）就 push-state（:162），是對稱的。
#
# ---- 釘的是不變量，不是某一行程式碼 --------------------------------------
#
#   > create-worker 失敗時，池側不得還有任何一份「宣告」說這個 worker 存在。
#
# 兩條硬性要求（都不釘「有沒有某個 step」）：
#   * 別人用**另一種方式**達成同一件事時不能誤紅。所以這支測試**模擬整條失敗
#     路徑**（把 job 打在成功路徑的每一個步驟上，跑完所有 failure() 步驟，
#     然後看池側還剩下什麼），不是檢查 step 存在與否。補救可以是「加一個回滾
#     步驟」（§4a），也可以是「把寫入移到最後」（§4f）——兩種都必須轉綠。
#   * 別人加了一個**壞掉的**補救時不能誤綠。所以補救是**真的被執行**、真的作用
#     在池子狀態上，然後才檢查殘留——把快取推在「刪帳本」之前的補救會被照出
#     還在（§4d／§4e）。
#
# ---- 「宣告」分三類，這個分類是判準的核心 --------------------------------
#
#   declaration  池側有任何一份資料「宣告這個 worker 存在」。必須被回滾收掉：
#                container / placeholder / ledger / state-cache /
#                authorized-keys
#   rebuildable  寫了但不是宣告、而且不累積：image（`docker build -t` 固定
#                tag，每次覆寫；池子裡沒有任何東西靠它決定要不要連一台 worker）。
#                認得它是為了不要被「未建模」閘門誤紅；不要求回滾。
#   unknown      看得見它在改東西，但認不出改的是哪一種狀態 → **紅**。這是
#                「下次有人加第六樣狀態時也會紅」的機制（§4c 證明它會）。
#
# 分類不照 step 名字，靠**這個 repo 自己的函式名**加上遠端命令的改動 token
# （create_worker_ledger_add、pool-port-alloc --release、docker rm、
# .github/actions/push-state…）。那些是這個 repo 的語彙；換掉名字要連帶換掉
# 這裡。這是刻意的：真正的守衛要站在實作改不掉的接縫上。
#
# ---- 模擬模型與它的極限（誠實記在這裡）-----------------------------------
#
# * **失敗的步驟假設「沒有寫成」**。真的部分寫入（record step 的
#   `> "$f.tmp" && mv "$f"` 兩行之間死掉）不在模型裡——那會留下 `.tmp`，
#   由 pool-residue 的 `stray` 那一行負責，不是這支測試的判準。
# * **失敗點只放在成功路徑上**。清理步驟自己失敗（`docker rm -f` 掉了）會不會
#   留下殘骸是另一個問題、另一個判準；混進來會讓這支測試同時回答兩件事，而
#   兩件事的修法不同。
# * output 的可用性**由順序決定**：第 N 步在失敗點 F 之後就沒跑，
#   `steps.X.outputs.Y` 就是空的。所以 `if: failure() && steps.port.outputs.port
#   != ''` 這種守衛是被真的評估，不是假裝永遠成立——§3 會找到一個這種守衛
#   造成的孤兒 placeholder（§2 會印出來；實測打中的最後一步看不到它）。
# * 埠的配置、帳本格式、state.json 的組裝、authorized_keys 的組裝，全部呼叫
#   **本 repo 自己的函式**（create_worker_compute_identity、
#   create_worker_ledger_add、ledger_remove、state_next_serial + state_build、
#   refresh_collect_tunnel_keys + rotate_assemble_sshproxy_keys）。所以量到的
#   是實作，不是這支測試的模型；模型錯了會對不上，不會假綠。
# * 夾具刻意照現在的真池子（4 個 worker、4 個 placeholder、4 個在聽的埠），
#   所以模擬出來的殘留跟真實那次實驗同名同埠（2304 /
#   mlp-fh-proxy-asus-default-36202314872），可以直接對照 before/after。
# * 注入用的 workflow 副本全部在 $SANDBOX 裡；不連網、不連池子、不寫 .github/。
#
# ---- 2026-09-26：這個守衛曾經對真實殘骸說「綠」，以及為什麼 ----------------
#
# 這一版之前的同一支測試，對**未修改的** create-worker.yml 報
# 「ok 3a. state-cache：任何失敗點之後，快取都不再宣告那個 worker / passed 6 /
# failed 0」，而那個當下真實叢集裡留著 port=2304（run 36202314872）。一個說
# 乾淨、而現實留著殘骸的守衛比沒有守衛糟——它會讓這個缺陷被當成已覆蓋。根因是
# 兩個 bug 疊在一起，**兩個都是這支測試自己的**：
#
# 1. **我把檔案「路徑」當成 JSON 內容傳給 repo 函式。**
#    `state_build <serial> <source> <nodes_json> <workers_json>` 與
#    `refresh_collect_tunnel_keys <vars_json> <workers_json>` 收的是本文；
#    傳路徑進去，兩者各自安靜地失敗（jq 報 invalid JSON / "neither an object
#    with .variables nor an array"），留下 **0 _byte 的 state.json 與
#    authkeys**。修法：傳 `$(cat file)`。
# 2. **「讀不到」被讀成「讀到，而且裡面是空的」。** 這是整件事的關鍵，也是這個
#    repo 修過六次的同一個形狀（docs/TESTPLAN.md §1.7）：`survivors` 拿著空字串
#    的 state.json 去問 jq，jq 對空檔案回 1，於是「快取裡沒有那個 worker」被
#    報成綠。**只修 1 不修 2，這個陷阱只是換個觸發時機再咬一次**（函式改名、
#    參數抽錯、jq 壞掉、fixture 變形……全都會走同一條路）。
#    所以現在：`store_readable` 先問每一份狀態讀不讀得到，讀不到就報
#    `unknown:<store>` 而不是跳過；`write_store` 寫完立刻驗收，寫出空檔或非法
#    狀態就報 `!harness:`，而 `!harness:` 會讓整個結果被標成不可采信
#    （§3h + §5 的結論）。**猜錯的方向一律是綠，所以閘門一律保守。**
#
# 同一輪還抓到三個「語言層」的坑，都記在這裡因為它們會 silent 地改變結論：
#
#   * `IFS=$'\t'` 讀欄位時，**空欄位會讓後面的欄位整個左移**。tab 屬於 IFS 的
#     空白字元，連續空白被當成一個分隔符。成功路徑的步驟沒有 `if:`（guard 欄
#     是空的），於是 effects 讀成空字串——所有成功路徑的寫入都不會被執行，
#     模擬於是回報「每個失敗點都收乾淨」。改用 `\x1f`（非 IFS 空白）才對。
#   * `$var` 後面**緊接全形括號**時，bash 3.2 會把那個 multibyte 字元收進變數
#     名（`step $pts）` → 找 `pts）`）→ `unbound variable`。用 `${pts}`。
#   * `[[ x =~ ... ]]` 的樣式裡若含未加引號的括號，bash 3.2 直接語法錯誤；
#     樣式要放進變數再比對。
#
# ---- 2026-09-26 第三輪：4h ——「只補一半也全綠」有兩個獨立的成因 ------------
#
# 症狀：4h 報「只補一半的補救居然全綠」。診斷經過三層，**前兩層都是我的探針壞掉，
# 最後才是判準的問題**。三層都記在這裡，因為每一層都是同一個形狀。
#
# **第一層（探針從來沒構造出「只補一半」）。** `no-remedy` 只移除「重推快取」那一
# 種補救，沒有移除 authkeys 的補救。於是它問「只補快取會怎樣」，實際跑的卻是
# 「兩種都補」。探針問的問題與它構造的狀態不是同一個，於是它綠，而那個綠被讀成
# 「守衛接受只補一半」。**探針沒構造出它聲稱的狀態，比探針紅更危險**：它讓人以為
# 那一條被驗過了。
#
# **第二層（串接的探針等於沒有探針）。** 修法一開始是「no-remedy 兩種都拿掉，再
# 只加一種」——兩個探針。但 `probe` 每次都**從基底重新出發**，所以第二步根本看不見
# 第一步的結果，它把基底自己那份 authkeys 補救又帶回來了。半套這種狀態必須在**一個
# 轉換裡**做出來（現在是 `half-cache` / `half-authkeys` 兩個單步模式）。
#
# **第三層（判準是彙總布林）。** 這一層才是真的。`3b` 問的是「有沒有殘留」——
# 一個彙總值。而「只補快取」與「兩種都沒補」在彙總裡是同一個值：**彙總會讓一個被
# 覆蓋掉另一個**，而且它無法指名是哪一種殘留。修法是**每一種池側狀態各自獨立判定**：
# §3 現在印五行（container / placeholder / ledger / state-cache / authorized-keys），
# 每一行是一種狀態自己的結論，3z 只是把五個獨立結果印在一起。於是 4h 能指出
# **沒被補的是哪一種**。
#
# 這一輪的驗收（工單指定）：只補快取 → 紅且指名 authorized_keys；只補
# authkeys → 紅且指名 state-cache；兩種都補（現況）→ 綠。got 值在 §4 的輸出裡。
#
# 順帶修掉一個會誤導人的地方：結論區塊原本把「注入失敗」也算成「結論：紅」。於是
# 一個**不變量全過、但注入防線失敗**的結果會被讀成「守衛抓到殘骸」。現在分開說：
# 不變量紅 → 「結論：紅」；不變量綠但注入失敗 → 「綠，但這個綠的可信度要打折」。
#
# ---- 2026-09-26 第二輪：3a 的綠一度沒有意義，因為探針是「附加」的 ----------
#
# impl 補上了「失敗時重推快取」，3a/3b 轉綠——但同一跑裡 4d/4e 紅著，報的是
# 「壞掉的補救居然綠了」。那兩句擱在一起就是這張工單的指控，而它**成立**。
#
# **根因不在 `if:` 的評估。** 對照組：基底自己的補救與我合成的補救，guard 形式
# 完全相同（`if: failure() && steps.port.outputs.port != ''`），模型對兩者的判斷
# 一樣。差異在**探針怎麼構造**：
#
#   舊探針：在 workflow 尾部**附加**一個壞補救。
#   新探針：先確保基底有補救，再**就地把它改壞**（改寫它自己的 `if:`／把整塊
#           搬到刪帳本之前）。
#
# 舊探針在「基底沒有補救」時有效（原本的洞還在，附加的壞補救不影響結論）；基底
# 一旦自己修好，那個壞補救就變成多餘的，基底那個仍然把快取清乾淨，於是探針回綠。
# 實測（基底 = impl 那版，失敗路徑的快取補救數量見括號）：
#
#   舊式 dead-if     （2 個補救）→ violations_for = []            → 綠
#   舊式 wrong-order （2 個補救）→ violations_for = []            → 綠
#   新式 dead-if     （1 個補救）→ 18 ;; state-cache / 19 ;; state-cache
#   新式 wrong-order （1 個補救）→ 15,16,17,18,19 ;; state-cache
#
# wrong-order 出現**五個**失敗點（不是兩個）值得記：那正是「順序錯的補救比不修更
# 糟」的量化——一旦髒的快取被推上去，之後每一個失敗點都會留著它。
#
# 連帶修掉的兩個模型洞（都是「動作有沒有發生」而不是「後果」）：
#
#   * **「動作有跑，但跑失敗了」原本不存在這個狀態。** 只看守衛，模型只有
#     「守衛不成立 → 不跑」與「守衛成立 → 回滾成功」兩種。於是一個 `with:`
#     引用了**還沒被產出的 output** 的補救（Actions 給空字串，那一步會失敗）
#     被算成有效的回滾。現在補上第三種：守衛成立、但引用的 output 有一個是由失敗
#     點之後的步驟產生的 → 動作會失敗 → 狀態沒被回滾（探針 4e）。
#     判斷是**位置性**的（那一步跑過沒有），不是靠 output 的值——`stdout` 同時
#     由 claim / run / pubkey 三個 pool-ssh 步驟產生，只認名稱會把「還沒產生」
#     誤判成「已經有值」。
#   * **authorized_keys 這個視角在結構上抓不到它存在的理由要抓的殘骸。** worker
#     的 tunnel key 在 authorized_keys 裡的 comment 是**去掉 `mlp-` 前綴**的那個
#     名字（真實叢集實測：`fh-proxy-asus-default-36202314872`）。只拿容器名去
#     grep 永遠不會中，於是輸出看起來乾淨。`scripts/lib/ledger.sh` 的
#     ledger_find 註解裡早記了這兩種拼法都在流通中。
#
# 這一輪為了查 impl 的說法（而不是相信 3a 的綠）而找到的三個**假綠**，每一個都長得
# 跟真綠一模一樣：
#
#   1. 分類器的函式偵測正則是 `name\s+["$]`——「後面一定要是引號或 $」。於是
#      `create_worker_dispatch_refresh_and_wait 300`（後面是數字）**完全沒被認出
#      來**：那個步驟既沒有效果、也沒被報成未建模，靜靜從分類裡消失。連帶後果是
#      模擬器從來沒把 worker 的 tunnel key 寫進 authorized_keys，於是這種殘骸在
#      模型裡不可能出現。改成抓「命令位置」的識別字並扣掉 shell 內建。
#   2. 上面那個 authorized_keys 拼法問題。
#   3. 探針裡「已經有補救了嗎」的判斷寫成「整個檔案裡出現過 refresh」——成功路徑
#      本來就有 refresh，於是 4b 從來不追加 authkeys 補救，紅的原因與它要驗的無關。
#
# 結論：`3a 的綠` 只有在 **4c/4d/4e/4h 同時紅**（壞的、順序錯的、壞參照的、只補
# 一半的補救都會被抓）之後才是證據。這個檔案現在把四者一起印出來，就是為了讓
# 「綠」和「這個綠值多少錢」在同一個畫面上。
#
# ---- 這支測試的模型還有什麼沒建模（誠實記在這裡）------------------------
#
# * **清理步驟自己失敗**（`docker rm -f` 掉了）會不會留下殘骸：不在模型內。
#   那是另一個問題、另一個判準；混進來會讓這支測試同時回答兩件事。
# * **失敗的步驟假設「沒有寫成」**。真的部分寫入（record step 的
#   `> "$f.tmp" && mv "$f"` 兩行之間死掉）會留下 `.tmp`，那是 pool-residue 的
#   `stray` 那一行的判準，不是這裡的。
# * **`if:` 只認兩種形狀**：`steps.X.outputs.Y != ''` 與 `== 'literal'`。其他
#   形狀一律回報成 harness limitation，不猜。只看「有沒有引用」而不看運算子，
#   是上一版讓「加了 push-state 但 if: 永遠不成立」這個壞補救轉綠的原因
#   （注入 4d 就是釘這件事）。
# * **authorized_keys 是第二個缺口**，而工單列的五樣裡沒有它。實測：在真實
#   Gateway 上，死掉那次的 worker key 仍然在 `/home/sshproxy/.ssh/
#   authorized_keys` 裡（`refresh-authorized-keys` 是從 POOL_WORKERS 全部重組
#   再覆寫，所以要等「下一次 refresh」才會掉；失敗路徑沒有觸發 refresh）。
#   修法與快取那個同形，但它是獨立的一個，4a 只修快取、4b 兩個都修。
#
# Run: scripts/tests/test-rollback-coverage.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"
WF=".github/workflows/create-worker.yml"

for tool in python3 jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: ${tool} not on PATH" >&2; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "ERROR: python3 + pyyaml required" >&2; exit 1; }
[[ -f "$WF" ]] || { echo "ERROR: ${WF} missing" >&2; exit 1; }
DEBUG=0
for a in "$@"; do
    case "$a" in
        --debug) DEBUG=1 ;;
        *) echo "usage: $0 [--debug]" >&2; exit 2 ;;
    esac
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-rollback-cov.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
REPO="$SANDBOX/repo"
mkdir -p "$SANDBOX/wf" "$REPO"
rsync -a --exclude='.git' --exclude='tests' "$REPO_ROOT/scripts/" "$REPO/scripts/" 2>/dev/null \
  || { mkdir -p "$REPO/scripts"; cp -R "$REPO_ROOT/scripts/." "$REPO/scripts/"; rm -rf "$REPO/scripts/tests"; }
rsync -a "$REPO_ROOT/shared-configs/" "$REPO/shared-configs/" 2>/dev/null || true
mkdir -p "$REPO/profiles/worker/default"
printf '{"name":"default","role":"worker","secrets":{},"capabilities":{}}\n' \
    > "$REPO/profiles/worker/default/profile.json"

pass=0; fail=0; injpass=0; injfail=0
ok()      { pass=$((pass+1));      printf '  ok    %s\n' "$1"; }
bad()     { fail=$((fail+1));      printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# 夾具常數：對齊真實那次實驗（run 36202314872），讓模擬殘留可與 before/after 對照
FIX_PROVIDER="fh-proxy-asus"
FIX_IMAGE="default"
FIX_RUN_ID="36202314872"
PORT_LO=2300; PORT_HI=2399
FIX_CREATED="2026-09-26T08:46:00Z"
FIX_PUBKEY="ssh-ed25519 AAAAfixture36202314872 fh-proxy-asus-default-36202314872"

# ============================ 分類器 ======================================
# 分兩趟，因為「這個函式是產生別人消費的 output，還是它自己就是效果」要看
# 全檔才知道：
#   1. 每一個 pool-ssh 步驟若整個命令是 `${{ steps.X.outputs.Y }}`，就去 X 的
#      run: 追出「哪個函式產出 Y」→ 那才是這個 pool-ssh 步驟的效果。
#      （step 10 產兩個 output、step 11/12 各消費一個，不會被混為一談。）
#   2. shell 步驟的效果 = 它呼叫的 repo 函式，**扣掉**第一趟認領掉的那些
#      （那些只是「組命令」，真正執行的是 pool-ssh 那一步）。例如
#      create_worker_build_claim_cmd 在 step 6（組）與 step 7（跑）都出現，
#      效果只記在 step 7——記兩次會讓模擬以為埠被佔了兩次。
#
# 輸出 $2：index<TAB>is_failpath<TTAB>name<TAB>guard<TAB>effects
# 未建模的改動逐行印到 stdout（呼叫端自行判紅）。
cat > "$SANDBOX/classify.py" <<'PY'
import re, sys, yaml

WRITER = {
    "create_worker_build_claim_cmd":  "placeholder:claim",
    "create_worker_build_run_cmd":    "container:run",
    "create_worker_read_pubkey_cmd":  "",
    "create_worker_compute_identity": "identity:compute",
    "create_worker_ledger_add":       "ledger:add",
    "ledger_remove":                  "ledger:remove",
    "create_worker_dispatch_refresh_and_wait": "authkeys:refresh",
    "create_worker_verify_reachable": "",
}
WRITEISH = re.compile(r"_(add|remove|write|install|push|refresh|release|claim|create|"
                      r"set|put|apply|sync|update|delete|rm|drop|publish|emit)_")
OUT_REF = re.compile(r"^\$\{\{\s*steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)\s*\}\}$")
# 任何形式的 step output 參照（with: 與 run: 都要抓）
ANY_REF = re.compile(r"steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)")
ASSIGN_FN = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)=\"?\$\(\s*([a-z_][a-z0-9_]*)', re.M)
# 「整個 stdout 導去 GITHUB_OUTPUT」：容許**一行**續行反斜線。
#   create_worker_compute_identity "${{ ... }}" \
#     >> "$GITHUB_OUTPUT"
# 少了那個 (?:[^\n]*\\\n)? 的話這個正則跨不過換行，step 3（Compute worker
# identity）就會被判定成「不產生任何 output」，於是每個引用 steps.identity.
# outputs.container 的步驟（20/21）都被算成「引用拿不到 → 動作失敗」→
# 刪容器那一步被模型當成沒跑，容器殘留會在所有失敗點炸出來。
REDIRECT_FN = re.compile(r'([a-z_][a-z0-9_]*)(?:[^\n]*\\\n)?[^\n]*>>\s*"?\$GITHUB_OUTPUT')
OUT_KEY = re.compile(r'(?:echo|printf)\s+(?:-[a-zA-Z]+\s+)*["\']?([A-Za-z0-9_-]+)=')

CMD_TOKENS = [
    (re.compile(r"pool-port-alloc\s+--claim"),   "placeholder:claim"),
    (re.compile(r"pool-port-alloc\s+--release"), "placeholder:release"),
    (re.compile(r"\bdocker\s+run\b"),            "container:run"),
    (re.compile(r"\bdocker\s+rm\b"),             "container:rm"),
    (re.compile(r"\bdocker\s+build\b"),          "rebuildable:image"),
    (re.compile(r"workers\.d/.*?\.json"),         "placeholder:record"),
]
MUTATION_HINT = re.compile(r"(?:^|[;&|(]\s*)(?:rm\s+-[a-zA-Z]*f|mv\s|install\s|sed\s+-i|"
                           r"tee\s|truncate\b)")
REDIRECT_FILE = re.compile(r">\s*[\"']?(?!/dev/null)[^\s;&|]+")

# shell 內建與關鍵字：它們長得像函式呼叫，但不是我們的函式
BUILTINS = set("""set source echo printf exit if then else elif fi for while do done case esac
function return export local read shift trap eval exec command cd test true false time coproc
select until break continue declare typeset readonly unset wait jobs kill getopts hash unalias
mapfile readarray let""".split())

def called_functions(body):
    r"""命令位置的函式呼叫名稱。

    2026-09-26 踩到的坑：原本的正則是 `name\s+["$]`，也就是「後面一定要是引號
    或 $」。於是 `create_worker_dispatch_refresh_and_wait 300`（後面是數字）
    **完全沒被認出來**——那個步驟既沒有效果、也沒有被報成未建模，靜靜地從
    分類裡消失。連帶的後果是模擬器從來沒有把 worker 的 tunnel key 寫進
    sshproxy 的 authorized_keys，於是「authorized_keys 殘留」這種殘骸在模型裡
    不可能出現，3b 綠得很漂亮——**那是一個長得跟真綠一模樣的假綠**，而且正是
    這張工單在對付的那件事。

    所以改成：抓「命令位置」（行首／&&／||／;／|／( 之後）開頭的識別字，
    扣掉 shell 內建與關鍵字。認錯方向的後果是誤報 unknown（紅），不是假綠。
    """
    out = []
    for m in re.finditer(r'(?:^|[;&|(]|&&|\|\|)\s*([a-z_][a-z0-9_]*)\b', body or "", re.M):
        fn = m.group(1)
        if fn in BUILTINS:
            continue
        out.append(fn)
    return out

def writer_map(body):
    out = {}
    for m in ASSIGN_FN.finditer(body or ""):
        out.setdefault(m.group(1), []).append(m.group(2))
    for m in REDIRECT_FN.finditer(body or ""):
        out.setdefault("*", []).append(m.group(1))
    return out

def command_effects(cmd, unknown, where):
    eff = [e for rx, e in CMD_TOKENS if rx.search(cmd or "")]
    if not eff and (MUTATION_HINT.search(cmd or "") or REDIRECT_FILE.search(cmd or "")):
        unknown.append(f"{where}: 遠端命令有寫入動作但認不出寫到哪：{(cmd or '').strip()[:72]!r}")
    return eff

def producer_ref(steps, by_id, sid, oname):
    """steps.<sid>.outputs.<oname> → "<產生它的步驟索引>:<name>"。

    索引是**位置事實**：模擬器只需要知道「那一步跑過沒有」。用 output 名稱
    不行——`stdout` 同時由 claim / run / pubkey 三個 pool-ssh 步驟產生，只認
    名稱會把「還沒產生」誤判成「已經有值」，於是壞掉的補救又被算成回滾成功。
    解析不出來（沒有這樣的步驟、或不是 action 宣告的輸出）回 "?:<name>"，
    模擬器把它當成永遠拿不到的值（Actions 給空字串，動作會失敗）。
    """
    for i, s2 in enumerate(steps):
        if s2.get("id") != sid:
            continue
        if s2.get("uses"):
            return f"{i}:{oname}" if oname == "stdout" else f"?:{oname}"
        run = s2.get("run") or ""
        if oname in set(OUT_KEY.findall(run)):
            return f"{i}:{oname}"
        if REDIRECT_FN.search(run):
            return f"{i}:{oname}"          # 整個 stdout 導去 GITHUB_OUTPUT
        return f"?:{oname}"
    return f"?:{oname}"


def effects_for(i, s, by_id, claimed, resolved, unknown):
    uses, run = s.get("uses") or "", s.get("run") or ""
    cmd = ((s.get("with") or {}).get("command")) or ""
    if "push-state" in uses:
        return ["state_cache:push"]
    if "pool-ssh" in uses:
        if i in resolved:
            return resolved[i]
        return command_effects(cmd, unknown, f"[{i}] {s.get('name')}")
    if not run:
        return []
    eff = []
    for fn in called_functions(run):
        if fn in claimed:
            continue
        if fn in WRITER:
            if WRITER[fn]:
                eff.append(WRITER[fn])
        elif WRITEISH.search(fn):
            unknown.append(f"[{i}] {s.get('name')} 呼叫了會寫入的 {fn}()，"
                           f"但不在分類表裡——加進去，或確認它不寫池側狀態")
    if not eff and "gh variable set" in run:
        eff.append("ledger:add")
    if not eff:
        for k in sorted(set(OUT_KEY.findall(run))):
            eff.append(f"output:{k}")
    return eff

def main(wf, out_path, unknown_path):
    doc = yaml.safe_load(open(wf, encoding="utf-8"))
    jobs = doc.get("jobs") or {}
    if len(jobs) != 1:
        print(f"WORKFLOW 形狀變了：{len(jobs)} 個 job（預期 1），模型只懂單 job",
              file=sys.stderr)
        sys.exit(2)
    steps = list(jobs.values())[0].get("steps") or []
    by_id = {s["id"]: s for s in steps if isinstance(s, dict) and s.get("id")}
    unknown, claimed, resolved = [], set(), {}

    for i, s in enumerate(steps):
        if "pool-ssh" not in (s.get("uses") or ""):
            continue
        cmd = ((s.get("with") or {}).get("command")) or ""
        m = OUT_REF.match(cmd.strip())
        if not m:
            continue
        sid, oname = m.group(1), m.group(2)
        src = by_id.get(sid)
        if src is None:
            unknown.append(f"[{i}] 用 steps.{sid}.outputs.{oname}，但沒有 id 為 {sid} 的步驟")
            continue
        wmap = writer_map(src.get("run") or "")
        fns = wmap.get(oname) or wmap.get("*") or []
        if not fns:
            unknown.append(f"[{i}] 用 steps.{sid}.outputs.{oname}，"
                           f"但讀不出那個 key 是哪個函式產的")
            continue
        eff = []
        for fn in fns:
            claimed.add(fn)
            if fn in WRITER:
                if WRITER[fn]:
                    eff.append(WRITER[fn])
            elif WRITEISH.search(fn):
                unknown.append(f"[{i}] steps.{sid}.outputs.{oname} 由 {fn}() 產出，"
                               f"但不在分類表裡")
        resolved[i] = eff

    rows = []
    for i, s in enumerate(steps):
        cond = s.get("if") or ""
        failpath = ("failure()" in cond) or ("always()" in cond)
        eff = effects_for(i, s, by_id, claimed, resolved, unknown)
        # 這個步驟引用了哪些 steps.*.outputs.*（with: 與 run: 全部算）。模擬器
        # 用它判斷「這個動作會不會跑失敗」——見 simulate 裡 refs_unavailable。
        blob = yaml.safe_dump(s, default_flow_style=False, allow_unicode=True)
        refs = sorted({producer_ref(steps, by_id, a, b) for a, b in ANY_REF.findall(blob)})
        rows.append("\x1f".join([str(i), "1" if failpath else "0",
                                 str(s.get("name", "")), cond.replace("\x1f", " "),
                                 ",".join(dict.fromkeys(eff)), ",".join(refs)]))
    open(out_path, "w", encoding="utf-8").write("\n".join(rows) + "\n")
    open(unknown_path, "w", encoding="utf-8").write(
        "".join(u + "\n" for u in unknown))

main(sys.argv[1], sys.argv[2], sys.argv[3])
PY

classify() {   # classify <workflow> <tag>
    python3 "$SANDBOX/classify.py" "$1" "$SANDBOX/$2.tsv" "$SANDBOX/$2.unknown" \
        2>"$SANDBOX/$2.err"
}

# ============================ 假池子 ======================================
seed_pool() {
    local d="$1"
    STORE_COMPLAINED=""
    rm -rf "$d"; mkdir -p "$d/workers.d" "$d/containers"
    cat > "$d/workers.json" <<'J'
[{"port":2300,"provider":"fh-proxy","image":"default","container":"mlp-fh-proxy-default-35521634874","created_at":"2026-09-20T16:06:21Z","tunnel_public_key":"ssh-ed25519 AAAAfake2300 fh-proxy-default-35521634874"},
 {"port":2301,"provider":"fh-proxy-asus","image":"default","container":"mlp-fh-proxy-asus-default-36025218177","created_at":"2026-09-24T16:10:11Z","tunnel_public_key":"ssh-ed25519 AAAAfake2301 fh-proxy-asus-default-36025218177"},
 {"port":2302,"provider":"fh-l","image":"default","container":"mlp-fh-l-default-36197689685","created_at":"2026-09-25T22:39:00Z","tunnel_public_key":"ssh-ed25519 AAAAfake2302 fh-l-default-36197689685","capabilities":{}},
 {"port":2303,"provider":"fh-l","image":"default","container":"mlp-fh-l-default-35680730388","created_at":"2026-09-22T02:47:33Z","tunnel_public_key":"ssh-ed25519 AAAAfake2303 fh-l-default-35680730388"}]
J
    printf '%s\n' 2300 2301 2302 2303 > "$d/listeners"
    local p
    for p in 2300 2301 2302 2303; do
        jq --argjson p "$p" '.[] | select(.port == $p)' "$d/workers.json" > "$d/workers.d/$p.json"
    done
    printf 'mlp-fh-proxy-default-35521634874\n' > "$d/containers/fh-proxy"
    printf 'mlp-fh-proxy-asus-default-36025218177\n' > "$d/containers/fh-proxy-asus"
    printf 'mlp-fh-l-default-36197689685\nmlp-fh-l-default-35680730388\n' > "$d/containers/fh-l"
    cat > "$d/vars.json" <<'V'
[{"name":"CLIENT_ACTIONS","value":"{\"name\":\"actions\",\"public_key\":\"ssh-ed25519 AAAAactions\"}"},
 {"name":"NODE_FH_PROXY","value":"{\"name\":\"fh-proxy\",\"role\":\"provider\",\"tunnel_public_key\":\"ssh-ed25519 AAAAfakeproxy\"}"},
 {"name":"NODE_FH_PROXY_ASUS","value":"{\"name\":\"fh-proxy-asus\",\"role\":\"provider\",\"tunnel_public_key\":\"ssh-ed25519 AAAAfakeasus\"}"},
 {"name":"NODE_FH_L","value":"{\"name\":\"fh-l\",\"role\":\"provider\",\"tunnel_public_key\":\"ssh-ed25519 AAAAfakel\"}"}]
V
    # state.json 與 sshproxy 的 authorized_keys 都用 repo 自己的函式生，
    # 確保量到的是實作而不是這支測試的模型。
    # 傳**內容**，不是路徑。state_build / refresh_collect_tunnel_keys 收的是
    # JSON 本文；傳路徑進去，它們會安靜地各自失敗（jq 報 invalid JSON /
    # "neither an object with .variables nor an array"），留下 0 _byte 的
    # state.json 與 authkeys——而那兩份 0 位元組檔案正好讓「查不到」被讀成
    # 「是空的」，於是整個守衛回報綠。**這就是這個測試自己版本的 §1.7。**
    # write_store 會驗收結果：寫出來不是合法狀態就直接報錯，不准靜靜留空。
    write_store state-cache "$d/state.json" "$( cd "$REPO" && bash -c 'source scripts/lib/state.sh
        state_build 9 "create-worker#36197689685" "$1" "$2"' \
        _ "$(cat "$d/vars.json")" "$(cat "$d/workers.json")" 2>&1 )"
    write_store authorized-keys "$d/authkeys" "$( cd "$REPO" && bash -c 'source scripts/refresh-authkeys.sh 2>/dev/null
        source scripts/rotate-gateway.sh 2>/dev/null
        rotate_assemble_sshproxy_keys "$(refresh_collect_tunnel_keys "$1" "$2")"' \
        _ "$(cat "$d/vars.json")" "$(cat "$d/workers.json")" 2>&1 )"
}

# write_store <檔案> <內容> <標籤>
#   內容必須是「一份可讀的狀態」。空檔案或錯誤訊息落地 = 模擬壞掉，必須報出來。
#   這一條是這個守衛最重要的防假綠閘門：沒有它，任何 harness 的退化（函式改名、
#   參數抽錯、jq 壞掉）都會表現成「池子乾淨」。
STORE_ERRORS=""
STORE_COMPLAINED=""
HARNESS_NOTE=""
violations=""      # §2 填；探針段落會用 violation_kinds <blob> 的形式呼叫
write_store() {   # write_store <label> <file> <body>
    local label="$1" f="$2" body="$3"
    if [[ -z "${body//[[:space:]]/}" ]]; then
        STORE_ERRORS="${STORE_ERRORS}${label}:empty "
        complain_once "$label" "寫出來是空的（repo 函式沒跑成功）"
        : > "$f"
        return 1
    fi
    printf '%s\n' "$body" > "$f"
    if ! store_readable "$(dirname "$f")" "$label"; then
        STORE_ERRORS="${STORE_ERRORS}${label}:invalid "
        complain_once "$label" "寫出來不是合法狀態：$(printf '%s' "$body" | head -1 | cut -c1-90)"
        return 1
    fi
    return 0
}

# 同一個 store 壞掉時只講一次。20 個失敗點 × 5 次注入 = 100 行同一句話會把
# 真正的紅淹掉——那正是「守衛壞掉時要看得見」要對抗的相反面。
complain_once() {
    case "$STORE_COMPLAINED" in
        *" $1 "*) return 0 ;;
    esac
    STORE_COMPLAINED="${STORE_COMPLAINED} $1 "
    printf '!!! harness 壞掉：%s %s\n' "$1" "$2" >&2
}

# store_readable <pool> <store>：這一份狀態是不是「讀得到而且合法」
store_readable() {
    local d="$1" s="$2"
    case "$s" in
        ledger)         jq -e 'type == "array"' "$d/workers.json" >/dev/null 2>&1 ;;
        state-cache)    jq -e 'type == "object" and .schema == 1 and has("workers")' \
                            "$d/state.json" >/dev/null 2>&1 ;;
        authorized-keys) [[ -s "$d/authkeys" ]] && grep -q '^ssh-' "$d/authkeys" 2>/dev/null ;;
        *)              return 1 ;;
    esac
}

# 池側是否還「宣告」這個 worker：任何一份資料還提到它的埠或容器名。
survivors() {
    local d="$1" p="$2" c="$3" out="" f alt st
    # **先問每一份狀態讀不讀得到。** 讀不到的不是「乾淨」，是「不知道」——
    # 兩者共用一個空字串正是這個 repo 修過六次的形狀（TESTPLAN §1.7），而
    # 上一版的這個函式正好那樣錯過：repo 函式失敗留下 0 位元組 state.json，
    # jq 對空檔案回 1，於是「快取裡沒有那個 worker」被報成綠。
    for st in ledger state-cache authorized-keys; do
        if ! store_readable "$d" "$st"; then
            out="${out}unknown:${st} "
            printf '%s 讀不到（不是「裡面沒有」，是「沒讀到」）\n' "$st" > "$d/why.unknown-$st"
        fi
    done
    for f in "$d"/containers/*; do
        [[ -f "$f" && -n "$c" ]] || continue
        if grep -qxF "$c" "$f" 2>/dev/null; then
            out="${out}container "
            printf '容器 %s 還在 %s 上\n' "$c" "$(basename "$f")" > "$d/why.container"
            break
        fi
    done
    if [[ -n "$p" && -f "$d/workers.d/$p.json" ]]; then
        out="${out}placeholder "
        printf 'workers.d/%s.json 還在（沒有別的視角提到它）\n' "$p" > "$d/why.placeholder"
    fi
    if [[ -n "$p" ]] && jq -e --argjson p "$p" --arg c "$c" \
        'any(.[]; .port == $p or .container == $c)' "$d/workers.json" >/dev/null 2>&1; then
        out="${out}ledger "
        printf 'POOL_WORKERS 還有 port=%s 或 container=%s\n' "$p" "$c" > "$d/why.ledger"
    fi
    if [[ -f "$d/state.json" && -n "$p" ]] && jq -e --argjson p "$p" --arg c "$c" \
        'any(.workers[]?; .port == $p or .container == $c)' "$d/state.json" >/dev/null 2>&1; then
        out="${out}state-cache "
        printf 'state.json 還宣告 port=%s / container=%s\n' "$p" "$c" > "$d/why.state-cache"
    fi
    # 沒有 worker 身分（失敗發生在 identity 之後以前）就沒有東西可查。
    # `grep -qF ""` 會匹配每一行——那會讓「查不到要查什麼」變成「四邊都有殘留」。
    #
    # **兩種拼法都要找。** worker 的 tunnel key 在 authorized_keys 裡的 comment
    # 是**去掉 mlp- 前綴**的那個名字（真實叢集上實測：
    # `fh-proxy-asus-default-36202314872`，沒有 mlp-）。只拿容器名去 grep 永遠
    # 不會中——於是這個視角在結構上就抓不到它存在的理由要抓的那種殘骸，而輸出
    # 看起來是乾淨的。scripts/lib/ledger.sh 的 ledger_find 註解裡早就記了這兩種
    # 拼法都在流通中。
    if [[ -n "$c" && -f "$d/authkeys" ]]; then
        local alt="${c#mlp-}"
        if grep -qF "$c" "$d/authkeys" 2>/dev/null \
           || { [[ "$alt" != "$c" ]] && grep -qF "$alt" "$d/authkeys" 2>/dev/null; }; then
            out="${out}authorized-keys "
            printf 'sshproxy 的 authorized_keys 還認得 %s 的 key\n' "$alt" > "$d/why.authorized-keys"
        fi
    fi
    printf '%s' "$out"
}

# ============================ 模擬器 ======================================
# 追蹤中的 step outputs。空 = 產生它的那步還沒跑（GitHub 給空字串）。
ID_NAME=""; ID_TAG=""; ID_CONT=""; ID_PORT=""; ID_PUBKEY=""; CLAIMED=""

trace() { [[ "$DEBUG" == "1" ]] && printf 'TRACE %s\n' "$*" >&2; return 0; }

apply_effect() {   # apply_effect <pool> <effect>
    trace "apply_effect d=$1 e=$2"
    local d="$1" e="$2" o p tmp
    case "$e" in
        identity:compute)
            o="$(cd "$REPO" && FIXP="$FIX_PROVIDER" FIXI="$FIX_IMAGE" FIXR="$FIX_RUN_ID" \
                 bash -c 'source scripts/create-worker.sh
                          create_worker_compute_identity "$FIXP" "$FIXI" "$FIXR" ""' 2>/dev/null)"
            ID_NAME="$(printf '%s' "$o" | sed -n 's/^name=//p')"
            ID_TAG="$(printf '%s' "$o" | sed -n 's/^image_tag=//p')"
            ID_CONT="$(printf '%s' "$o" | sed -n 's/^container=//p')"
            ;;
        placeholder:claim)
            p="$PORT_LO"
            while [[ "$p" -le "$PORT_HI" ]]; do
                if ! grep -qxF "$p" "$d/listeners" 2>/dev/null \
                   && [[ ! -f "$d/workers.d/$p.json" ]]; then break; fi
                p=$((p + 1))
            done
            CLAIMED="$p"
            jq -n --arg provider "$FIX_PROVIDER" --arg image "$FIX_IMAGE" \
                --argjson port "$p" --arg created_at "$FIX_CREATED" \
                '{provider:$provider,image:$image,port:$port,created_at:$created_at,container:null}' \
                > "$d/workers.d/$p.json"
            ;;
        output:port)
            # 解析出來的埠只可能來自一次真的 claim；沒有 claim 就是空字串
            # （GitHub 對「引用一個還沒產生的 output」就是給空字串）
            [[ -n "$CLAIMED" ]] && ID_PORT="$CLAIMED"
            ;;
        output:public_key)
            ID_PUBKEY="$FIX_PUBKEY"
            ;;
        container:run)
            [[ -n "$ID_CONT" ]] && printf '%s\n' "$ID_CONT" >> "$d/containers/$FIX_PROVIDER"
            [[ -n "$CLAIMED" ]] && printf '%s\n' "$CLAIMED" >> "$d/listeners"
            ;;
        container:rm)
            tmp="$d/containers/.t"
            if [[ -f "$d/containers/$FIX_PROVIDER" ]]; then
                grep -vxF "$ID_CONT" "$d/containers/$FIX_PROVIDER" > "$tmp" 2>/dev/null || : > "$tmp"
                mv "$tmp" "$d/containers/$FIX_PROVIDER"
            fi
            ;;
        placeholder:record)
            [[ -n "$ID_PORT" && -f "$d/workers.d/$ID_PORT.json" ]] || return 0
            tmp="$d/workers.d/.t"
            if jq --arg c "$ID_CONT" '.container = $c' "$d/workers.d/$ID_PORT.json" > "$tmp" 2>/dev/null
            then mv "$tmp" "$d/workers.d/$ID_PORT.json"; else rm -f "$tmp"; fi
            ;;
        placeholder:release)
            [[ -n "$ID_PORT" ]] && rm -f "$d/workers.d/$ID_PORT.json"
            return 0
            ;;
        ledger:add)
            ( cd "$REPO" && bash -c 'source scripts/create-worker.sh
                create_worker_ledger_add "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"' \
                _ "$(cat "$d/workers.json")" "$ID_PORT" "$FIX_PROVIDER" "$FIX_IMAGE" \
                   "$ID_CONT" "$FIX_CREATED" "$ID_PUBKEY" \
                   "profiles/worker/$FIX_IMAGE/profile.json" ) > "$d/.w" 2>/dev/null \
                && mv "$d/.w" "$d/workers.json" || rm -f "$d/.w"
            ;;
        ledger:remove)
            ( cd "$REPO" && bash -c 'source scripts/lib/ledger.sh
                ledger_remove "$1" "$2"' _ "$(cat "$d/workers.json")" "$ID_PORT" ) \
                > "$d/.w" 2>/dev/null && mv "$d/.w" "$d/workers.json" || rm -f "$d/.w"
            ;;
        state_cache:push)
            local serial
            serial="$(cd "$REPO" && bash -c 'source scripts/lib/state.sh
                state_next_serial "$(cat "$1")"' _ "$d/state.json" 2>/dev/null)"
            write_store state-cache "$d/state.json" "$( cd "$REPO" && bash -c 'source scripts/lib/state.sh
                state_build "$1" "$2" "$3" "$4"' _ "${serial:-1}" \
                "create-worker#$FIX_RUN_ID" "$(cat "$d/vars.json")" "$(cat "$d/workers.json")" 2>&1 )"
            ;;
        authkeys:refresh)
            write_store authorized-keys "$d/authkeys" "$( cd "$REPO" && bash -c 'source scripts/refresh-authkeys.sh 2>/dev/null
                source scripts/rotate-gateway.sh 2>/dev/null
                rotate_assemble_sshproxy_keys "$(refresh_collect_tunnel_keys "$1" "$2")"' \
                _ "$(cat "$d/vars.json")" "$(cat "$d/workers.json")" 2>&1 )"
            ;;
    esac
    return 0
}

# guard_ok <guard>：這個 failure() 步驟現在會不會真的跑。
# 值從 stdin 收 "NAME=value" 行（不用關聯陣列，bash 3.2）。
#
# **必須看運算子，不能只看成有沒有引用。** 2026-09-26 那一版只檢查「被引用的
# output 有沒有值」，於是 `steps.port.outputs.port == 'never'` 這種永遠不成立
# 的守衛也被當成成立——「加了 push-state 但它是壞的」這個補救就這樣讓守衛轉綠
# （就是注入 4d）。只看「有沒有引用」等於只看「step 存不存在」，而那種斷言正
# 是工單明講會誤綠的。
#
# 認得的形狀只有兩種：
#   steps.X.outputs.Y != ''      → Y 必須非空
#   steps.X.outputs.Y == 'lit'   → Y 必須剛好等於 lit
# 其他形狀（多條件、!= 加字串、contains()…）→ 回 2，呼叫端必須報成 harness
# limitation，不准猜。猜錯的方向一律是綠，所以這裡保守。
GUARD_UNKNOWN=0
guard_ok() {
    local guard="$1" line name val op lit ref rest tail
    GUARD_UNKNOWN=0
    local -a have=()
    while IFS= read -r line; do
        [[ "$line" == *=* ]] || continue
        have+=("${line%%=*}=${line#*=}")
    done
    val_of() {
        local n="$1" e
        for e in ${have[@]+"${have[@]}"}; do
            [[ "$e" == "${n}="* ]] && { printf '%s' "${e#*=}"; return 0; }
        done
        printf ''
    }
    # bash 3.2 的 =~ 遇到未加引號、含括號的樣式會語法錯誤，所以樣式一律放進
    # 變數再比對（同一個坑在 guard_ok 的第一版就踩過）。
    local RE_REF='steps\.[A-Za-z0-9_-]+\.outputs\.[A-Za-z0-9_-]+'
    local RE_SQ="^[[:space:]]*'([^']*)'"
    local RE_DQ='^[[:space:]]*"([^"]*)"'
    local RE_OP="^[[:space:]]*([^[:space:]'\"]+)[[:space:]]"
    rest="$guard"
    while [[ "$rest" =~ $RE_REF ]]; do
        ref="${BASH_REMATCH[0]}"
        name="${ref##*.}"
        tail="${rest#*"$ref"}"
        if [[ "$tail" =~ $RE_SQ ]]; then
            lit="${BASH_REMATCH[1]}"; op="=="
        elif [[ "$tail" =~ $RE_DQ ]]; then
            lit="${BASH_REMATCH[1]}"; op="=="
        elif [[ "$tail" =~ $RE_OP ]]; then
            op="${BASH_REMATCH[1]}"
            lit="${tail#*"$op"}"
            lit="${lit#"${lit%%[![:space:]]*}"}"
            lit="${lit%\'}"; lit="${lit#\'}"; lit="${lit%\"}"; lit="${lit#\"}"
        else
            GUARD_UNKNOWN=1
            return 2
        fi
        case "$op" in
            "!=")
                [[ -n "$(val_of "$name")" ]] || return 1
                ;;
            "==")
                [[ "$(val_of "$name")" == "$lit" ]] || return 1
                ;;
            *)
                GUARD_UNKNOWN=1
                return 2
                ;;
        esac
        rest="${rest/"$ref"/}"
    done
    return 0
}

# violations 的每一行是「失敗點索引 ;; 殘留種類（空白分隔）」。三個解析器都
# 只認這個形狀。**用 bash 的參數展開做，不用 cut**——BSD cut 的 -d 只吃一個
# 字元（`cut -d' ;; '` 會直接報 bad delimiter），而 awk 要另外開一個行程。
kinds_of_blob() {   # kinds_of_blob <blob>：這個 blob 裡出現過哪些種類（去重排序）
    local line k out=""
    while IFS= read -r line; do
        [[ "$line" == *" ;; "* ]] || continue
        for k in ${line#* ;; }; do
            case " $out " in *" $k "*) continue ;; esac
            out="${out}${k} "
        done
    done <<< "$1"
    printf '%s' "$out"
}
violation_kinds() { kinds_of_blob "${1:-$violations}"; }
violation_kinds() { kinds_of_blob "${1:-$violations}"; }
violation_points_of() { points_of "$violations" "$1"; }
# points_of <blob> <kind>：這個 blob 裡，哪些失敗點留下這種殘留
# all_points <blob>：哪些失敗點留下任何殘留
#   兩個都不用 cut：BSD cut 的 -d 只吃一個字元（`-d' ;; '` 會 bad delimiter）。
points_of() {
    local line
    while IFS= read -r line; do
        [[ "$line" == *" ;; "* ]] || continue
        case "$line" in *"$2"*) printf '%s ' "${line%% ;; *}" ;; esac
    done <<< "$1"
}
all_points() {
    local line
    while IFS= read -r line; do
        [[ "$line" == *" ;; "* ]] || continue
        printf '%s ' "${line%% ;; *}"
    done <<< "$1"
}

# refs_unavailable <refs> <fail-index>
#   這個步驟引用的 output 裡，有「產生它的那一步在失敗點之後、所以還沒跑」的嗎？
#   判斷是純位置性的：失敗點 F 之後的步驟都沒跑，所以它們產生的 output 是空的。
#   `?:` = 解析不出產生者（沒有這樣的步驟）→ 永遠拿不到 → 一樣算 unavailable。
#
#   這一條是「動作有跑，但跑失敗了」那個第三種狀態（探針 4e）。只看守衛會把它
#   算成「守衛成立 → 回滾成功」，於是一個依賴還沒被產出的 output 的補救會被
#   算成有效的回滾——而真實 Actions 給空字串，那一步會失敗，狀態沒被回滾。
STEP_FAILED=""
refs_unavailable() {
    local refs="$1" F="$2" r idx
    for r in ${refs//,/ }; do
        [[ -n "$r" ]] || continue
        idx="${r%%:*}"
        if [[ "$idx" == "?" ]]; then return 0; fi
        if [[ "$idx" -ge "$F" ]]; then return 0; fi
    done
    return 1
}

# simulate <tag> <fail-index> <pool>：印出殘留的宣告種類（空白分隔）
simulate() {
    local tag="$1" F="$2" d="$3" idx isf name guard effects e grc
    STORE_ERRORS=""
    HARNESS_NOTE=""
    STEP_FAILED=""
    seed_pool "$d"
    ID_NAME=""; ID_TAG=""; ID_CONT=""; ID_PORT=""; ID_PUBKEY=""; CLAIMED=""
    while IFS=$'\x1f' read -r idx isf name guard effects refs; do
        # 成功路徑：跑到失敗點之前
        if [[ "$isf" == "0" && "$idx" -lt "$F" ]]; then
            if refs_unavailable "$refs" "$F"; then
                # 同理：這一步在真實 Actions 上會失敗，所以它沒寫成。模型把它
                # 當成「無效的步驟」而不是「更早的失敗點」——見檔頭的極限清單。
                STEP_FAILED="$STEP_FAILED $idx"
                continue
            fi
            while IFS= read -r e; do
                [[ -n "$e" ]] && apply_effect "$d" "$e"
            done < <(printf '%s\n' "${effects//,/$'\n'}")
        fi
    done < "$SANDBOX/$tag.tsv"
    # 失敗路徑：依序跑，守衛成立才跑（守衛是這個測試要真的評估的東西）
    while IFS=$'\x1f' read -r idx isf name guard effects refs; do
        [[ "$isf" == "1" ]] || continue
        local grc=0
        guard_ok "$guard" <<EOF
name=$ID_NAME
image_tag=$ID_TAG
container=$ID_CONT
port=$ID_PORT
public_key=$ID_PUBKEY
EOF
        grc=$?
        if [[ $grc -eq 2 ]]; then
            # 守衛看不懂 → 不准猜成「會跑」也不准猜成「不會跑」。記下來，
            # 讓整個結果被標成 harness limitation（猜錯的方向都是綠）。
            HARNESS_NOTE="看不懂的 if: 條件（${guard}）"
        elif [[ $grc -eq 0 ]]; then
            # 守衛成立 ≠ 動作會成功。`with:` 引用一個「產生它的那一步在失敗點
            # 之後、所以還沒被產出」的 output 時，Actions 給空字串，動作會失敗
            # ——而「失敗」的後果是**狀態沒被回滾**，不是「什麼都沒發生」，也不是
            # 「回滾成功」。只看守衛就會把這種補救算成有效的回滾（探針 4e）。
            if refs_unavailable "$refs" "$F"; then
                STEP_FAILED="$STEP_FAILED $idx"
            else
                while IFS= read -r e; do
                    [[ -n "$e" ]] && apply_effect "$d" "$e"
                done < <(printf '%s\n' "${effects//,/$'\n'}")
            fi
        fi
    done < "$SANDBOX/$tag.tsv"
    local out
    HARNESS_NOTE=""
    out="$(survivors "$d" "$ID_PORT" "$ID_CONT")"
    if [[ -n "$HARNESS_NOTE" ]]; then
        out="${out}!harness:unknown-guard "
    fi
    # harness 自己壞掉時必須看得出來，而且不能被讀成「這個失敗點乾淨」
    if [[ -n "$STORE_ERRORS" ]]; then
        out="${out}!harness:${STORE_ERRORS}"
    fi
    printf '%s' "$out"
}

# 逐一失敗點跑一遍，印出「索引<TAB>殘留種類」
violations_for() {   # violations_for <workflow> <tag>
    local wf="$1" tag="$2" idx out rc
    classify "$wf" "$tag" || return 1
    [[ -s "$SANDBOX/$tag.unknown" ]] && return 2
    for idx in $(cut -d$'\x1f' -f1 "$SANDBOX/$tag.tsv"); do
        # 失敗點只放在成功路徑上（清理步驟自己失敗是另一個判準）
        [[ "$(awk -F'\037' -v i="$idx" '$1==i{print $2}' "$SANDBOX/$tag.tsv")" == "1" ]] && continue
        out="$(simulate "$tag" "$idx" "$SANDBOX/pool-$tag-$idx")"
        [[ -n "$out" ]] && printf '%s ;; %s\n' "$idx" "$out"
    done
    return 0
}

# ---------- 失敗路徑的分類結果（診斷用，機械事實）------------------------
# 印出「每個 failure() 步驟被分類成撤銷了什麼」，以及「有沒有任何步驟撤銷
# state-cache」。2026-09-26 那一版的假綠就是靠這張表才看得出來：分類器本身
# 早就知道沒有任何步驟撤銷快取，但當時的輸出沒有把它印出來。
report_failure_path() {
    local idx isf name guard effects refs any_cache="沒有（所以沒人收）"
    printf '        %-50s %-24s %s\n' "失敗路徑步驟" "撤銷了什麼" "引用的 output"
    while IFS=$'\x1f' read -r idx isf name guard effects refs; do
        [[ "$isf" == "1" ]] || continue
        printf '        [%-2s] %-48s %-24s %s\n' "$idx" "${name:0:48}" \
            "${effects:-（沒有）}" "${refs:-}"
        [[ ",$effects," == *,state_cache:* ]] && any_cache="有"
    done < "$SANDBOX/$1.tsv"
    printf '        → 有任何失敗步驟撤銷 state-cache 嗎：%s\n' "$any_cache"
}

# ---- 探針：改 workflow 副本，全部在 $SANDBOX 裡 ---------------------------
#
# 探針的設計原則（2026-09-26 這一版改掉的就是這條）：**探針要「改壞基底自己的
# 補救」，不是「在基底旁邊再加一個」。**
#
# 上一版的 4d／4e 是把一個壞補救**附加**到 workflow 尾部。那在基底沒有補救時
# 有效（原本的洞還在，附加的壞補救不影響結論），但一旦基底自己就有正確補救
# （impl 補上之後），附加上去的壞補救就是多餘的——基底那個仍然把快取清乾淨，
# 於是「壞補救」被證明無害，探針回綠。那個綠的正確解讀是「這個探針在基底已
# 修好之後不再有意義」，但它被印成「這個測試在釘 step 存在」；兩件事被同一
# 個符號講出來，而 **3a 的綠也就跟著看起來像證據**——守衛對正確補救、壞補救、
# 順序錯補救三者同樣給綠時，那個綠只代表「有個 step 在」。
#
# 所以現在每個探針都先 `correct`（基底沒有補救就補一個正確的），再**就地**把
# 它改壞：`dead-if` 改寫它自己的 `if:`、`wrong-order` 把它整塊搬到刪帳本之前。
# 這樣不論基底有沒有補救，探針的問題都成立。
PROBE="$SANDBOX/probe.py"
cat > "$PROBE" <<'PROBE_PY'
import re, sys, yaml

CACHE_STEP = """      - name: On failure, re-push the state cache
        if: failure() && steps.port.outputs.port != ''
        uses: ./.github/actions/push-state
        with:
          gateway-ip: ${{ steps.gateway.outputs.ip }}
          gateway-port: ${{ steps.gateway.outputs.ssh_port }}
          host-key: ${{ steps.gateway.outputs.host_key }}
          source: create-worker#${{ github.run_id }}
          ssh-key: ${{ secrets.SSH_KEY_ACTIONS }}
"""
AUTHKEYS_STEP = """      - name: On failure, refresh the Gateway authorized keys
        if: failure() && steps.port.outputs.port != ''
        shell: bash
        run: |
          set -uo pipefail
          source scripts/create-worker.sh
          create_worker_dispatch_refresh_and_wait 300 || true
"""
# 引用一個「在某些失敗點上還沒被產出」的 output：collect pubkey 那一步若沒跑到，
# 它的 stdout 就是空字串，push-state 拿到空 gateway-ip 會失敗——而「失敗」在
# 真實 GitHub 上不會讓快取被清乾淨。
MARKER_STEP = """      - name: Record a marker for the new worker
        id: marker
        shell: bash
        run: |
          echo "note=${{ steps.identity.outputs.container }}" >> "$GITHUB_OUTPUT"
"""
BADREFS_STEP = """      - name: On failure, re-push the state cache
        if: failure() && steps.port.outputs.port != ''
        uses: ./.github/actions/push-state
        with:
          gateway-ip: ${{ steps.marker.outputs.note }}
          gateway-port: ${{ steps.gateway.outputs.ssh_port }}
          host-key: ${{ steps.gateway.outputs.host_key }}
          source: create-worker#${{ github.run_id }}
          ssh-key: ${{ secrets.SSH_KEY_ACTIONS }}
"""
SIXTH_STEP = """      - name: Stash a note about this worker
        uses: ./.github/actions/pool-ssh
        with:
          node: gateway
          command: mkdir -p ~/.mylinuxpool/leftovers && echo "${{ steps.port.outputs.port }}" > ~/.mylinuxpool/leftovers/note.txt
"""
LEDGER = "remove the entry from POOL_WORKERS"

def split_steps(lines):
    idxs = [i for i, l in enumerate(lines) if l.startswith("      - name:")]
    if not idxs:
        raise SystemExit("probe: 找不到步驟（workflow 形狀變了？）")
    head = lines[:idxs[0]]
    blocks = []
    for n, i in enumerate(idxs):
        end = idxs[n + 1] if n + 1 < len(idxs) else len(lines)
        blocks.append("\n".join(lines[i:end]))
    return head, blocks

def find_remedy(blocks):
    """失敗路徑上的「重推快取」補救。"""
    for n, b in enumerate(blocks):
        if "actions/push-state" in b and "if: failure()" in b:
            return n
    return None

def find_authkeys_remedy(blocks):
    """失敗路徑上的「重跑 refresh」補救。

    要看的是失敗路徑上有沒有，不是整個檔案裡有沒有——成功路徑本來就有一個
    refresh（step 15），用「整個檔案裡出現過」來判會以為補救已經存在。
    """
    for n, b in enumerate(blocks):
        if "create_worker_dispatch_refresh_and_wait" in b and "if: failure()" in b:
            return n
    return None

def main(src, dst, mode):
    lines = open(src, encoding="utf-8").read().split("\n")
    head, blocks = split_steps(lines)

    def write(bs):
        open(dst, "w", encoding="utf-8").write("\n".join(head + bs))
        yaml.safe_load(open(dst, encoding="utf-8"))      # 必須仍是合法 YAML

    if mode == "asis":
        write(blocks); return
    if mode in ("half-cache", "half-authkeys"):
        # **單步完成「兩種都拿掉、只補一種」。** 2026-09-26 之前這件事是用兩個
        # 探針串起來的（no-remedy 然後 correct），而 probe 每次都從**基底**重新
        # 出發，所以第二步把基底自己那份 authkeys 補救又帶回來了——於是「只補
        # 一半」從來沒有真的發生過。**串接的探針等於沒有探針**：第二步看不見
        # 第一步的結果。半套這種狀態必須在一個轉換裡做出來。
        drop_cache = (mode == "half-authkeys")
        out = []
        for i, b in enumerate(blocks):
            is_cache = (find_remedy([b]) is not None)
            is_ak = (find_authkeys_remedy([b]) is not None)
            if is_cache and drop_cache:
                continue
            if is_ak and not drop_cache:
                continue
            out.append(b)
        blocks = out
        if not drop_cache and find_remedy(blocks) is None:
            blocks = blocks + [CACHE_STEP.rstrip("\n")]
        if drop_cache and find_authkeys_remedy(blocks) is None:
            blocks = blocks + [AUTHKEYS_STEP.rstrip("\n")]
        write(blocks); return
    if mode.startswith("no-"):
        # no-remedy / no-cache / no-authkeys：**每一種補救各自可獨立移除**。
        # 2026-09-26 之前只有 no-remedy，而它只移除快取那一種——所以「只補一半」
        # 這個探針其實從來沒有構造出「只補一半」的狀態：基底自己的 authkeys 補救
        # 還在裡面。探針問的問題與它實際構造的狀態不是同一個，於是它綠，而那個綠
        # 被讀成「守衛接受只補一半」。**探針沒構造出它聲稱的狀態，比探針紅更
        # 危險**：它會讓人以為那一條被驗過了。
        drop = set()
        if mode in ("no-remedy", "no-cache"):
            n = find_remedy(blocks)
            if n is not None:
                drop.add(n)
        if mode in ("no-remedy", "no-authkeys"):
            n = find_authkeys_remedy(blocks)
            if n is not None:
                drop.add(n)
        write([b for i, b in enumerate(blocks) if i not in drop]); return
    if mode in ("correct", "correct+authkeys"):
        if find_remedy(blocks) is None:
            blocks = blocks + [CACHE_STEP.rstrip("\n")]
        # **要看的是失敗路徑上有沒有，不是整個檔案裡有沒有。** 成功路徑本來就有
        # 一個 refresh（step 15），用「整個檔案裡出現過」來判會以為補救已經
        # 存在、於是從來不追加——4b 就這樣紅著，而紅的原因與它要驗的無關。
        if mode == "correct+authkeys" and find_authkeys_remedy(blocks) is None:
            blocks = blocks + [AUTHKEYS_STEP.rstrip("\n")]
        write(blocks); return
    if mode == "sixth":
        i = next((n for n, b in enumerate(blocks) if LEDGER in b), len(blocks) - 1)
        blocks = blocks[:i] + [SIXTH_STEP.rstrip("\n")] + blocks[i:]
        write(blocks); return
    if mode == "reorder-push":
        n = next((i for i, b in enumerate(blocks)
                  if "actions/push-state" in b and "if: failure()" not in b), None)
        if n is None:
            raise SystemExit("probe: 找不到成功路徑的 push-state")
        blocks = blocks + [blocks.pop(n).rstrip("\n")]
        write(blocks); return

    # --- 以下都要「先有補救，才能把它改壞」---
    r = find_remedy(blocks)
    if r is None:
        blocks = blocks + [CACHE_STEP.rstrip("\n")]
        r = len(blocks) - 1
    if mode == "dead-if":
        blocks[r] = re.sub(r"^(\s*if: failure\(\)).*$",
                            r"\1 && steps.port.outputs.port == 'never'",
                            blocks[r], count=1, flags=re.M)
        write(blocks); return
    if mode == "bad-refs":
        # 這個探針要造出第三種狀態：「動作有跑，但跑失敗了」。三件事一起做，
        # 缺一件就造不出來：
        #   (a) 在「Record the worker in POOL_WORKERS」之後立刻推快取——之後帳本
        #       已經有那筆 worker，所以這時推上去的快取**是髒的**；
        #   (b) 加一個產生 output 的步驟（marker）放在推快取**之後**；
        #   (c) 補救引用 steps.marker.outputs.note。
        # 於是打在 (b) 的失敗點上：快取已髒、補救要的 output 還沒被產出（Actions
        # 給空字串）→ 補救失敗 → 殘留。
        #
        # 為什麼需要這麼麻煩：現有順序把快取寫在成功路徑倒數第二步，於是任何
        # 「補救有意義」的失敗點都已經跑過全部步驟，那個狀態根本provoke不到。
        # 這個形狀只用 /tmp 複本，而且是唯一能把它逼出來的方式。
        n = next((i for i, b in enumerate(blocks)
                  if "actions/push-state" in b and "if: failure()" not in b), None)
        if n is None:
            raise SystemExit("probe: 找不到成功路徑的 push-state")
        blk = blocks.pop(n)
        j = next((i for i, b in enumerate(blocks) if "Record the worker in POOL_WORKERS" in b), None)
        if j is None:
            raise SystemExit("probe: 找不到 Record the worker in POOL_WORKERS")
        blocks = (blocks[:j + 1] + [blk.rstrip("\n"), MARKER_STEP.rstrip("\n")]
                  + blocks[j + 1:])
        r2 = find_remedy(blocks)
        blocks[r2 if r2 is not None else len(blocks) - 1] = BADREFS_STEP.rstrip("\n")
        write(blocks); return
    if mode == "wrong-order":
        blk = blocks.pop(r)
        i = next((n for n, b in enumerate(blocks) if LEDGER in b), None)
        if i is None:
            raise SystemExit("probe: 找不到刪帳本那一步")
        blocks = blocks[:i] + [blk] + blocks[i:]
        write(blocks); return
    raise SystemExit("probe: 不认识的 mode " + mode)

main(sys.argv[1], sys.argv[2], sys.argv[3])
PROBE_PY

probe() {   # probe <mode> <tag>
    python3 "$PROBE" "$REPO_ROOT/$WF" "$SANDBOX/wf/$2.yml" "$1" 2>"$SANDBOX/probe-$2.err"
}

echo "=== 0. 先決條件 ==="
[[ -f "$REPO_ROOT/$WF" ]] && ok "0a. ${WF} 存在" || bad "0a. ${WF} 不存在"
if ( cd "$REPO" && bash -c 'source scripts/create-worker.sh; source scripts/lib/state.sh
        source scripts/lib/ledger.sh; source scripts/refresh-authkeys.sh 2>/dev/null
        source scripts/rotate-gateway.sh 2>/dev/null
        declare -F create_worker_ledger_add state_build state_next_serial ledger_remove \
                     refresh_collect_tunnel_keys rotate_assemble_sshproxy_keys >/dev/null' ) 2>/dev/null
then ok "0b. 模擬要呼叫的 repo 函式都讀得到（量的是實作，不是測試的模型）"
else bad "0b. repo 函式讀不到——後面的模擬全部不可信"; fi

echo
echo "=== 1. 分類：成功路徑寫了哪些池側狀態 ==="
classify "$REPO_ROOT/$WF" cur
if [[ -s "$SANDBOX/cur.err" ]]; then
    bad "1a. 分類器讀不了 workflow：$(head -2 "$SANDBOX/cur.err")"
else
    ok "1a. 分類器讀得了 workflow（$(grep -c . "$SANDBOX/cur.tsv") 個步驟）"
fi
if [[ -s "$SANDBOX/cur.unknown" ]]; then
    bad "1b. 有認不出來的改動（未建模 → 判準失效，必須先補進分類表）:"
    while IFS= read -r u; do printf '        %s\n' "$u"; done < "$SANDBOX/cur.unknown"
else
    ok "1b. 每一處改動都認得出（沒有未建模的池側狀態）"
fi
WRITTEN="$(cut -d$'\x1f' -f5 "$SANDBOX/cur.tsv" | tr ',' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
printf '        成功路徑寫到：%s\n' "${WRITTEN:-（無）}"
report_failure_path cur

echo
echo "=== 2. 逐一失敗點：回滾之後池側還剩下什麼 ==="
# 失敗點 = 成功路徑上的每一個步驟。回滾必須對**任何**一個失敗點都收乾淨，
# 不只是最後那一步——最後一步是實測碰巧打中的位置。
violations=""
npoints=0
for idx in $(cut -d$'\x1f' -f1 "$SANDBOX/cur.tsv"); do
    [[ "$(awk -F'\037' -v i="$idx" '$1==i{print $2}' "$SANDBOX/cur.tsv")" == "1" ]] && continue
    sname="$(awk -F'\037' -v i="$idx" '$1==i{print $3}' "$SANDBOX/cur.tsv")"
    npoints=$((npoints + 1))
    out="$(simulate cur "$idx" "$SANDBOX/pool-$idx")"
    if [[ -n "$out" ]]; then
        printf '  FAIL  打在「%s」（step %s）→ 殘留：%s\n' "$sname" "$idx" "$out"
        for k in $out; do
            [[ -f "$SANDBOX/pool-$idx/why.$k" ]] && \
                printf '          %s\n' "$(cat "$SANDBOX/pool-$idx/why.$k")"
        done
        violations="${violations}${idx} ;; ${out}"$'\n'
    else
        printf '  ok    打在「%s」（step %s）→ 收乾淨\n' "$sname" "$idx"
    fi
done
printf '        （%s 個失敗點）\n' "$npoints"


echo "=== 3. 不變量 ==="
HARNESS_BROKEN=0
if printf '%s' "$violations" | grep -q '!harness:'; then
    HARNESS_BROKEN=1
    bad "3h. 模擬器自己在某個失敗點壞掉（下面的綠色不可信）: $(printf '%s' "$violations" | grep '!harness:' | head -1)"
fi
if [[ "$HARNESS_BROKEN" -eq 0 ]]; then
    # **每一種池側狀態各自獨立判定。**
    #
    # 2026-09-26 之前這裡是一個彙總布林（「有沒有殘留」）。彙總有兩個問題，
    # 而且第二個會被第一個遮掉：
    #   * 它無法**指名**是哪一種殘留——只能說「有殘留」，而修的人需要知道是哪一種。
    #   * 一種被修好、另一種沒修好時，彙總只會說「還有殘留」，於是兩種狀況
    #     看起來一樣。而更糟的是：探針那邊也只問「有沒有殘留」，所以一個只補
    #     一半的 workflow 會被當成「沒在殘留的類別裡」而通過（4h 抓到的就是
    #     這個）。**獨立的判斷讓每一種自己說話，彙總只是把獨立結果印在一起。**
    #
    # 這一節印出五行，每一行是一種狀態自己的結論。結論區塊也逐種列出。
    RESIDUE_KINDS=""
    for k in container placeholder ledger state-cache authorized-keys; do
        pts="$(points_of "$violations" "$k")"
        if [[ -n "$pts" ]]; then
            bad "3.${k}：${k} 在失敗點 ${pts} 之後仍然殘留（這一種沒有被收乾淨）"
            RESIDUE_KINDS="${RESIDUE_KINDS}${k} "
        else
            ok "3.${k}：${k} 在每一個失敗點之後都收乾淨"
        fi
    done
    if [[ -z "$RESIDUE_KINDS" ]]; then
        ok "3z. 五種池側狀態全部收乾淨（逐種獨立判定，不是彙總）"
    else
        bad "3z. 仍未收乾淨的是：${RESIDUE_KINDS}"
    fi
fi

# 3c：迴歸——把基底自己的補救**拿掉**，state-cache 必須仍然是紅。
#     這是「這個守衛還抓得到原來那個缺陷」的證據，也是唯一一個在修正被
#     commit 進去之後仍然成立的寫法（見 §4 探針 4b 用同一個機制）。
if [[ "$HARNESS_BROKEN" -eq 0 ]]; then
    if probe no-remedy nore 2>/dev/null; then
        v3="$(violations_for "$SANDBOX/wf/nore.yml" nore)"
        if printf '%s' "$v3" | grep -q 'state-cache'; then
            ok "3c. 把補救拿掉之後 state-cache 仍然是紅（這個守衛還抓得到原來那個缺陷）"
            printf '        殘留的失敗點：%s\n' "$(points_of "$v3" state-cache)"
        else
            bad "3c. 拿掉補救之後 state-cache 卻是綠——這個守衛已經抓不到原來的缺陷了"
        fi
    else
        bad "3c. 探針 no-remedy 產生失敗: $(head -1 "$SANDBOX/probe-nore.err")"
    fi
fi

echo
echo "=== 4. 探針：證明判準會泛化，而且不靠「有沒有某個 step」 ==="
# 每一條都是「基底現在的樣子 → 改壞它 → 守衛必須紅」。基底是 impl 寫的
# 那一版，不是空白；這一點很重要（見 probe 層的檔頭說明）。
probe_summary() {   # probe_summary <tag> <預期：red|green> <只关心哪一種>
    local tag="$1" want="$2" kind="${3:-}"
    local v rc
    v="$(violations_for "$SANDBOX/wf/$tag.yml" "$tag")"; rc=$?
    if [[ $rc -ne 0 ]]; then
        printf '%s\n' "probe-error: 分類不過：$(head -2 "$SANDBOX/$tag.unknown")$(head -1 "$SANDBOX/$tag.err")"
        return 3
    fi
    local has_kind=""
    if [[ -n "$kind" ]]; then
        printf '%s' "$v" | grep -q -- "$kind" && has_kind=yes || has_kind=""
    else
        [[ -n "$v" ]] && has_kind=yes
    fi
    if [[ "$want" == "red" && -n "$has_kind" ]]; then
        PROBE_RED=1; return 0
    fi
    if [[ "$want" == "green" && -z "$v" ]]; then
        PROBE_GREEN=1; return 0
    fi
    if [[ "$want" == "green" ]]; then
        # 「只關心某一種」的綠：那一種沒有了就算過（重排修不到 authkeys 是預期的）
        [[ -z "$has_kind" ]] && { PROBE_GREEN=1; return 0; }
    fi
    PROBE_GOT="$(printf '%s' "$v" | tr '\n' ' ')"
    return 1
}

PROBE_RED=0; PROBE_GREEN=0; PROBE_GOT=""

# 4a：基底現在的樣子（impl 寫的那版）。這是驗收第 2 條——3a/3b 的綠只有在
#     4c/4d 也紅的情況下才是證據，所以它在這裡只是被記錄，不是被判定的對象。
# 4a：基底（工作樹現在的樣子）如實報。**綠與紅都在這裡講清楚**，因為這一條
#     不是「測試通過與否」，是「現在這個版本有沒有把不變量滿足掉」。
if probe asis base 2>/dev/null; then
    PROBE_GOT="$(violations_for "$SANDBOX/wf/base.yml" base)"
    if [[ -z "$PROBE_GOT" ]]; then
        inj_ok "4a. 基底 → 全綠（每一種宣告在所有失敗點都收乾淨）"
    else
        inj_bad "4a. 基底仍紅：$(kinds_of_blob "$PROBE_GOT")（失敗點：$(all_points "$PROBE_GOT")）"
    fi
else
    inj_bad "4a. 基底探針產生失敗（harness 問題）: $(head -1 "$SANDBOX/probe-base.err")"
fi

# 4b：從「沒有補救」的基底補一個正確的 → 綠。證明判準可被滿足，而且不依賴
#     impl 寫的那一版（所以基底換成任何寫法都成立）。
if probe no-remedy nore 2>/dev/null && probe correct+authkeys fixboth 2>/dev/null; then
    if probe_summary fixboth green; then
        inj_ok "4b. 從沒有補救的基底補上兩個正確的補救（快取 + authorized_keys）→ 全綠（判準可被滿足）"
    else
        inj_bad "4b. 補上兩個正確補救後仍紅：$PROBE_GOT"
    fi
else
    inj_bad "4b. 探針產生失敗（harness 問題）: $(head -1 "$SANDBOX/probe-fixboth.err")"
fi

# 4h：**只補一半**不算修好——而且必須**指名**沒補的那一種。
#
# 這條的診斷經過兩次，中間那個版本比原版更糟，值得記下來：
#   * 第一版：探針用 no-remedy 移除「快取那一種」補救，但沒有移除 authkeys 的
#     補救。於是它從來沒有構造出「只補一半」的狀態——基底自己的 authkeys 補救
#     還在裡面。**探針問的問題與它構造的狀態不是同一個**，所以它綠，而那個綠被
#     讀成「守衛接受只補一半」。探針沒構造出它聲稱的狀態，比探針紅更危險：
#     它讓人以為那一條被驗過了。
#   * 第二版：no-remedy 改成兩種補救各自可獨立移除，但**判準仍是彙總布林**
#     （「有沒有殘留」）。於是「只補快取」會紅——可是它只會說「有殘留」，不會說
#     是 authorized_keys 沒被收。彙總會讓一個被覆蓋掉另一個：兩種狀況（一種沒修／
#     兩種都沒修）在彙總裡是同一個值。
# 現在兩層都對：探針真的構造出半套（no-remedy 把兩種都拿掉，再只加一種），
# 判準逐種獨立判定（§3 印五行，每行是一種狀態自己的結論），所以這一條能指出
# **沒被補的是哪一種**。
half_probe() {   # half_probe <tag> <只補哪一種> <應該被指名的另一種>
    local tag="$1" mode="$2" expect="$3" v
    if ! probe "$mode" "$tag" 2>/dev/null; then
        printf 'probe-error:%s-failed' "$mode"; return 3
    fi
    v="$(violations_for "$SANDBOX/wf/$tag.yml" "$tag")"
    if [[ -z "$v" ]]; then
        printf 'no-violations'; return 1
    fi
    if printf '%s' "$v" | grep -q -- "$expect"; then
        printf 'red-names-%s' "$expect"; return 0
    fi
    printf 'red-but-names:%s' "$(kinds_of_blob "$v")"
    return 1
}

if r="$(half_probe halfcache half-cache authorized-keys)"; then
    inj_ok "4h1. 只補狀態快取 → 紅，且指名 authorized-keys（got [$r]）——部分補救不算修好，而且說得出缺哪一種"
else
    inj_bad "4h1. 只補狀態快取的結果是 [$r]（期望 red-names-authorized-keys）"
fi
if r="$(half_probe halfauth half-authkeys state-cache)"; then
    inj_ok "4h2. 只補 authorized_keys → 紅，且指名 state-cache（got [$r]）"
else
    inj_bad "4h2. 只補 authorized_keys 的結果是 [$r]（期望 red-names-state-cache）"
fi


# 4c：把基底自己的補救的 if: 改成永遠不成立 → 必須紅。
#     這一條直接對應「別人加了一個壞掉的 push-state 時會誤綠」：模型看的是
#     「那個動作有沒有真的發生」，不是「step 有沒有加」。
if probe dead-if deadif 2>/dev/null; then
    if probe_summary deadif red state-cache; then
        inj_ok "4c. 補救的 if: 永遠不成立（就地改壞，不是附加）→ 仍然紅"
    else
        inj_bad "4c. 壞掉的補救讓守衛轉綠了——這個測試在釘 step 存在，不是釘後果（got: ${PROBE_GOT:-乾淨}）"
    fi
else
    inj_bad "4c. 探針產生失敗: $(head -1 "$SANDBOX/probe-deadif.err")"
fi

# 4d：把補救整塊搬到「刪帳本」之前 → 必須紅。
#     順序錯的補救不是「沒修好」，它把一筆死 worker 寫進一份讀取端無條件相信
#     的快取——比不修更糟。模型算的是「執行當下帳本是什麼」，不是位置。
if probe wrong-order wrongorder 2>/dev/null; then
    if probe_summary wrongorder red state-cache; then
        inj_ok "4d. 補救被搬到「刪帳本」之前（就地搬位）→ 仍然紅（後果被算出來了）"
    else
        inj_bad "4d. 順序錯的補救讓守衛轉綠了——模型只看動作有沒有發生，沒看後果（got: ${PROBE_GOT:-乾淨}）"
    fi
else
    inj_bad "4d. 探針產生失敗: $(head -1 "$SANDBOX/probe-wrongorder.err")"
fi

# 4e：補救引用一個「在某些失敗點上還沒被產出」的 output → 必須紅。
#     這一條釘的是第三種狀態：「動作有跑，但跑失敗了」。前兩種是「守衛不成立」
#     與「順序不對」，這裡是「跑了、但結果不是清乾淨」。
if probe bad-refs badrefs 2>/dev/null; then
    if probe_summary badrefs red state-cache; then
        inj_ok "4e. 補救引用了還沒被產出的 output（動作會跑、但會失敗）→ 仍然紅"
    else
        inj_bad "4e. 壞參照的補救讓守衛轉綠了——模型把「跑了但失敗」算成「回滾成功」（got: ${PROBE_GOT:-乾淨}）"
    fi
else
    inj_bad "4e. 探針產生失敗: $(head -1 "$SANDBOX/probe-badrefs.err")"
fi

# 4f：加第六樣未建模的池側狀態 → 分類器必須紅。
if probe sixth sixth 2>/dev/null; then
    classify "$SANDBOX/wf/sixth.yml" sixth
    if [[ -s "$SANDBOX/sixth.unknown" ]]; then
        inj_ok "4f. 加了第六樣未建模的池側狀態 → 分類器紅（判準會泛化，不只釘這次的缺口）"
        printf '        %s\n' "$(head -1 "$SANDBOX/sixth.unknown")"
    else
        inj_bad "4f. 加了第六樣狀態，分類器卻沒認出來——這個判準只釘住這一次的缺口"
    fi
else
    inj_bad "4f. 探針產生失敗"
fi

# 4g：用重排達成同一件事（把成功路徑的寫入移到最後，不新增任何 step）→ 綠。
n_before="$(grep -c '^      - name:' "$REPO_ROOT/$WF")"
if probe reorder-push reorder 2>/dev/null; then
    n_after="$(grep -c '^      - name:' "$SANDBOX/wf/reorder.yml")"
    if probe_summary reorder green state-cache && [[ "$n_before" == "$n_after" ]]; then
        inj_ok "4g. 把 push-state 移到最後（沒有新增 step：${n_before} → ${n_after}）→ state-cache 綠"
        [[ -n "$PROBE_GOT" ]] && printf '        （重排修不到的那個缺口仍在：%s）\n' \
            "$(kinds_of_blob "$PROBE_GOT")"
    else
        inj_bad "4g. 重排修正沒讓 state-cache 綠：${PROBE_GOT:-（步驟數 ${n_before}→${n_after}）}"
    fi
else
    inj_bad "4g. 探針產生失敗: $(head -1 "$SANDBOX/probe-reorder.err")"
fi


echo "=== 5. 結論 ==="
if [[ "$HARNESS_BROKEN" -eq 1 ]]; then
    printf '結論：守衛自己壞掉，這個結果不能采信（harness error）\n'
elif [[ "$fail" -ne 0 ]]; then
    printf '結論：紅。create-worker 的失敗回滾會留下殘骸（細節在 §2／§3）。\n'
elif [[ "$injfail" -ne 0 ]]; then
    printf '結論：綠（不變量全過），但有 %s 條注入防線失敗——這個綠的可信度要打折。\n' "$injfail"
else
    printf '結論：綠。create-worker 失敗回滾在所有失敗點、五種狀態都收乾淨了。\n'
    # 逐種列出，兩欄都給：殘留的與收乾淨的。這樣「哪一種沒被修」不用 grep。
    for k in container placeholder ledger state-cache authorized-keys; do
        pts="$(points_of "$violations" "$k")"
        if [[ -n "$pts" ]]; then
            printf '      %-16s 殘留在失敗點 %s\n' "$k" "$pts"
        else
            printf '      %-16s 收乾淨\n' "$k"
        fi
    done
    printf '      注入：%s 個假綠防線全過\n' "$injpass"
fi
echo
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' \
    "$pass" "$fail" "$injpass" "$injfail"
[[ "$fail" -ne 0 ]] && exit "$fail"
[[ "$injfail" -ne 0 ]] && exit 2
exit 0
