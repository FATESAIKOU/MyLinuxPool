#!/usr/bin/env bash
# ops-scripts/pool-residue.sh — 池側殘骸的唯讀快照。給「create-worker 失敗回滾
# 到底收不乾淨」那個問題用。
#
# 為什麼需要這支：scripts/tests/test-create-worker-source.sh §4 只證明了那些
# `if: failure()` 步驟「叫得動」（它呼叫的函式解析得到），沒有證明它們
# 「收得乾淨」。一個不會 127 的回滾，仍然可能漏掉容器、漏掉埠、或刪錯對象。
# 補的方式是：真的讓 create 打到某個步驟失敗，然後從池側查殘留。本檔只做
# 量測工具——不注入故障、不跑 workflow。
#
# 殘骸有五種形狀，每一種只有一個視角看得見，所以五個視角缺一不可
# （回滾漏掉任何一種，其他視角都會回報「乾淨」）：
#
#   形狀                          只有哪個視角看得見
#   ----------------------------  ------------------------------------
#   容器留著（跑著**或 Exited**）  containers：provider 的 docker ps -a
#   帳本留著一筆死的              ledger：POOL_WORKERS repo variable
#   孤兒 placeholder              placeholders：Gateway 的 workers.d
#   隧道還在但上面沒東西          listeners：Gateway 的 ss
#   狀態快取還在宣告一台已死的    state-cache：Gateway 的 state.json
#
# 第五個（2026-09-26 追加）是唯一一個「帳本已經對了、它還是錯的」藏身處：
# create-worker 的步驟順序是「Record the worker in POOL_WORKERS → Push the
# state cache → Verify worker is actually reachable」，而四個 failure() 清理
# 步驟（抓 log、刪容器、放埠、刪帳本項目）**沒有重推快取**。對照
# delete-worker.yml：刪完帳本就 push-state，是對稱的。所以 create 在最後一步
# 失敗時，前四個視角全部收乾淨了，快取繼續宣告那台 worker——而讀取端無條件
# 相信它（push-state/run.sh 檔頭：readers trust this cache unconditionally）。
#
# `docker ps -a` 而不是 `docker ps`：停掉但沒刪掉的容器是回滾漏掉的一種，
# 而 `ps` 正好看不見它。孤兒 placeholder 是最安靜的一種——不影響任何現有
# worker，只會讓那個埠永遠配不出去，要等埠段用滿才有人發現。
#
# ---- 輸出契約（兩次跑之間沒變化就應該逐字相同）------------------------
#
# stdout 只有快照，格式是每行一筆記錄，空白分隔、欄位固定順序：
#
#   run     ...  這份快照是對哪個 Gateway、哪個埠段、哪幾台 provider 拍的
#   obs     subject=... result=observed|unobserved|absent|complete|incomplete [...]
#   row     ...  一筆觀測到的東西（consistency 那一節的 row 一個 port 一行）
#   aux     ...  預期會在、但不是殘骸的東西
#   stray   ...  在 workers.d 裡、但不該在那裡的東西
#   unclassified ...  一個連角色都沒辨認出來的 NODE_* var
#   unparsed ...  看到了但讀不出欄位的東西
#   dup     ...  同一個視角裡同一個 port 出現兩次（契約上 port 是唯一鍵）
#   tally   ...  這一節的統計
#
# 為什麼是 `key=value` 而不是對齊欄位：對齊要把欄寬訂在「這一跑看到的最長值」
# 上，那個長度會隨資料變——多一個 40 字的容器名，整個區塊的每一行都跟著位移，
# diff 會被排版雜訊淹掉。單一空白沒有這個問題（Docker 的容器名、image 參照、
# 狀態都不含空白；真的含空白會被 sanitize 成 `_`，不會讓一行看起來像兩行）。
#
# 為什麼沒有時間戳：加了時間戳，兩次跑就永遠不可能逐字相同，等於把這支工具
# 唯一的用途（diff）弄壞。要時間的人自己在外面 `date`。
#
# 為什麼排序全用 `LC_ALL=C`：排序結果會隨 locale 變，同一份資料在兩台機器上
# 排序不同，diff 就全紅。埠是**數值**排序（`2300` 必須排在 `999` 後面），
# 所以用補零的排序鍵排完再切掉——`sort -n` 對 "port=2300" 這種帶非數字前綴
# 的欄位行為不可靠（不同實作差異很大，常見結果是全部當 0）。
#
# **diff 之前先看 `run` 那一行**：Gateway 換過、埠段改過、provider 數量變了，
# 兩份快照就不可比，而內容量看起來會像「沒變」。這是 §1.7 那個形狀在比較層的
# 版本：兩種狀態共用一個值（兩份看起來一樣的輸出），下游拿它做決定。
#
# ---- 「沒看到」必須和「看到是空的」分開（docs/TESTPLAN.md §1.7）--------
#
# 本 repo 今天修過六處同一個形狀的缺陷：表示法只有一個位置，於是「查不到」
# 和「查到是空的」共用一個值，前者被印成後者——某台 provider 連不上時，它的
# 容器清單看起來是「這台沒有殘骸」。所以：
#
#   * 每個視角、每個對象都有 result=observed（真的查了，可能真的是空的）/
#     unobserved（沒查到，附 reason）/ absent（東西不存在）三態。
#   * 遠端命令一律在最後印一個完成標記 `##POOL_RESIDUE_DONE <exit>##`。
#     **只有這個標記能決定觀測結果**——和 mlp 的 NC_DONE 同一個形狀
#     （ops-scripts/mlp 的 gw_probe_port 註解）。原因：run_on_node 自己的失敗
#     和「遠端命令跑完但沒東西」都會給空的 stdout，兩者只能靠「命令有沒有跑
#     到最後」分開。這個標記刻意不叫 NC_DONE，那個字串是跨 repo 契約
#     （MyAiEntry 的 poolReachability 依賴它），不要摻在一起。
#   * 遠端 stderr 不會被當成訊號：run_on_node 沒有丟 stderr（gw_run 有），
#     那是診斷，不是觀測結果。
#
# 列舉本身給空東西也不算通過（preflight 的 ok_counted 同一個教訓）：0 個
# provider、0 筆帳本、0 個 placeholder，各自是「列舉沒給我東西看」，不是
# 「池子是乾淨的」。`run` 那行把 provider 數量印出來，就是為了讓這種情況
# 在 diff 裡現形。
#
# ---- 唯讀 --------------------------------------------------------------
#
# 這支腳本不刪、不建、不改**池子裡**的任何東西：遠端只跑 ls / cat / ss /
# `docker ps -a` / `gh api` 的 GET。沒有 --release、沒有 rm、沒有
# pool-port-alloc 的任何子命令（見下面第 1 條）。
#
# 借來的 helper 仍然會寫**本機**的快取，這是誠實的界線，不是這支腳本能
# 繞過的（見下面第 2 條）。
#
# ---- 這次做這支時才發現的限制與繞法 ------------------------------------
#
# 1. **`pool-port-alloc --list` 不是唯讀的。** 它是列 workers.d 最順手的工具，
#    但 `cmd_list` 會 `mkdir -p "$WORKERS_DIR"` 並 `exec 200> "$LOCK_FILE"`
#    （pool-port-alloc:163-165）——也就是「查一下」會**建立** workers.d 目錄、
#    建立或清空 .lock。在一台剛 provision 完、workers.d 應該是空的機器上跑它，
#    觀測動作本身就製造了狀態。繞法：這支腳本用 `ls -A1` 加逐檔 `cat` 讀
#    workers.d，完全不碰 pool-port-alloc。（`--claim`/`--release` 當然更會寫，
#    但那是它們的用途。）
#
# 2. **source mlp 會寫本機檔案。** `resolve_gateway` 會 `mkdir -p
#    ~/.mylinuxpool` 並把 Gateway 的 host key 釘進 `~/.mylinuxpool/known_hosts`
#    （ops-scripts/mlp:208-214）；`open_gateway_master` 會建 ControlMaster 與
#    一個臨時目錄；`pool-resolve` 會寫 `~/.mylinuxpool/cache/*.json`。這些都是
#    本機的 ssh/GitHub 快取，不是池子裡的狀態，而且寫入行為本身就是 mlp 信任
#    模型的一部分（不重寫、不繞過）。所以「唯讀」在這裡的定義是「不改池子」，
#    不是「不改本機任何檔案」。繞法：沒有——重寫一份就不叫共用，而這支工具的
#    判準就是共用那兩個 helper。
#
# 3. **遠端的工具不能假設存在。** 遠端是另一台機器：`ss` 不在、`docker` 不在，
#    都會把「查不到」變成「空的」。繞法：完成標記帶回遠端命令的退出碼，127
#    單獨分類成 remote-tool-missing；workers.d 的讀取改用 cat 加**本機** jq，
#    不假設遠端有 jq。
#
# 4. **工單裡的「23xx 埠」是今天的配置，不是規則。** 埠段來自
#    `NODE_GATEWAY.ports.worker`（今天 2300-2399，剛好整段都是 23xx）。寫死
#    23xx 的過濾器一旦埠段搬到 24xx，就會印出「沒有在聽的埠」——也就是「池子
#    乾淨」。那正是 §1.7 的形狀。繞法：埠段一律從 pool-resolve 取，並且把
#    `range=` 印在 listeners 的 obs 行上，讓埠段改動在 diff 裡現形。同一個
#    理由，provider 名單也不寫死，要從 NODE_* 問。
#
# 5. **`gh api .../variables?per_page=100` 沒有翻頁。** repo 的 Actions
#    variable 超過 100 個時，provider 清單會被**靜靜截斷**，而截斷掉的那一兩台
#    provider 看起來就像「那台沒殘骸」。這是 pool-status 與 mlp 的 gather_targets
#    共用的同一個限制，這支腳本沿用同一個呼叫（它只列 var **名稱**，連線資訊
#    一律走 pool-resolve——和 mlp 檔頭那個窄例外同一個理由）。繞法：把「0 個
#    provider」與「N 個 provider」在輸出裡分開，並且讓無法解析的 NODE_* var
#    自己現身（那可能正是一台沒被查到的 provider）。真的要看見第 101 個之後的
#    東西，得改那個呼叫，而那是一件獨立的事。
#
# 6. **遠端 stderr 會漏到本機終端機。** run_on_node 沒有丟 stderr，所以 provider
#    上的 `bash: warning: setlocale: LC_ALL: cannot change locale` 會直接噴出來
#    （實測）。繞法：遠端命令前加 `LC_ALL=C`——順便讓輸出不依賴 locale。
#
# 7. **沒有沿用 mlp 的 check_deps。** 它要求 fzf（這支工具沒有任何互動），訊息
#    前綴也是 "mlp:"。這裡只檢查 jq / gh / ssh，外加 pool-resolve 存在。
#
# 8. **本檔的自我位置解析區塊沒有被測試涵蓋。** 那個區塊是每支 ops-script 各抄
#    一份的，test-script-self-location.sh 逐位元組比對——但它比對的是**手寫的
#    四個檔名**（mlp / register-client / verify-profile / preflight，不是 glob）。
#    本檔的區塊是逐位元組複製的，但要讓它被守住，得把 `pool-residue.sh` 加進那
#    個清單（test-script-self-location.sh 的 for 迴圈，另有 probe_args /
#    probe_want 兩個函式）。在那之前，這個區塊只能靠複製時的紀律。
#
# 9. **mlp 的 helper 是有狀態的，不能包在 `$( )` 裡叫。** 這次真的踩到：
#    `err="$(open_gateway_master 2>&1)"` 會讓 open_gateway_master 在 subshell 裡
#    跑，它設的 CTL/CTL_DIR 隨 subshell 一起消失。GW_MASTER 仍然是 1，於是
#    view_placeholders 照跑，gw_run 拿著空的 CTL 發出 `ssh -S ''`，**什麼都沒
#    回來**。沒有完成標記的話，「什麼都沒回來」會被讀成「workers.d 是空的」，
#    也就是「池子乾淨」——一個由觀測工具自己生出來的假乾淨。繞法：完成標記
#    （於是它變成 result=unobserved reason=no-trace-from-remote），加上
#    open_gateway_master_quiet 把 stderr 導進本機暫存檔再逐行 note，絕不用
#    命令替換接它的回傳值。同一個道理適用於 resolve_gateway（它設 GW_*）——
#    那兩個在本檔都是直接在主 shell 呼叫的。
#
# 10. **provider 的「名單」是新的，「位址」可能是舊的。** 名單來自 gh（每次都
#     問），但 run_on_node 的 hop chain 來自 pool-resolve，而 pool-resolve 的
#     讀取順序是 state.json → GitHub → 本機 30 秒快取
#     （docs/STATE_CONTRACT.md §3；pool-resolve:111-125）。本機的 state.json
#     若過期，會被拿來探一台已經搬走的機器，結果是
#     reason=no-trace-from-remote——**那個 reason 不代表機器沒開，代表沒打到它**。
#     繞法：刪掉 ~/.mylinuxpool/state.json 再跑一次即可分辨；這支工具刻意不去
#     改它（刪別人的快取不是觀測工具該做的事）。要長期修，pool-resolve 該把
#     陳舊度一起帶出來。
#
# ---- 第五個視角（state.json）這輪才發現的 ------------------------------
#
# 11. **「readers trust this cache unconditionally」有前提，那句話本身不是
#     契約。** 它出自 push-state/run.sh 檔頭，講的是「push 失敗必須讓步驟失敗，
#     半寫的副本不能看起來像成功」——是寫入原子性，不是「讀取端不驗任何東西」。
#     實際上 pool-resolve 有 schema 守門：`.schema != 1` 就整份快取不用、改問
#     GitHub（pool-resolve:117-125；STATE_CONTRACT §2 invariant 1「讀取端遇到
#     不認得的值必須拒絕使用此快取並改問 GitHub，不可嘗試解讀」）。所以這個視角
#     **在 schema 不是 1 時不讀 workers**，只印出那個值並記 unobserved
#     reason=unknown-schema。把它當成「讀不到」而不是「0 個 worker」是這節最重要
#     的一個決定：一個不認得的 schema 配上 `workers: []`，跟真的空快取在畫面上
#     一模一樣。
#     真正沒有守門的是**內容**：schema=1 的舊快取與新的長得一模一樣，沒有任何
#     欄位能說出「我幾歲」。written_at 是 RFC3339 但 STATE_CONTRACT §2 明講
#     「僅供人閱讀，不可用於邏輯判斷」，所以這支工具照印（人要看），但絕不拿它
#     算任何東西——尤其是「快取比帳本舊多久」這種判斷。
#
# 12. **serial 是每一台 Gateway 自己的序號，不是全域的。** `state_next_serial`
#     在讀不到現有 state.json 時回傳 1（scripts/lib/state.sh:13-24），而
#     provision-gateway.sh 不會先種一份。所以 rotate 換成新機器之後，第一個 push
#     的 serial 是 1——契約上「單調遞增」只在**同一台 Gateway 的生命週期內**成立。
#     實測：今天 generation=18、serial=9（這台機器上推過 9 次）。
#     這對殘骸比對是個陷阱：rotate 前後兩份快照，serial 會**倒退**（9 → 1），
#     那看起來像「有人把快取回捲了」，其實只是換機。分辨要看 run 行的
#     generation=。所以 serial 照印（工單要求，而且它真的能指認 run），但這支
#     工具不因為 serial 倒退就說任何話。
#
# 13. **沒有任何現有工具同時看「帳本 + 這份快取」。** `mlp state`（cmd_state）
#     確實比 master vs gateway vs local 三份，但它那欄標成 "master" 的 ports 是
#     `pool-port-alloc --list` 的結果——**Gateway 自己的 placeholder**，不是
#     GitHub 的 POOL_WORKERS（ops-scripts/mlp:1197）。POOL_WORKERS 在整個
#     pool-status 與 cmd_state 裡都沒被讀過。所以「帳本對了但快取還是錯的」這個
#     形狀沒有現成的觀測點，這也是這個視角必須存在的理由。
#
# 14. **同一份快取在這個 Mac 上也有一份，而它沒有人查。** pool-resolve 的第一層
#     讀取來源就是 `~/.mylinuxpool/state.json`（pool-resolve:12），`mlp state`
#     會把它印在 "local" 那一欄。一台 Mac 上留著一份舊快照，會讓 pool-resolve 用
#     舊位址解析節點（就是第 10 條）。**那 是這個檔案的第六份副本**，而這個工具
#     只查池側那一份——因為工單的框法是「池側」。要涵蓋它需要另一個 subject，
#     不是這個視角加一個欄位。
#
# 15. **第五份副本在資料面，不只在控制面。** state.json 是 644 root-owned，所以
#     provider 是以 `sshproxy` 身分連進 Gateway 的（STATE_CONTRACT §2 記錄了
#     為什麼不放家目錄）。也就是說，一個沒清掉的快取**每一台 provider 的
#     pool-tunnel 都讀得到**（pool-tunnel:252-267 就是去抓這一份）。所以這個
#     殘骸的影響不是「operator 的 mlp ls 少一個 worker」，而是資料面會被餵一份
#     指向已死 worker 的解析結果。這也是為什麼這個形狀比孤兒 placeholder 嚴重。
#
# ---- 為什麼叫 pool-residue.sh，而不是工單上寫的 pool-residue ------------
#
# 因為 ops-scripts/preflight 的 shell 檔列舉是
# `git ls-files | grep -E '\.sh$|^ops-scripts/(mlp|verify-profile|preflight)$|/files/pool-'`
# ——沒有副檔名、名字又不在那三個裡的檔案，**不會**被 `bash -n` 語法檢查掃到，
# 也不會進 ssh 埠稽核。那正是 preflight 自己檔頭警告的形狀（「一個檔案可以一直
# 通過語法檢查，同時安靜地掉出稽核」）。叫 `.sh` 就被 `\.sh$` 免費收進兩項
# 檢查。位置沒有異議：LAYOUT §5 說 ops-scripts 就是人手動跑的東西。
#
# ---- 這支「不」做什麼（故意的）----------------------------------------
#
# * **不把四個視角交叉比對，不輸出「有無殘骸」的結論。** 工單要的是原始觀測
#   加一份可以 diff 的輸出；把「孤兒」這種結論算在工具裡，就會多出一層可能
#   自己算錯、而原始觀測不會錯的東西。判斷交給 diff 的那個人。
# * **不用 `mlp ls`。** 那是加工過的結論（cmd_ls 已經把 dead / out-of-pool /
#   inconclusive 收斂成一個狀態欄），這裡要的是沒被加工過的觀測。只重用它的
#   連線 helper（run_on_node / resolve_gateway / gw_run）與 self-location，
#   不呼叫它的任何 cmd_*。
# * **不推時間戳、不把輸出排成「正常」的樣子。** 見上面。
#
# 用法：ops-scripts/pool-residue.sh [-h|--help]
# 結束碼：0 每個對象都觀測到 / 1 有東西沒看到（部分快照）/ 2 快照做不出來
set -uo pipefail

# Resolve this script's REAL location, following symlinks, so it can be
# linked into a directory on PATH (`ln -s .../ops-scripts/mlp <dir on PATH>`).
# Both $0 and BASH_SOURCE name the LINK, not the target, so dirname on
# either lands in the link's directory and every repo-relative path below
# becomes wrong — the symptom is "scripts/lib/ssh.sh: No such file".
# `readlink` without -f is used deliberately: -f is GNU-only.
#
# This block is duplicated in every ops-script because it has to run
# BEFORE the script knows where the repo is — there is nothing to source
# yet. test-script-self-location.sh asserts the copies stay identical.
_mlp_self="${BASH_SOURCE[0]:-$0}"
while [ -L "$_mlp_self" ]; do
    _mlp_dir="$(cd -P "$(dirname "$_mlp_self")" && pwd)"
    _mlp_self="$(readlink "$_mlp_self")"
    case "$_mlp_self" in /*) ;; *) _mlp_self="${_mlp_dir}/${_mlp_self}" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_mlp_self")" && pwd)"
unset _mlp_self _mlp_dir
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Reuse mlp's connection layer. Sourcing it is safe, and is how its own tests
# load it: main is guarded by `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`
# (ops-scripts/mlp:2935), so nothing runs on source. Sourcing also brings in
# POOL_RESOLVE, REPO, the Gateway globals, run_on_node, resolve_gateway (with
# its "nodie" mode), open/close_gateway_master and gw_run. It sets
# `set -uo pipefail` and SSH_IDENTITY too, and SSH_IDENTITY 是 far-side hops
# 之所以還能認得出機器的全部原因（mlp 檔頭、RUNBOOK §7.12）。
if [[ ! -f "${SCRIPT_DIR}/mlp" ]]; then
    printf 'pool-residue: 找不到 %s/mlp——請在 MyLinuxPool checkout 裡跑\n' \
        "$SCRIPT_DIR" >&2
    exit 2
fi
# shellcheck source=./mlp
source "${SCRIPT_DIR}/mlp"

usage() {
    cat <<'EOF'
usage: pool-residue [-h|--help]

池側殘骸的唯讀快照。五個視角（每一種殘骸只有一個視角看得見）：
  containers     每台 provider 的 docker ps -a（含 Exited 的）
  ledger         POOL_WORKERS repo variable
  placeholders   Gateway 的 ~/.mylinuxpool/workers.d
  listeners      Gateway 的 ss，限 NODE_GATEWAY.ports.worker 範圍
  state-cache    Gateway 的 /var/lib/mylinuxpool/state.json
  consistency    以上五邊對齊（只說「哪幾邊看到」，不判斷哪個是殘骸）

唯讀：不會刪除、建立或修改池子裡的任何東西。
兩次跑之間沒有變化，輸出應該逐字相同——直接 diff 即可。
一致性那節不會影響結束碼：結束碼只代表「有沒有東西沒看到」。
結束碼：0 全部觀測到 / 1 有東西沒看到 / 2 快照做不出來
EOF
}

check_deps_and_args() {
    local dep
    case "${1:-}" in
        "") ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac

    # jq / gh / ssh：不用 fzf（沒有任何互動），所以不沿用 mlp 的 check_deps——
    # 它要求 fzf，訊息前綴也不是這個工具的。
    for dep in gh jq ssh; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            printf 'pool-residue: 缺少 %s（ brew install %s ）\n' "$dep" "$dep" >&2
            exit 2
        fi
    done
    if [[ ! -x "$POOL_RESOLVE" ]]; then
        printf 'pool-residue: pool-resolve 不在 %s\n' "$POOL_RESOLVE" >&2
        exit 2
    fi
}

# 完成標記。遠端命令的最後一行會印 "<SENT> <該命令的退出碼>##"；沒有這一行
# 就是「沒跑到最後」，不管 stdout 是不是空的。刻意不叫 NC_DONE——那是跨 repo
# 契約，摻在一起會讓兩邊的判讀混淆。
SENT="##POOL_RESIDUE_DONE"
NO_DIR="##POOL_RESIDUE_NO_DIR##"
NO_FILE="##POOL_RESIDUE_NO_FILE##"
LEDGER_VAR="POOL_WORKERS"
# Gateway 上的狀態快取（docs/STATE_CONTRACT.md §2）。寫在這裡而不是散在
# 遠端命令字串裡：這是第五個視角唯一的路徑，寫死一次比在字串裡出現兩次好。
STATE_CACHE_PATH="/var/lib/mylinuxpool/state.json"

# ---- 診斷一律走 stderr -------------------------------------------------
# stdout 是給 diff 的。gh 的錯誤訊息會變動、會帶路徑，混進快照裡會讓每次 diff
# 都紅；raw 的 gh 錯誤也有把 token 一起印出來的可能（pool-resolve 的 redact()
# 就是為此存在），所以先洗掉再說。
note() { printf 'pool-residue: %s\n' "$*" >&2; }

redact() {
    local s="$1"
    if [[ -n "${GH_TOKEN:-}" ]]; then
        s="${s//$GH_TOKEN/***REDACTED***}"
    fi
    printf '%s' "$s"
}

first_line() { printf '%s' "$1" | head -1; }

# 每一邊「有沒有觀測到」，給 consistency 那一節算完整性用。由各 view 在
# 觀測成功時設 1；預設 0 就是「沒看到」，所以忘記設的後果是保守的那一邊。
LEDGER_SEEN=0
PLACEHOLDERS_SEEN=0
LISTENERS_SEEN=0
STATE_CACHE_SEEN=0

# ---- 「有東西沒看到」的全域旗標 ----------------------------------------
# 結束碼從這裡算，不從自己的輸出 grep 回去：grep 自己的輸出等於把判斷建立在
# 「印出來的字串剛好長這樣」上，改一個 key 就會讓結束碼默默地變。
UNSEEN=0

# ---- 計數器（給每節的 tally）-------------------------------------------
T_OBS=0; T_OBSERVED=0; T_UNOBSERVED=0; T_ABSENT=0; T_COMPLETE=0; T_INCOMPLETE=0
T_ROWS=0; T_UNREADABLE=0; T_UNPARSED=0; T_STRAY=0

reset_tally() {
    T_OBS=0; T_OBSERVED=0; T_UNOBSERVED=0; T_ABSENT=0; T_COMPLETE=0; T_INCOMPLETE=0
    T_ROWS=0; T_UNREADABLE=0; T_UNPARSED=0; T_STRAY=0
}

# complete / incomplete 是 consistency 那一節專用的兩個值。它們**不是**
# observed：complete 說的是「五邊都看到了」，不是「這五邊的某一邊被看到了」。
# 把它們塞進 observed 的桶會讓 tally 說謊（實測過：obs=1 observed=0）。
tally() {
    printf 'tally obs=%s observed=%s unobserved=%s absent=%s complete=%s incomplete=%s rows=%s unreadable=%s unparsed=%s stray=%s\n' \
        "$T_OBS" "$T_OBSERVED" "$T_UNOBSERVED" "$T_ABSENT" "$T_COMPLETE" "$T_INCOMPLETE" \
        "$T_ROWS" "$T_UNREADABLE" "$T_UNPARSED" "$T_STRAY"
}

# obs <subject> <result> [key=value ...]
#   result 三態：observed（真的查了，可能真的是空的）／unobserved（沒查到，
#   一定要帶 reason）／absent（東西不存在）。只有 observed 會出現
#   rows=/entries=/listeners= 這種「查到幾筆」——因為那是觀測結果。
#   unobserved 與 absent 都算「沒看到」，結束碼因此是 1：absent 不是乾淨，
#   是池子少了一樣東西（POOL_WORKERS 這個變數必須存在，workers.d 由
#   provision-gateway 重建）。
obs() {
    local subject="$1" result="$2"; shift 2
    T_OBS=$((T_OBS + 1))
    case "$result" in
        observed)   T_OBSERVED=$((T_OBSERVED + 1)) ;;
        unobserved) T_UNOBSERVED=$((T_UNOBSERVED + 1)); UNSEEN=1 ;;
        absent)     T_ABSENT=$((T_ABSENT + 1)); UNSEEN=1 ;;
        complete)   T_COMPLETE=$((T_COMPLETE + 1)) ;;
        incomplete) T_INCOMPLETE=$((T_INCOMPLETE + 1)); UNSEEN=1 ;;
    esac
    printf 'obs subject=%s result=%s' "$subject" "$result"
    local kv
    for kv in "$@"; do printf ' %s' "$kv"; done
    printf '\n'
}

# ---- 遠端觀測的解碼 ---------------------------------------------------
#
# obs_decode <captured-stdout>：設定 OBS=observed|unobserved 與 OBS_REASON。
#   規則只有一條：完成標記不存在 → 沒跑到最後 → unobserved，不管 stdout 是不
#   是空的。標記存在才看它帶的退出碼：0 = 觀測到了；127 = 遠端沒有那個工具
#   （這是「不知道」，不是「沒有」）；其他非 0 = 遠端命令自己失敗。
#   逐筆記錄的失敗（某個檔案壞掉）不算整體失敗——「看到了一個讀不出來的東西」
#   與「整份清單沒讀到」是兩件事。
OBS=""
OBS_REASON=""

obs_decode() {
    local out="$1" line code=""
    OBS="unobserved"
    OBS_REASON="no-trace-from-remote"
    while IFS= read -r line; do
        case "$line" in
            "${SENT} "*"##")
                code="${line#"${SENT} "}"
                code="${code%##}"
                ;;
        esac
    done <<< "$out"
    [[ -n "$code" ]] || return 1
    case "$code" in
        0)   OBS="observed"; OBS_REASON="" ;;
        127) OBS="unobserved"; OBS_REASON="remote-tool-missing" ;;
        *)   OBS="unobserved"; OBS_REASON="remote-exit-${code}" ;;
    esac
}

# obs_data <captured-stdout>：去掉標記行，只留資料行
obs_data() { printf '%s\n' "$1" | grep -v "^${SENT} " || true; }

# sanitize <text>：欄位裡不允許有空白。Docker 的容器名、image 參照、狀態都沒有
# 空白，但萬一有，讓它變成可見的 `_` 好過讓一行看起來像兩行。
sanitize() {
    case "$1" in
        *[[:space:]]*) : ;;
        *) printf '%s' "$1"; return 0 ;;
    esac
    printf '%s' "$1" | tr '\t\r\n' '   ' | tr -s ' ' \
        | sed 's/^ *//; s/ *$//; s/ /_/g'
}

# json_field <json> <jq-path>：讀一個欄位，絕不空、絕不含空白。
#   欄位不存在（null）印 "?"，不是空字串——這是同一個形狀：placeholder 少了
#   container 欄（pool-port-alloc 剛 claim 完、還沒被「Record container name」
#   補上時就是那個形狀）與「這筆沒有 container」共用一個值，會讓人以為兩者
#   相同。「?」在 diff 裡是看得出來的。
json_field() {
    local v
    v="$(printf '%s' "$1" | jq -r "$2 // \"?\"" 2>/dev/null)" || v=""
    [[ -n "$v" ]] || v="?"
    sanitize "$v"
}

# 排序全用 LC_ALL=C：結果會隨 locale 變，同一份資料在兩台機器上排序不同，
# diff 就全紅。
sort_rows() { LC_ALL=C sort; }

# sort_rows_by_port：埠是數值排序，補零鍵排完再切掉。
# 用法：每行是 "<8 位補零埠>\t<整行記錄>"。
sort_rows_by_port() { LC_ALL=C sort | cut -f2-; }

port_key() { printf '%08d\t%s\n' "$1" "$2"; }

count_rows() { printf '%s\n' "$@" | grep -c . || true; }

# ---- 跨視角比對用的登記簿 ----------------------------------------------
#
# consistency 那一節要把五邊對起來，而五邊的共同語言只有 port 與 container。
# bash 3.2 沒有關聯陣列（mlp 檔頭明列這條限制），所以這裡用一個扁平陣列：每筆
# 一行「view<TAB>port<TAB>container<TAB>provider」。空的欄位代表「這一個視角
# 沒有這一筆」，不是「空值」。規模是幾十筆，線性掃描就好，不要為此發明結構。
#
#   claim <view> <port> <container> <provider>
CLAIMS=()
claim() {
    CLAIMS+=("$(printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4")")
}

# claim_has <view> <port>：這個視角到底有沒有這一筆（不看欄位值）。
#   為什麼需要它：listeners 那一邊的 container 欄是空的（見檔頭第 16 條），
#   而 claim_lookup 對空值回 1——用它查 listeners 會得到「沒有在聽的埠」，
#   剛好和真的沒有相反（實測：四個在聽的埠全部印成 listeners=-）。
claim_has() {
    local want_view="$1" want_port="$2" rec v p
    for rec in ${CLAIMS[@]+"${CLAIMS[@]}"}; do
        v="${rec%%	*}"; rec="${rec#*	}"
        [[ "$v" == "$want_view" ]] || continue
        p="${rec%%	*}"
        [[ "$p" == "$want_port" ]] && return 0
    done
    return 1
}

# claim_lookup <view> <port> <field>：該視角對這個埠的欄位值。field 是
#   container 或 provider。沒有回 1。同一個 (view,port) 有兩筆時回傳第一筆，
#   並把筆數放進 CLAIM_DUP——不默默挑一個（契約上 port 是唯一鍵，重複本身是
#   要被看見的東西）。
CLAIM_DUP=""
claim_lookup() {
    local want_view="$1" want_port="$2" field="$3"
    local rec v p c prov hits=0 found=""
    CLAIM_DUP=""
    for rec in ${CLAIMS[@]+"${CLAIMS[@]}"}; do
        v="${rec%%	*}"; rec="${rec#*	}"
        [[ "$v" == "$want_view" ]] || continue
        p="${rec%%	*}"; rec="${rec#*	}"
        [[ "$p" == "$want_port" ]] || continue
        c="${rec%%	*}"; prov="${rec#*	}"
        hits=$((hits + 1))
        [[ -n "$found" ]] && continue
        case "$field" in
            container) found="$c" ;;
            provider)  found="$prov" ;;
            *)         return 1 ;;
        esac
    done
    CLAIM_DUP="$hits"
    [[ -n "$found" ]] || return 1
    printf '%s' "$found"
    return 0
}

# 某個容器名在 containers 視角裡嗎？回傳 yes / no。容器視角整體沒觀測到時
# 回傳 unknown（由 container_view_result 負責）。
claim_container_seen() {
    local want="$1" rec v
    [[ -n "$want" ]] || return 1
    for rec in ${CLAIMS[@]+"${CLAIMS[@]}"}; do
        v="${rec%%	*}"
        [[ "$v" == "containers" ]] || continue
        rec="${rec#*	}"; rec="${rec#*	}"
        v="${rec%%	*}"
        [[ "$v" == "$want" ]] && return 0
    done
    return 1
}

# 某個容器名由哪個 provider 承載（從 containers 視角取——那是唯一知道容器在哪
# 一台機器上的視角）。
claim_container_provider() {
    local want="$1" rec v
    [[ -n "$want" ]] || return 1
    for rec in ${CLAIMS[@]+"${CLAIMS[@]}"}; do
        v="${rec%%	*}"
        [[ "$v" == "containers" ]] || continue
        rec="${rec#*	}"; rec="${rec#*	}"
        v="${rec%%	*}"
        [[ "$v" == "$want" ]] || continue
        printf '%s' "${rec#*	}"
        return 0
    done
    return 1
}

# containers 視角對某個 provider 的觀測結果：yes（看到了）/ no（看到了，沒有這個
# 容器）/ unknown（那台 provider 沒被觀測到）。**unknown 不是 no**——這正是
# §1.7 的形狀，而它在這裡會直接改變結論的強度。
CONTAINER_SUBJECTS=()
container_view_result() {
    local provider="$1" container="$2" rec p r
    if [[ -z "$container" ]]; then
        printf 'none'
        return 0
    fi
    for rec in ${CONTAINER_SUBJECTS[@]+"${CONTAINER_SUBJECTS[@]}"}; do
        p="${rec%%	*}"; r="${rec#*	}"
        [[ "$p" == "$provider" ]] || continue
        [[ "$r" == "observed" ]] || { printf 'unknown'; return 0; }
        if claim_container_seen "$container"; then printf 'yes'; else printf 'no'; fi
        return 0
    done
    printf 'unknown'
    return 0
}
container_subject() { CONTAINER_SUBJECTS+=("$(printf '%s\t%s' "$1" "$2")"); }

# container_view_complete：containers 視角算不算「看到了」。**要求每一台 provider
# 都觀測到**，不是只要有一台：少一台就是那台的容器清單不明，而那正是本工具要
# 杜絕的「看起來是空的」。一個 subject 都沒有也算不完整（等於沒查）。
container_view_complete() {
    local rec p r n=0
    for rec in ${CONTAINER_SUBJECTS[@]+"${CONTAINER_SUBJECTS[@]}"}; do
        p="${rec%%	*}"; r="${rec#*	}"
        n=$((n + 1))
        [[ "$r" == "observed" ]] || return 1
    done
    [[ $n -gt 0 ]]
}

# port_provider <port> / port_container <port>：這個埠在「會記名字」的三個視角
# （帳本、placeholder、快取）裡第一個說得出來的值。listeners 不會說容器，
# containers 視角不知道埠，所以那兩邊不參與。全部說不出來時 provider 印 "-"
# （不是 "?"——"?" 是「有說但讀不出來」，那是 json_field 的職責）。
port_provider() {
    local v p
    for v in ledger placeholders state_cache; do
        p="$(claim_lookup "$v" "$1" provider 2>/dev/null)" || continue
        [[ -n "$p" && "$p" != "?" ]] && { printf '%s' "$p"; return 0; }
    done
    printf -- '-'
    return 1
}

port_container() {
    local v c
    for v in ledger placeholders state_cache; do
        c="$(claim_lookup "$v" "$1" container 2>/dev/null)" || continue
        [[ -n "$c" && "$c" != "?" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# ---- Gateway（先解析：run 行與兩個 Gateway 視角都要用）----------------
GW_STATE="unknown"
GW_DESC="unknown"
GW_GEN="unknown"
PORT_LO=""
PORT_HI=""

resolve_gateway_state() {
    if resolve_gateway nodie; then
        GW_STATE="ok"
        GW_DESC="${GW_USER}@${GW_IP}:${GW_PORT}"
    else
        note "Gateway 解析不了（${RESOLVE_DETAIL}）——placeholders 與 listeners 兩節會是 unobserved"
        return 1
    fi

    # 埠段與 generation 一起取：--field 吃的是 jq 運算式，一次拿三個欄位。
    # 這一次呼叫通常吃到 resolve_gateway 剛剛 --refresh 寫進去的 30 秒快取。
    local meta rc=0
    meta="$("$POOL_RESOLVE" gateway \
        --field '{ip: .ip, generation: .generation, worker: .ports.worker}' 2>/dev/null)" || rc=$?
    if [[ $rc -ne 0 ]] || ! printf '%s' "$meta" | jq empty >/dev/null 2>&1; then
        note "拿不到 NODE_GATEWAY 的埠段／generation（pool-resolve exit ${rc}）——listeners 無法過濾，會是 unobserved"
        return 1
    fi
    GW_GEN="$(printf '%s' "$meta" | jq -r '.generation // "unknown"')"
    PORT_LO="$(printf '%s' "$meta" | jq -r '.worker[0] // empty')"
    PORT_HI="$(printf '%s' "$meta" | jq -r '.worker[1] // empty')"
    # 除了「有沒有」，還要「是不是數字」：view_listeners 裡那個 [[ p -ge lo ]]
    # 拿到非數字會直接在 stderr 報錯然後判 false，結果是「整節沒有 listener」
    # ——那正是這個工具要防的假乾淨。埠段形狀不對要說成 unobserved，不是空。
    if [[ ! "$PORT_LO" =~ ^[0-9]+$ || ! "$PORT_HI" =~ ^[0-9]+$ ]]; then
        note "NODE_GATEWAY.ports.worker 不是數字埠段（$(redact "$(first_line "$meta")")）——listeners 無法過濾，會是 unobserved"
        PORT_LO=""; PORT_HI=""
        return 1
    fi
    return 0
}

# open_gateway_master 失敗不 die：這支工具必須在 Gateway 掛掉的時候還能交出
# ledger 與（看得到的情況下）containers 那一節。全有全無的工具恰好在出事時
# 最沒用。
#
# **絕對不能寫成 `err="$(open_gateway_master 2>&1)"`。** 見檔頭第 9 條。簡版：
# open_gateway_master 是有狀態的（它把 CTL/CTL_DIR 設成全域變數），而 `$( )` 是
# subshell，那兩個變數會跟著消失。沒有完成標記的話，症狀是「gw_run 什麼都沒
# 回來」被讀成「workers.d 是空的」——一個由觀測工具自己生出來的假乾淨。診斷要
# 改寫前綴，所以 stderr 先進一個本機暫存檔，再由這裡逐行 note 出來。
GW_MASTER=0
open_gateway_master_quiet() {
    local rc=0 errf="" line
    errf="$(mktemp "${TMPDIR:-/tmp}/pool-residue.XXXXXX" 2>/dev/null)" || errf=""
    if [[ -n "$errf" ]]; then
        open_gateway_master 2>"$errf" || rc=$?
    else
        open_gateway_master || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        if [[ -n "$errf" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && note "gateway master: ${line}"
            done < "$errf"
            rm -f "$errf"
        fi
        return 1
    fi
    [[ -n "$errf" ]] && rm -f "$errf"
    GW_MASTER=1
    return 0
}

# ---- provider 列舉 ----------------------------------------------------
# 名單來自 repo 的 NODE_* var（不寫死台數），篩 role=provider。這是 mlp 與
# pool-status 共用的那一個 `gh api .../variables` 窄例外：它只列 var **名稱**，
# 連線資訊一律走 pool-resolve。沒有翻頁（見檔頭第 5 條）。
PROVIDERS=()        # 顯示用名稱（連字號，STATE_CONTRACT §2 invariant 2）
PROVIDERS_CALL=()   # 給 pool-resolve / run_on_node 用的名稱
PROVIDER_UNCLASSIFIED=()   # 連角色都沒辨認出來的 NODE_* var
PROV_ENUM="unknown"  # ok | none | unknown

enumerate_providers() {
    local out rc=0 var node_call node_disp json role
    out="$(gh api "repos/${REPO}/actions/variables?per_page=100" \
            --jq '.variables[].name' 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        PROV_ENUM="unknown"
        note "列不出 NODE_* var（gh api exit ${rc}）：$(redact "$(first_line "$out")")"
        return 1
    fi

    local names=() calls=() unclassified=()
    while IFS= read -r var; do
        [[ "$var" == NODE_* ]] || continue
        [[ "$var" == NODE_GATEWAY ]] && continue
        # var 去掉前綴再轉小寫，就是 pool-resolve 一定認得的名字：它會
        # var_name_for() 轉回大寫加底線，剛好回到同一個 var。這個來回是
        # 建構出來的，不靠「JSON 裡的 .name 剛好等於 var 名」這個慣例。
        node_call="$(printf '%s' "${var#NODE_}" | tr '[:upper:]' '[:lower:]')"
        # 顯示用連字號版：帳本與 workers.d 裡都是連字號，兩邊用不同拼法會讓人
        # diff 到假的「不一致」。
        node_disp="$(printf '%s' "$node_call" | tr '_' '-')"

        json="$("$POOL_RESOLVE" "$node_call" 2>/dev/null)" || json=""
        if [[ -z "$json" ]]; then
            # 解析不了不代表它不是 provider——它可能正是一台我們查不到容器的
            # 機器。讓它自己在 containers 那一節現身，不要靜靜跳過。
            names+=("$node_disp")
            calls+=("$node_call")
            unclassified+=("$node_disp")
            continue
        fi
        role="$(printf '%s' "$json" | jq -r '.role // empty' 2>/dev/null)"
        [[ "$role" == "provider" ]] || continue
        names+=("$node_disp")
        calls+=("$node_call")
    done <<< "$out"

    if [[ ${#names[@]} -eq 0 ]]; then
        PROV_ENUM="none"
        note "一個 role=provider 的 NODE_* 都找不到——這是列舉給了空東西，不是池子乾淨"
        return 1
    fi
    PROVIDERS=("${names[@]+${names[@]}}")
    PROVIDERS_CALL=("${calls[@]+${calls[@]}}")
    PROVIDER_UNCLASSIFIED=("${unclassified[@]+${unclassified[@]}}")
    PROV_ENUM="ok"
    return 0
}

# ---- 視角 1/5：containers（provider 的 docker ps -a）------------------
# 每台 provider 一個 obs。查不到就是 unobserved——絕不印成「這台沒有容器」。
view_containers() {
    printf '[containers] provider docker ps -a\n'
    reset_tally

    if [[ "$PROV_ENUM" != "ok" ]]; then
        obs providers unobserved "reason=provider-enumeration-${PROV_ENUM}"
    fi

    local i n out disp call rcmd raw n_rows rows=() f1 f2 f3
    n=${#PROVIDERS[@]}
    for (( i = 0; i < n; i++ )); do
        disp="${PROVIDERS[$i]}"
        call="${PROVIDERS_CALL[$i]}"
        # LC_ALL=C：provider 上的 bash 會噴 setlocale 警告（run_on_node 不丟
        # stderr），順便讓輸出不依賴 locale。docker 自己的 stderr 丟掉——它說什麼
        # 不是觀測結果，退出碼才是。
        rcmd="LC_ALL=C docker ps -a --format '{{.Names}}|{{.State}}|{{.Image}}' 2>/dev/null"
        rcmd="${rcmd}; printf '${SENT} %s##\\n' \"\$?\""
        out="$(run_on_node "$call" "$rcmd" 2>/dev/null)"

        if ! obs_decode "$out"; then
            obs "$disp" unobserved "reason=${OBS_REASON}"
            container_subject "$disp" unobserved
            continue
        fi

        rows=()
        n_rows=0
        while IFS= read -r raw; do
            [[ -n "$raw" ]] || continue
            if [[ "$raw" != *"|"*"|"* ]]; then
                # 看到了一行讀不出來的东西：這是觀測，不是空白。
                rows+=("row provider=${disp} unparsed=$(sanitize "$raw")")
                T_UNPARSED=$((T_UNPARSED + 1))
                UNSEEN=1
                n_rows=$((n_rows + 1))
                continue
            fi
            f1="${raw%%|*}"
            f2="${raw#*|}"; f2="${f2%%|*}"
            f3="${raw#*|*}"; f3="${f3#*|}"
            rows+=("row provider=${disp} name=$(sanitize "$f1") state=$(sanitize "$f2") image=$(sanitize "$f3")")
            # 容器視角不知道自己的埠（docker ps -a 不會說），所以 port 欄留空。
            # consistency 那一節用 container→port 的反查把它接回去。
            claim containers "" "$(sanitize "$f1")" "$disp"
            n_rows=$((n_rows + 1))
        done < <(obs_data "$out")

        # obs 在 rows 之前： verdict 那一行是「這台查到了沒有」，讀的人先看它
        # 再看下面那些 row。順序固定，diff 才不會有那種「多了一個 provider 所以
        # 整段位移」的雜訊。
        obs "$disp" observed "rows=${n_rows}"
        container_subject "$disp" observed
        T_ROWS=$((T_ROWS + n_rows))
        if [[ ${#rows[@]} -gt 0 ]]; then
            printf '%s\n' "${rows[@]}" | sort_rows
        fi
    done

    # 列出不了角色的 NODE_* var：它可能正是一台沒被查到的 provider。獨立成
    # 一種記錄，而不是併進 obs——那是列舉的可信度問題，不是某台 provider 的
    # 觀測結果。
    for disp in ${PROVIDER_UNCLASSIFIED[@]+"${PROVIDER_UNCLASSIFIED[@]}"}; do
        printf 'unclassified node=%s reason=pool-resolve-failed\n' "$disp"
        UNSEEN=1
    done

    tally
}

# ---- 視角 2/5：ledger（POOL_WORKERS）----------------------------------
# 這是主本（docs/STATE_CONTRACT.md §1）：GitHub repo variable。讀得到就整份
# 讀出來，不加工。
view_ledger() {
    printf '[ledger] %s\n' "$LEDGER_VAR"
    reset_tally

    local out rc=0
    out="$(gh api "repos/${REPO}/actions/variables/${LEDGER_VAR}" --jq .value 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        if printf '%s' "$out" | grep -q '404'; then
            # 變數不存在是第三種狀態：不是「帳本是空的」，也不是「讀不到」。
            obs "$LEDGER_VAR" absent reason=variable-not-defined
        else
            note "讀 ${LEDGER_VAR} 失敗（gh api exit ${rc}）：$(redact "$(first_line "$out")")"
            obs "$LEDGER_VAR" unobserved reason=gh-api-failed
        fi
        tally
        return
    fi

    # gh 的 --jq 對空字串會印一行空白、退出碼 0。空字串不是合法的帳本；空的帳本
    # 是 "[]"。把前者當成「空的」就是這支工具要防的那種缺陷。
    if [[ -z "${out//[[:space:]]/}" ]]; then
        note "${LEDGER_VAR} 是空字串——不是合法的帳本（空帳本請寫 []）"
        obs "$LEDGER_VAR" unobserved reason=empty-value
        tally
        return
    fi
    if ! printf '%s' "$out" | jq empty >/dev/null 2>&1; then
        note "${LEDGER_VAR} 不是合法 JSON"
        obs "$LEDGER_VAR" unobserved reason=not-json
        tally
        return
    fi
    if [[ "$(printf '%s' "$out" | jq -r 'type' 2>/dev/null)" != "array" ]]; then
        note "${LEDGER_VAR} 不是 JSON 陣列"
        obs "$LEDGER_VAR" unobserved reason=not-an-array
        tally
        return
    fi

    local count i entry port keys=() row
    count="$(printf '%s' "$out" | jq 'length')"
    LEDGER_SEEN=1
    obs "$LEDGER_VAR" observed "entries=${count}"

    for (( i = 0; i < count; i++ )); do
        entry="$(printf '%s' "$out" | jq -c ".[$i]")"
        port="$(printf '%s' "$entry" \
            | jq -r 'if (.port | type) == "number" then .port else empty end' 2>/dev/null)"
        if [[ -z "$port" ]]; then
            # 沒有可用埠的帳目：看得到，但它排不進埠序，也不能被當成任何結論。
            # 原樣貼出來。
            printf 'unparsed entry=%s\n' "$(sanitize "$entry")"
            UNSEEN=1
            T_UNPARSED=$((T_UNPARSED + 1))
            T_ROWS=$((T_ROWS + 1))
            continue
        fi
        row="row port=${port}"
        row="${row} provider=$(json_field "$entry" .provider)"
        row="${row} image=$(json_field "$entry" .image)"
        row="${row} container=$(json_field "$entry" .container)"
        keys+=("$(port_key "$port" "$row")")
        claim ledger "$port" "$(json_field "$entry" .container)" "$(json_field "$entry" .provider)"
        T_ROWS=$((T_ROWS + 1))
    done
    if [[ ${#keys[@]} -gt 0 ]]; then
        printf '%s\n' "${keys[@]}" | sort_rows_by_port
    fi

    tally
}

# ---- 視角 3/5：placeholders（Gateway 的 workers.d）--------------------
# 不用 pool-port-alloc --list：它會 mkdir -p 並建立／清空 .lock（檔頭第 1 條）。
# 用 ls -A1 加逐檔 cat。
view_placeholders() {
    printf '[placeholders] gateway workers.d\n'
    reset_tally

    if [[ "$GW_MASTER" -ne 1 ]]; then
        obs workers.d unobserved reason=gateway-unreachable
        tally
        return
    fi

    local out rcmd saw_dir line
    rcmd="d=\$HOME/.mylinuxpool/workers.d; rc=0"
    rcmd="${rcmd}; if [ -d \"\$d\" ]; then ls -A1 \"\$d\"; else printf '${NO_DIR}\n'; fi"
    rcmd="${rcmd}; printf '${SENT} %s##\\n' \"\$rc\""
    out="$(gw_run "$rcmd")"

    saw_dir=1
    printf '%s\n' "$out" | grep -qxF "$NO_DIR" && saw_dir=0
    if ! obs_decode "$out"; then
        obs workers.d unobserved "reason=${OBS_REASON}"
        tally
        return
    fi
    if [[ $saw_dir -eq 0 ]]; then
        # 目錄不在。provision-gateway 會重建它，所以「不存在」本身就可疑，但那
        # 跟「讀不到」是兩件事。
        obs workers.d absent reason=directory-missing
        tally
        return
    fi

    local names=() n_files
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        names+=("$line")
    done < <(obs_data "$out" | sort_rows)
    n_files="$(count_rows "${names[@]+${names[@]}}")"

    PLACEHOLDERS_SEEN=1
    obs workers.d observed "files=${n_files}"

    local i name port brcmd body payload row keys=()
    for (( i = 0; i < n_files; i++ )); do
        name="${names[$i]}"
        if [[ "$name" == .lock ]]; then
            # pool-port-alloc 的鎖檔，本來就該在那裡。印出來是為了讓「沒有
            # .lock」也看得見，但它不是殘骸，所以是 aux 不是 stray。
            printf 'aux file=%s what=pool-port-alloc-lock\n' "$name"
            continue
        fi
        if [[ ! "$name" =~ ^[0-9]+\.json$ ]]; then
            # workers.d 裡不該有的檔案。順帶一提：pool-port-alloc --list 遇到
            # 這種檔名會整個壞掉（jq group_by(.port) 拿到沒有 port 的檔）——
            # 那是另一個工具的問題，這裡只負責看見它。
            printf 'stray name=%s\n' "$(sanitize "$name")"
            T_STRAY=$((T_STRAY + 1))
            UNSEEN=1
            continue
        fi
        port="${name%.json}"

        # 路徑用 $HOME 展開；檔名已經過上面的白名單過濾（只有數字 .json），
        # 所以不會有任何 shell 文字插進來。
        brcmd="cat \"\$HOME/.mylinuxpool/workers.d/${name}\" 2>/dev/null"
        brcmd="${brcmd}; printf '${SENT} %s##\\n' \"\$?\""
        body="$(gw_run "$brcmd")"
        if ! obs_decode "$body"; then
            # 檔案在，但讀不到——那是「看到了一個讀不出來的東西」。
            keys+=("$(port_key "$port" "row port=${port} read=unobserved reason=${OBS_REASON}")")
            T_ROWS=$((T_ROWS + 1))
            T_UNREADABLE=$((T_UNREADABLE + 1))
            UNSEEN=1
            continue
        fi
        payload="$(obs_data "$body")"
        if ! printf '%s' "$payload" | jq empty >/dev/null 2>&1; then
            keys+=("$(port_key "$port" "row port=${port} read=unobserved reason=not-json")")
            T_ROWS=$((T_ROWS + 1))
            T_UNREADABLE=$((T_UNREADABLE + 1))
            UNSEEN=1
            continue
        fi
        row="row port=${port}"
        row="${row} provider=$(json_field "$payload" .provider)"
        row="${row} image=$(json_field "$payload" .image)"
        row="${row} container=$(json_field "$payload" .container)"
        row="${row} created_at=$(json_field "$payload" .created_at)"
        keys+=("$(port_key "$port" "$row")")
        claim placeholders "$port" "$(json_field "$payload" .container)" "$(json_field "$payload" .provider)"
        T_ROWS=$((T_ROWS + 1))
    done
    if [[ ${#keys[@]} -gt 0 ]]; then
        printf '%s\n' "${keys[@]}" | sort_rows_by_port
    fi

    tally
}

# ---- 視角 4/5：listeners（Gateway 的 ss）------------------------------
# 範圍來自 NODE_GATEWAY.ports.worker，不寫死 23xx（檔頭第 4 條）。range 印在
# obs 行上：埠段改動要在 diff 裡現形，否則兩份「一模一樣」的輸出其實在講不同
# 範圍。
view_listeners() {
    printf '[listeners] gateway ss\n'
    reset_tally

    if [[ "$GW_MASTER" -ne 1 ]]; then
        obs ss unobserved reason=gateway-unreachable
        tally
        return
    fi
    if [[ -z "$PORT_LO" || -z "$PORT_HI" ]]; then
        obs ss unobserved reason=port-range-unavailable
        tally
        return
    fi

    local out rcmd keys=() n=0 line state rest addr port peer
    rcmd="rc=0; if ! command -v ss >/dev/null 2>&1; then rc=127; else ss -Htln 2>/dev/null; rc=\$?; fi"
    rcmd="${rcmd}; printf '${SENT} %s##\\n' \"\$rc\""
    out="$(gw_run "$rcmd")"

    if ! obs_decode "$out"; then
        obs ss unobserved "reason=${OBS_REASON}"
        tally
        return
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # ss -Htln: STATE RECV-Q SEND-Q LOCAL:PORT PEER:PORT
        read -r state rest rest addr peer <<< "$line"
        [[ -n "$addr" ]] || continue
        port="${addr##*:}"
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        [[ "$port" -ge "$PORT_LO" && "$port" -le "$PORT_HI" ]] || continue
        keys+=("$(port_key "$port" "row port=${port} local=$(sanitize "$addr")")")
        # listeners 不知道容器是誰（也查不到是誰，見檔頭第 16 條），所以
        # container 欄留空。
        claim listeners "$port" "" ""
        n=$((n + 1))
    done < <(obs_data "$out")

    LISTENERS_SEEN=1
    obs ss observed "range=${PORT_LO}-${PORT_HI}" "listeners=${n}"
    T_ROWS=$((T_ROWS + n))
    if [[ ${#keys[@]} -gt 0 ]]; then
        printf '%s\n' "${keys[@]}" | sort_rows_by_port
    fi

    tally
}

# ---- 視角 5/5：state-cache（Gateway 的 state.json）--------------------
# 這是唯一一個「帳本已經對了、它還是錯的」藏身處：create-worker 推完快取才去
# 驗證可達性，而四個 failure() 步驟沒有重推（見檔頭）。讀取端無條件相信它
# （push-state/run.sh 檔頭），所以這一份比前四份加起來更值得看。
#
# 三件一定要分開的事：
#   * 讀不到（Gateway 掛／檔案不存在／權限不對）→ unobserved / absent
#   * 讀到了但 schema 不是 1 → unobserved reason=unknown-schema，**而且不讀
#     workers**。契約 §2 invariant 1 明講不認得的 schema 不可嘗試解讀；
#     pool-resolve 自己就是這樣守門的（pool-resolve:117-125）。
#   * 讀到了、schema 對、workers 是空陣列 → observed workers=0（真的空）
# 後兩種在畫面上差一個字，但意思是相反的。
view_state_cache() {
    printf '[state-cache] gateway %s\n' "$STATE_CACHE_PATH"
    reset_tally

    if [[ "$GW_MASTER" -ne 1 ]]; then
        obs state.json unobserved reason=gateway-unreachable
        tally
        return
    fi

    local out rcmd saw_file
    rcmd="rc=0; if [ -f '${STATE_CACHE_PATH}' ]; then cat '${STATE_CACHE_PATH}' 2>/dev/null; rc=\$?;"
    rcmd="${rcmd} else printf '${NO_FILE}\\n'; fi"
    rcmd="${rcmd}; printf '${SENT} %s##\\n' \"\$rc\""
    out="$(gw_run "$rcmd")"

    saw_file=1
    printf '%s\n' "$out" | grep -qxF "$NO_FILE" && saw_file=0
    if ! obs_decode "$out"; then
        obs state.json unobserved "reason=${OBS_REASON}"
        tally
        return
    fi
    if [[ $saw_file -eq 0 ]]; then
        obs state.json absent reason=file-missing
        tally
        return
    fi

    local body
    body="$(obs_data "$out")"
    if ! printf '%s' "$body" | jq empty >/dev/null 2>&1; then
        note "${STATE_CACHE_PATH} 不是合法 JSON"
        obs state.json unobserved reason=not-json
        tally
        return
    fi

    # schema 守門。值照印（人要看得見它變成什麼），但-workers 不讀。
    local schema
    schema="$(printf '%s' "$body" | jq -r 'if has("schema") then (.schema | tostring) else "missing" end' 2>/dev/null)"
    [[ -n "$schema" ]] || schema="unreadable"
    local serial source
    serial="$(json_field "$body" .serial)"
    source="$(sanitize "$(printf '%s' "$body" | jq -r '.source // empty' 2>/dev/null)")"
    [[ -n "$source" ]] || source="?"

    if [[ "$schema" != "1" ]]; then
        note "${STATE_CACHE_PATH} 的 schema=${schema}，不是契約認得的 1——不讀它的 workers（STATE_CONTRACT §2 invariant 1）"
        obs state.json unobserved "reason=unknown-schema" "schema=${schema}" "serial=${serial}" "source=${source}"
        tally
        return
    fi

    # workers 欄位本身要存在且是陣列。缺欄位不是「0 個 worker」。
    local wtype
    wtype="$(printf '%s' "$body" | jq -r 'if has("workers") then (.workers | type) else "missing" end' 2>/dev/null)"
    if [[ "$wtype" != "array" ]]; then
        note "${STATE_CACHE_PATH} 的 workers 欄位是 ${wtype}，不是陣列"
        obs state.json unobserved "reason=no-workers-array" "schema=${schema}" "serial=${serial}" "source=${source}"
        tally
        return
    fi

    # nodes 也一起印：同一個檔案、同一個「讀取端無條件相信」的理由，而一個
    # 已經 decommission 但仍在快取裡的節點，是同一類的殘骸。契約 §2 的節點鍵
    # 是連字號版，所以直接用。
    local nodes=() nnodes
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        nodes+=("row node=$(sanitize "$line")")
    done < <(printf '%s' "$body" | jq -r '(.nodes // {}) | keys[]' 2>/dev/null | sort_rows)
    # 引號不能省：節點列印出來是 "row node=fh-l"，含空白。不加引號的
    # ${arr[@]} 會被逐字切開，4 個節點被數成 8 個（實測）。
    nnodes="$(count_rows "${nodes[@]+${nodes[@]}}")"

    local count i entry port row keys=()
    count="$(printf '%s' "$body" | jq '.workers | length')"
    STATE_CACHE_SEEN=1
    obs state.json observed "schema=${schema}" "serial=${serial}" "source=${source}" \
        "nodes=${nnodes}" "workers=${count}"
    T_ROWS=$((T_ROWS + nnodes))

    for (( i = 0; i < count; i++ )); do
        entry="$(printf '%s' "$body" | jq -c ".workers[$i]")"
        port="$(printf '%s' "$entry" \
            | jq -r 'if (.port | type) == "number" then .port else empty end' 2>/dev/null)"
        if [[ -z "$port" ]]; then
            printf 'unparsed entry=%s\n' "$(sanitize "$entry")"
            UNSEEN=1
            T_UNPARSED=$((T_UNPARSED + 1))
            T_ROWS=$((T_ROWS + 1))
            continue
        fi
        row="row port=${port}"
        row="${row} provider=$(json_field "$entry" .provider)"
        row="${row} container=$(json_field "$entry" .container)"
        keys+=("$(port_key "$port" "$row")")
        claim state_cache "$port" "$(json_field "$entry" .container)" "$(json_field "$entry" .provider)"
        T_ROWS=$((T_ROWS + 1))
    done
    if [[ ${#keys[@]} -gt 0 ]]; then
        printf '%s\n' "${keys[@]}" | sort_rows_by_port
    fi
    if [[ ${#nodes[@]} -gt 0 ]]; then
        printf '%s\n' "${nodes[@]}" | sort_rows
    fi

    tally
}

# ---- 跨視角一致性（不是結論，是「哪幾邊看到」的地圖）--------------------
#
# 殘骸的定義是「視角之間不一致」，但**這支工具不判斷哪一種不一致是殘骸**：
# create 正在跑的時候，帳本已經寫了、容器還沒起來，那也是不一致，而且完全正常。
# 所以這裡只做兩件事：
#   1. 把同一個 port 在五邊各自說了什麼並排印出來（沒有出現的那邊印 `-`）
#   2. 任何一邊 unobserved／absent 時，明說這次比對不完整
#
# 為什麼第 2 點是硬要求：四邊一致而第五邊沒看到，**不等於乾淨**——那只是「四邊
# 一致」和「第五邊不明」兩件事共用了一個「沒問題」的印象。所以這節的 obs 分
# complete / incomplete，incomplete 時 missing= 逐一列出缺的那幾邊。標題行也把
# 「complete 不代表一致」寫死在那裡，因為那是整份輸出裡最容易被誤讀的一行。
#
# 這節**不改變結束碼**。結束碼的意義是「有沒有東西沒看到」，而「不一致」不是
# 「沒看到」——讓結束碼也管不一致，會讓「建立中」和「查不到」變成同一個值。
view_consistency() {
    printf '[consistency] 五邊對齊（result=complete 只代表五邊都觀測到，不代表它們一致）\n'
    reset_tally

    # 每一邊「有沒有看到」。subject 名用英文叢名，diff 才不會因為改名而全紅；
    # 中文留在 stderr 診斷上。
    local missing=() m n_seen=0
    if container_view_complete; then
        n_seen=$((n_seen + 1))
    else
        missing+=("containers")
    fi
    if [[ "${LEDGER_SEEN:-0}" == "1" ]]; then
        n_seen=$((n_seen + 1))
    else
        missing+=("ledger")
    fi
    if [[ "${PLACEHOLDERS_SEEN:-0}" == "1" ]]; then
        n_seen=$((n_seen + 1))
    else
        missing+=("placeholders")
    fi
    if [[ "${LISTENERS_SEEN:-0}" == "1" ]]; then
        n_seen=$((n_seen + 1))
    else
        missing+=("listeners")
    fi
    if [[ "${STATE_CACHE_SEEN:-0}" == "1" ]]; then
        n_seen=$((n_seen + 1))
    else
        missing+=("state-cache")
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        obs completeness complete "views=${n_seen}/5"
    else
        m="$(printf '%s\n' "${missing[@]}" | sort_rows | tr '\n' ',' | sed 's/,$//')"
        obs completeness incomplete "views=${n_seen}/5" "missing=${m}"
        note "有視角沒看到（${m}）——這次比對不完整；沒看到的那幾邊不能被當成「沒有殘骸」"
    fi

    # ---- block 1：一個 port 一行 ---------------------------------------------
    # port 是唯一能橫跨五邊的鍵。containers 視角不知道自己的埠（docker 不說）、
    # listeners 不知道容器是誰（要 root 才查得到 process，見檔頭第 16 條），
    # 所以那兩邊用反查接回來。
    # 埠是數值排序，所以排序鍵是補零的埠、去掉前綴之後仍然是埠本身。
    # （不要把排序鍵的內容丟掉再期待切完還拿得到埠——這裡踩過，結果是整個
    # block 1 印不出來，而 block 2 卻把每個容器都說成「沒人認領」。）
    local ports=() uniq=() rec v p i
    for rec in ${CLAIMS[@]+"${CLAIMS[@]}"}; do
        v="${rec%%	*}"; rec="${rec#*	}"
        p="${rec%%	*}"
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        ports+=("$(port_key "$p" "$p")")
    done
    if [[ ${#ports[@]} -gt 0 ]]; then
        while IFS= read -r p; do
            [[ -n "$p" ]] && uniq+=("$p")
        done < <(printf '%s\n' "${ports[@]}" | LC_ALL=C sort -u | cut -f2-)
    fi

    local port_view c_ledger c_ph c_sc c_list c_any c_res prov dup dupv
    for (( i = 0; i < ${#uniq[@]}; i++ )); do
        port_view="${uniq[$i]}"

        c_ledger="$(claim_lookup ledger "$port_view" container 2>/dev/null)" || c_ledger="-"
        c_ph="$(claim_lookup placeholders "$port_view" container 2>/dev/null)" || c_ph="-"
        c_sc="$(claim_lookup state_cache "$port_view" container 2>/dev/null)" || c_sc="-"
        if claim_has listeners "$port_view"; then
            c_list="yes"
        else
            c_list="-"
        fi

        # 契約上 port 是唯一鍵（STATE_CONTRACT §1）。同一個視角對同一個埠說了兩次
        # 是畸形，必須看見——默默挑一個等於刪掉一份證據。
        for dupv in ledger placeholders state_cache; do
            claim_lookup "$dupv" "$port_view" container >/dev/null 2>&1
            dup="$CLAIM_DUP"
            [[ "${dup:-0}" -gt 1 ]] || continue
            printf 'dup port=%s view=%s entries=%s\n' "$port_view" "$dupv" "$dup"
            UNSEEN=1
            T_UNPARSED=$((T_UNPARSED + 1))
        done

        prov="$(port_provider "$port_view")"
        c_any="$(port_container "$port_view")" || c_any="-"

        if [[ "$c_any" == "-" ]]; then
            # 沒有任何一邊說得出這個埠的容器名（只有 listener，或三邊都還沒記錄
            # container）。這不是「沒有容器」，是「沒人說得出名字」——所以是
            # unknown，不是 no。
            c_res="unknown"
        else
            c_res="$(container_view_result "$prov" "$c_any")"
        fi

        printf 'row port=%s ledger=%s placeholders=%s state_cache=%s listeners=%s container=%s containers=%s provider=%s\n' \
            "$port_view" "$c_ledger" "$c_ph" "$c_sc" "$c_list" "$c_any" "$c_res" "$prov"
        T_ROWS=$((T_ROWS + 1))
    done

    # ---- block 2：沒有任何埠認領的容器 ---------------------------------------
    # 這是反方向的殘骸：容器還在，但帳本／placeholder／快取都沒提到它（回滾刪過頭）。
    #
    # **只有在能認領埠的那三邊都觀測到時才印。** 帳本沒看到時，幾乎每個容器都會
    # 變成「沒有人認領」——那不是發現，是查不到。寧可少印一節，也不要印一節
    # 內容由未觀測狀態決定的東西。
    if [[ "${LEDGER_SEEN:-0}" == "1" && "${PLACEHOLDERS_SEEN:-0}" == "1" \
          && "${STATE_CACHE_SEEN:-0}" == "1" ]]; then
        local c cp claimed j
        for rec in ${CLAIMS[@]+"${CLAIMS[@]}"}; do
            v="${rec%%	*}"; rec="${rec#*	}"
            [[ "$v" == "containers" ]] || continue
            rec="${rec#*	}"
            c="${rec%%	*}"; cp="${rec#*	}"
            [[ -n "$c" ]] || continue
            claimed="no"
            for (( j = 0; j < ${#uniq[@]}; j++ )); do
                if [[ "$(port_container "${uniq[$j]}")" == "$c" ]]; then
                    claimed="yes"
                    break
                fi
            done
            [[ "$claimed" == "yes" ]] && continue
            printf 'row container=%s port=- provider=%s\n' "$c" "$cp"
            T_ROWS=$((T_ROWS + 1))
        done
    else
        printf 'suppressed what=unclaimed-containers reason=port-claiming-views-not-observed\n'
    fi

    tally
}

# ---- main -------------------------------------------------------------
# 這裡的順序有意義：先診斷再輸出，view 之間互相獨立。Gateway 掛掉時 ledger 與
# containers 仍然要交出來——全有全無的工具恰好在出事時最沒用。五個 view 全部
# 跑完才做 consistency：它吃的是五邊的結果，任何一邊沒跑就沒有東西可比。
main() {
    check_deps_and_args "${1:-}"

    resolve_gateway_state || true
    if [[ "$GW_MASTER" -eq 0 && "$GW_STATE" == "ok" ]]; then
        open_gateway_master_quiet || true
    fi

    enumerate_providers || true

    # run 行：這份快照是對誰拍的。diff 之前先看這行——Gateway 換過或埠段改過，兩份
    # 輸出就不可比，而內容量看起來會像「沒變」。state-cache 的 serial 必須配著
    # generation 一起看（rotate 之後 serial 會從 1 重新開始，見檔頭第 12 條）。
    printf '[run] gateway=%s generation=%s worker_ports=%s providers=%s\n' \
        "$GW_DESC" "$GW_GEN" \
        "$(if [[ -n "$PORT_LO" ]]; then printf '%s-%s' "$PORT_LO" "$PORT_HI"; else printf 'unknown'; fi)" \
        "$(if [[ "$PROV_ENUM" == "ok" ]]; then printf '%s' "${#PROVIDERS[@]}"; else printf 'unknown'; fi)"

    view_containers
    view_ledger
    view_placeholders
    view_listeners
    view_state_cache
    view_consistency

    [[ "$GW_MASTER" -eq 1 ]] && close_gateway_master

    # 結束碼 0 = 每個對象都觀測到；1 = 有東西沒看到（部分快照）。數的是「有沒有
    # 東西沒看到」，不是「池子乾不乾淨」，也**不是**「五邊有不一致」——不一致不
    # 調結束碼（見 view_consistency 的說明）。這支工具不對殘骸下結論，它只保證
    # 每一個它沒看到的對象都不會被讀成「看到了，是空的」。
    exit "$UNSEEN"
}

# 只在真的被執行時跑 main，被 source 時只定義函式。跟 ops-scripts/mlp 最底下
# 同一個形狀（mlp:2935），理由也一樣：這支工具的每一個行為都該能被一個密閉的
# 測試載入後單獨呼叫。**還沒有那樣的測試**——本次交付只有工具本身與一次真池
# 實跑（工單的交付清單就是這樣）。source 這支檔案時 ArgumentCheck 不會跑，所以
# 不會在別的腳本裡 exit。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
