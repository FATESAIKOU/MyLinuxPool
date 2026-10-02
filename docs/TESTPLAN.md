# 測試計畫

給人 review 用。分成三層：**純函式**（已存在、每次改動都跑）、
**整合**（跨元件，半自動）、**實機驗收**（人工觸發，驗真實行為）。

原則（`REDESIGN.md` N4）：**每個檢查都必須「有能力失敗」。**
新增任何一條，都要附一個證明它會失敗的案例。

---

## 1. 純函式測試（已實作，約 300 個斷言）

| 檔案 | 斷言 | 保護什麼 |
|---|---|---|
| `test-ledger.sh` | 75 | 帳本增刪、排序、去重、**回傳型別必為 array** |
| `test-state.sh` | 31 | state.json 組裝、serial 遞增、機密掃描、安裝片段可真的執行 |
| `test-install-state-cache.sh` | 34 + 18 injection | 快取寫入的原子性、schema 拒絕 |
| `test-pool-resolve-state.sh` | 29 | 三層讀取、快取鍵正規化 |
| `test-push-state.sh` | 29 | 推送前的組裝與驗證 |
| `test-ssh-admin-install.sh` | 15 | 不再佈署私鑰、既有私鑰不被刪、drift 回報 |
| `test-delete-worker.sh` | 9 | 兩種 worker 名稱寫法 |
| `test-pool-resolve.sh` | 13 | 跳板鏈展開 |
| `test-pool-sync.sh` | 112 | 收斂邏輯：GitHub 掛掉必須 exit 0、無變更不得重啟 tunnel、`needs_key` 的 unit 跳過、暫存目錄三種離開路徑都清、token 不入 argv 與 log、**跑完不新增任何檔案**；issue #7 加了「已發布零 dispatch／剛寫入恰好一次／dispatch 失敗只警告」（2026-10-02 實跑 112 條） |
| `test-tunnel-key-lib.sh` | 13 | 隧道金鑰的 mint／publish／ensure；issue #7 加了 `TUNNEL_KEY_CHANGED` 的「已一致＝0／剛寫入＝1／連呼兩次不殘留」與 `tunnel_key_mint` 顯式 `return 0` 的斷言（2026-10-02 實跑 13 條＋4 條注入） |
| `test-install-check.sh` | 20 + 3 injection | `pool-runtime` 的 `--check` 做的是**內容比對**而非存在性檢查（整個 pool-sync 設計的地基） |
| `test-register-provider-tempclone.sh` | 27 | 註冊後不留 `~/.mylinuxpool/repo`、舊的會被刪、`gh_token` 保留、暫存目錄失敗時也清 |
| `test-mlp-fwd.sh` | 83（含 19 注入） | `mlp fwd` 的四態健康檢測、bind 重疊判準、分層邊界、上色後的欄寬 |
| `test-wake-via.sh` | 29（含 19 注入，含 D6 的 16–26 整節：wol 資格篩選、略過佔序號、四態不降級、verify 的 via 回報） | `via` 清單的 fallback：觸發條件是機器有沒有真的醒、等待預算、「無法驗證」不得說成「沒醒」 |
| `test-register-provider-checks.sh` | 17（含 6 注入） | 登錄流程的三個宣告：埠、curl、docker 群組，各自都要有能失敗的檢查 |
| `test-capability-flags.sh` | 34 | 能力形狀契約（`key: object`、`{}` 不是 `null`、未知鍵保留）、遷移表、worker 的 github 禁令 |
| `test-capability-units.sh` | 40 + 9 injection | 三個能力單位的 `--check` 契約、三態、`MLP_CAPABILITY_PARAMS` 傳遞、`pool-wol` 位元組相同 |
| `test-capability-consumers.sh` | 13 + 2 injection | `mlp verify-capabilities` 用同一份單位的 `--check`；新增能力不必改 mlp |
| `test-capability-declare.sh` | 16 + 3 injection | pool-sync／register-provider 的宣告路徑：只 merge capabilities、零 dispatch、相同時零寫入、三態的 2 保留原值 |
| `test-install-replace-file.sh` | 10 + 2 injection | `install_file` 換檔取代原地覆寫，正在執行的舊版 process 不受影響（D10） |

執行：`FILE_CRYPTO_KEY=$(cat crypto_key) scripts/tests/<file>`

---

## 1.5 注入怎麼寫：分辨真紅與假紅

N4 說每個檢查都必須有能力失敗。**注入就是那個證明**：把修正拿掉，
看守衛會不會轉紅。這一節講的是這個證明本身也會說謊。

**紅燈不是證據，紅的原因才是。** 一條注入要能回答三個問題，
任何一個答不出來，就記成 harness 問題而不是計入通過。

### 一：針有沒有扎到，而且只扎到一處

不是「needle 存在」，是 **命中數剛好 1**。

命中 0 次是沒扎到，看得出來。命中 2 次看不出來，而且更糟：
2026-09-25 要改一個分類器的判斷行，替換命中的卻是上面一行內容相同的註解，
行為完全沒變、測試照樣全綠，差一點就把「這條守衛很弱」當成結論回報。
天然有兩處時，把 needle 加長到唯一為止。

### 二：突變版有沒有活著

`bash -n`（或對應語言的語法檢查）必須先過。語法錯誤造成的紅，
跟守衛咬住的紅長得一模一樣，而它是最常見的一種。

### 三：紅的形狀對不對

最容易被跳過的一條。斷言不能只看「有沒有紅」，要看**得到的具體值**
是不是這條注入所預期的那個錯誤，並且把它寫進輸出。

例：把喚醒的觸發條件改回結束碼，預期得到 `RC=0 SLEEPS=0`（短路、一次探測都沒做）。
若拿到的是空值或別的退出碼，那是 harness 爆了，不是守衛生效。

### 附帶：覆寫有沒有生效

用函式覆寫或 PATH stub 造夾具時，如果覆寫沒生效，量到的是 stub 自己而不是實作，
而結果一樣好看。夾具要自己證明有分辨力：斷言 `type <fn>` 是 function、
檢查事件記錄裡真的有那次呼叫的痕跡，並確認原版與突變版在同一夾具下給出**不同**的值。

### 摘要那一行也要遵守同一條規矩

2026-09-25：某個測試檔把注入失敗獨立計數、獨立回 exit 2（這是對的），
但最後印的是 `passed 13 / failed 0`。自動化看退出碼沒被騙，人看摘要被騙了——
而人就是會看摘要，也是人在決定要不要出貨。

**摘要那一行在 harness 壞掉時，給出了跟全綠一樣的答案。**
這正是這整套測試存在要防的事，只是掉頭咬了測試自己。

一句話：**假綠是「壞了但沒紅」，假紅是「紅了但不是因為壞」。**
前者靠注入擋，後者靠上面三問擋。只做前者，會得到一整套看起來很兇、
其實在量自己有沒有跑的護欄。

---

## 1.6 掃描式檢查的界線：它守不住什麼

2026-09-25 修「stdout 即回傳值的函式不得在 stdout 印字」時，寫了一支掃描器找
同型地雷，判準是**「函式被 `="$(fn)"` 捕捉、且函式體內有不帶 `>&2` 的 `log INFO`」**。
它找到兩個真地雷。然後獨立審查發現這個判準有三個結構性盲點。

寫在這裡不是為了修判準，是因為**下一個人會以為「掃過就沒事了」**。

### 盲點一：只認 `$( )`，漏掉重導型的捕捉

`scripts/delete-worker.sh` 的 `delete_worker_find_claim` 被 workflow 以
`delete_worker_find_claim ... >> "$GITHUB_OUTPUT"` 呼叫——**stdout 直接就是
Actions 的 output**，但這不是 `$(...)`，掃描器不會看它。

它現在安全**只因為剛好只用 `log ERROR`**（走 stderr）。而 `>> $GITHUB_OUTPUT`
正是這個 repo workflow 的主要輸出慣例，所以下一顆地雷落在這個形式上的機率最高。

### 盲點二：只認 `log`，漏掉直接的 `echo` / `printf`

判準找的是 `log INFO`。有人在同樣位置寫 `echo "waiting…"` 就完全看不到。

而且這裡有一個**純文字掃描做不到的判斷**：同一個函式裡的 `printf` 可能是
「組出回傳值」（正確）也可能是「印訊息」（污染），兩者長得一樣。
要分辨必須理解語意。

### 盲點三：只看函式自身，漏掉被呼叫的子函式

`A` 被捕捉、`A` 呼叫 `B`、`B` 印在 stdout —— `A` 的回傳值一樣被污染。
目前生產碼沒有這種實例，但判準結構上看不到。

另外：判準只掃 shell 檔，而**捕捉點常常住在 workflow YAML 內嵌的 bash 裡**。

### 所以這類檢查不進 preflight

`preflight` 的立場是**沒有排除清單**（見該檔）。這個判準會誤抓合法的例外
（例如 `rotate_wait_for_cloud_init` 刻意在 stdout 印字，因為呼叫端只取尾行），
而要讓它常設就得維護一張排除清單——那正是 preflight 拒絕的東西。

替代做法是**逐實例以行為測試釘住**（`test-rotate-stdout-contract.sh` 是模板）：
新增一個「stdout 即回傳值」的函式時，當場補一條同型斷言。

代價要講清楚：**這意味著掃描判準不會守未來的新地雷，只有已列的行為測試會守。**
這是刻意接受的，不是疏忽。

### 1.6b 替代做法：把「生產觸發條件」寫在分支旁邊

掃描與覆蓋率都守不住的另一類，是**從未被執行過的分支**。2026-09-25 的三個嚴重
缺陷全落在這種分支上，最典型的是 `rotate-gateway.sh` 的
`if [[ -n "${GATEWAY_ROOT_PASS:-}" ]]`——它在 repo 裡躺了很久，直到使用者第一次
設 `GATEWAY_ROOT_PASSWORD` 那個 secret 才第一次執行，而它裡面就有一顆 stdout
污染地雷。

**為什麼覆蓋率工具解決不了這件事**（qa 實測結論）：覆蓋率量的是「這一行在測試
中有沒有被執行」。測試可以直接呼叫函式、硬塞參數，把那個 `if` 的兩條分支都走過
一次，於是那幾行變綠——但**生產的呼叫者**（那個 workflow step）從來沒有送出過
讓它成立的那組參數。問題不在行覆蓋率，而在**呼叫圖 × 參數域**：誰在生產裡呼叫
它、帶著哪些值。行覆蓋率對這個維度全盲，而測試自己造出的參數會給出假安心。

替代做法是**在分支旁邊寫下它的生產觸發條件**，兩種形狀：

```
# 生產觸發條件：目前無人觸發（<哪個條件不成立>）
# 生產觸發條件：目前 100% 走此路；<某條件成立> 後應歸零
```

**第二種（退場條件）比第一種好**，因為它把「這條分支什麼時候會該消失」寫在
分支旁邊，而不是收在一份歸檔的設計文件裡。第一種只說了「現在沒人走」，讀者
仍要自己去追那個條件會不會變；第二種直接給出**觀察點**——當某條件成立，這裡
就該歸零，於是它變成一個可被檢查的承諾，而不是一句背景說明。

寫的紀律與 §1.6 同：**只寫你有把握的**。寫不出「誰觸發」就代表你不確定，那就不
要寫——一句猜錯的觸發條件比沒有更糟，它會讓下一個人以為自己懂了。

---

## 1.7 值域不夠用：兩種狀態，一個位置

2026-09-25 一晚連修五處同型缺陷，每一處當時都被當成獨立事件。它們是同一個形狀，
而那個形狀原本只存在於對話裡，不在 repo。

**形狀**：有兩種狀態需要被表達，但表示法只有**一個位置**。於是兩種狀態共用一個
值，下游拿那個值去做決定，兩種狀態走同一條路，其中一條走錯。

**為什麼看不見**：共用值本身是**合法**的——`""` 是「這個 workflow 還沒有任何
run」的正當基準，`down` 是「機器關著」的正當狀態。檢查的時候不會停在那個值上
（它沒壞），會往流程去找。所以它總是被燙到才修：事前沒徵兆，事後看又很明顯。

### 事前可以問的問題

現象（「兩種情況得到同一個答案」）要人先注意到兩種情況**會撞在一起**——而想像
失敗情境是難的，而且會漏。原因（「表示法容量不夠」）只要看下面這個問題：

> **對著每個值問：拿到這個值的人要做什麼？**

兩種狀態的**下一步不同**，就不能共用一個值。
**下一步真的一樣**，共用是對的壓縮，不是缺陷。

這個問法不需要想像兩種狀態怎麼撞在一起；它只看**這個值的消費端要做什麼決定**，
那是當下就看得到的東西。本 repo 的例子：

- 「沒在聽」的下一步是去修服務，「沒去探」的下一步是去修探測 → 不同 → 必須分開
- 「確實沒有新 run」的下一步是報失敗，「讀不到清單」的下一步是叫人自己去看
  → 不同 → 必須分開

### 五個實例（全部已修，位置已逐一到碼裡核對）

| 撞在一起的兩種狀態 | 原本的共用值 | 現在怎麼分開 |
|---|---|---|
| 「確認沒在聽」/「根本沒探到」 | `down` | `gw_probe_port`（`ops-scripts/mlp:355-368`）分 `down`（:367）/ `inconclusive`（:361） |
| 「確實沒有新 run」/「讀不到清單」 | `die "the run never appeared"` | `wf_dispatch`（`ops-scripts/mlp:1404-1419`）rc 3（:1417）/ rc 1（:1419） |
| 「基準是空的」/「基準讀不到」 | `""` | `wf_dispatch`（`ops-scripts/mlp:1325-1341`）`baseline_ok` |
| 「探不到路由」/「被防火牆丟包」 | 一個 timeout | `fwd_probe`（`ops-scripts/mlp:2062-2073`）的 `inconclusive`（:2068）對 `unreachable`（:2072） |
| 「驗過且通過」/「宣告畸形、根本沒觀察到」 | `pass` | `cap_verify_worker_host`（`ops-scripts/mlp:2519`）與 `cap_verify_github`（:2564）初始值 `unverifiable` |

> 核對更正（兩處）：
> 第 4 列原記成 `gw_probe_port`，但那支分的是第 1 列的兩態；「探不到路由」/
> 「被防火牆丟包」是 `fwd_probe` 的目標段（`mlp fwd ls` 的 TSTATE `inconclusive`
> 對 `unreachable`）。兩者是同一形狀的兩個不同實例，原表把它們混成一列。
> 第 5 列的兩態原文「沒宣告能力」/「宣告解析不了」與碼裡實際的兩態不符：實際共用
> `pass` 的是「驗過且通過」與「宣告畸形導致迴圈根本沒跑到、什麼都沒觀察到」
> （qa 2026-09-25：`{"repos":"o/r"}` 等畸形值讓 jq 失敗、`while` 零圈，初始的
> `pass` 就漏了出去，回報 ok + exit 0）；初始值確實是 `unverifiable`，函式名是
> `cap_verify_worker_host` 與 `cap_verify_github`。

### 界線

這一節不是說每個值都要拆三態。判準就是上面那句：**拿到這個值的人下一步不同**，
才必須分開；下一步相同時合併是對的壓縮。無差別地三態化只會讓每個消費端都得處理
三條路，那才是缺陷。

---

## 2. 整合測試（提案，尚未實作）

這些跨元件但不需要真機，可以在 CI 跑。

### I1 主本 → 快取 → 邊緣，端到端一致

給定一組假的 `NODE_*` 與 `POOL_WORKERS`，
`state_build` → `state_validate` → `install_state_cache` → `state_file_lookup`
取回的節點內容必須與輸入**逐欄相同**。

> 保護的是：中途任何一層改了格式（例如鍵名轉換寫錯），
> 目前只會在真機上才發現。

**失敗案例**：把 `state_build` 的鍵名改成底線，這條必須紅。

### I2 帳本主本與 Gateway 快取不會分歧

模擬 create → delete → create 的序列，每一步之後
`POOL_WORKERS` 的埠集合必須等於 `workers.d/*.json` 的埠集合。

**失敗案例**：讓 delete 只清其中一邊，必須紅。

### I3 rotate 的還原路徑

給一份含 N 筆 worker 的 `state.json`，跑還原邏輯，
`workers.d/` 必須剛好有 N 個檔案且埠一一對應。

**失敗案例**：state.json 裡有兩筆同埠（不該發生但要防），
還原後不得產生重複或遺漏。

---

## 3. 實機驗收（人工觸發）

| # | 情境 | 判準 | 現況 |
|---|---|---|---|
| V1 | 穩態不打 GitHub | provider 在 `GH_TOKEN` 為空時仍解析得出節點 | ✅ 已驗 |
| V2 | rotate 後新機器有正確快取 | `state.json` 的 serial/source 正確、`workers.d` 由主本還原 | ✅ 已驗（gen 9） |
| V3 | fh-l 關機時 rotate | 成功；醒來後自己接上新 Gateway | ✅ 已驗 |
| V4 | Gateway 不可用 | 節點退回問 GitHub 並重連 | ✅ 已驗（rotate 過程） |
| V5 | **GitHub 不可用** | 已連線節點不受影響；快取仍可服務 | ❌ **從未測過** |
| V6 | 實體斷網 | 約 60 秒回收殭屍埠，恢復 | ✅ 已驗 |
| V7 | worker 跟隨 rotate | 容器 ID 不變 | ✅ 已驗 |
| V8 | `verify-profile` 三台 matches | 比對內容而非存在 | ✅ 已驗 |
| V9 | **零狀態自癒** | 刪光衍生物，50 秒內全部回來 | ✅ 已驗（兩台） |
| V10 | **worker 跟隨檔遺失** | 刪掉 `gateway/gateway.json`，worker 仍能在下次 rotate 跟上 | ⚠️ 部分——檔案本身已驗會自癒（V9），但「遺失後仍跟得上 rotate」未單獨驗 |
| V11 | **主本與實際分歧** | `mlp state` 能看出差異 | ✅ 已驗——第一次跑就抓到我 Mac 上一份 serial 99 的假快取 |
| V12 | **rotate 與 provider 離線同時發生** | 兩台都有 worker；rotate 途中關掉 fh-l 再喚醒 | ✅ 已驗（見下） |
| V13 | **provider 宣告漂移自癒** | 竄改 `bin/pool-status` 後 `pool-sync` 把它修回來；無漂移時不重啟 tunnel | ✅ 已驗——兩台各 17/17 |
| V14 | **provider 不再留常駐 clone** | 部署後 `~/.mylinuxpool/` 無 `repo/`，且推導不出的資訊只剩 `config` + `gh_token` | ✅ 已驗——8.2 MB → 只剩衍生物；推 master 後兩台各自收斂到新的 unit 檔 |
| V15 | **rotate 後 provider 狀態仍最小** | rotate 到 generation 11 之後，`~/.mylinuxpool/` 仍無 `repo/`，`pool-sync` 仍正常，worker 原地存活 | ✅ 已驗——fh-proxy 17/17；容器 `1bfa9e46f8ac` 未重建；`mlp state` consistent |
| V16 | **完整生命週期序列** | fh-l 起 worker → fh-l 關機 → Gateway rotate → fh-l 開機，全程 fh-proxy 帶著自己的 worker | ✅ 已驗兩次（generation 12→13、13→14）——見下 |

### V12 實測（2026-09-14，generation 9 → 10）

```
15:45:53  rotate 開始
15:47:58  fh-l 關機（rotate 在 step 6-7）
15:51:09  rotate 判定 fh-l not attached，只 probe fh-proxy、只等 2226
          restored 2 claim(s) ← 含離線 fh-l 的 2300，位子保留
15:52:03  fh-proxy 的 worker 1 秒內切到 generation 10
15:52:46  送 WoL
15:54:47  fh-l 的 worker 開機後直接接上 generation 10
15:55:00  fh-l 完全上線
```

容器 ID 前後不變（`abec2ea3eddd` / `1bfa9e46f8ac`）——**fh-l 整機斷電再開，
同一個容器回來**。`mlp state` 事後回報三處一致。

這一輪也暴露了兩個缺陷：`mlp wake`/`mlp down` 因為 `local node="$1"` 在
`set -u` 下炸掉（盲寫測試只測純函式、沒測進入點），以及我把
`systemctl reboot` 的失敗當成成功——fh-l 的 sudoers 只允許 `poweroff`。

### V5 怎麼做（建議）

在 provider 上把 `api.github.com` 指到黑洞，或暫時把 `gh_token` 改壞：

```bash
# 在 provider 上
mv ~/.mylinuxpool/gh_token{,.bak}
# 等 60 秒，隧道必須仍然 active，pool-resolve 仍解析得出節點
mv ~/.mylinuxpool/gh_token{.bak,}
```

判準：隧道不中斷、`pool-resolve fh-l` 仍有輸出（來自 state.json）。
**Gateway 本身解析不出來是預期的**（那是循環依賴的例外，必須走 GitHub）。

### V11 為什麼重要

今天發生過一次：2300 那個 worker 建立於帳本主本化之前，不在 `POOL_WORKERS` 裡。
如果當時直接 rotate，它會安靜消失。我是在接線前手動比對才發現的。
**這種分歧不會有任何錯誤訊息**，所以需要一條主動檢查。

建議做成 `mlp state --check`：比對主本、Gateway 快取、各 provider 的本機快取，
列出三者的差異。這也正好是 B3 的內容。

---

## 4. 尚未實作的東西

| | 狀態 |
|---|---|
| B3 `mlp state` | 未做——顯示主本與快取的差異，也是 V11 的工具 |
| I1–I3 整合測試 | 未做 |
| V5 / V10 / V11 | 未測 |
| issue #7 的紅燈測試 | 未做——`TUNNEL_KEY_CHANGED` 的兩次斷言＋注入、`test-pool-sync.sh` 的「已一致時不得有 `gh workflow run`」與「有 dispatch 要收緊成恰好一筆」、dispatch 失敗的新案例（**`FAKE_GH_MODE=dispatchfail`，不能用 `writefail`**——後者連 `variable set` 一起失敗，`tunnel_key_publish` 會先 return 1，走不到 dispatch 那一步）、以及 `refresh-authorized-keys.yml` 的每日排程：**行為測試**（`test-refresh-attribution.sh` 新增一個情境——一筆排程 run ＋ 我們自己那筆，必須仍然認出我們的）＋**回歸護欄**（**仍然**沒有任何 step 讀 `inputs.*`；排程 run 的 `run-name` nonce 是空的，靜態標題不可能被 `contains()` 認領）。實作與實機驗收都要在這些斷言之後 |

---

## V16 完整生命週期序列（2026-09-16）

一次跑完四步，中間不介入。跑了兩次：第一次暴露一個缺陷，修掉後重跑。

| 步驟 | 結果 |
|---|---|
| fh-l 起 worker | ✅ 配到未使用的埠（第二次跑時 fh-l 已有 2301，正確配到 2302） |
| fh-l 關機 | ✅ 用 fh-proxy ping 區網位址確認真的斷電，不是只看隧道消失 |
| Gateway rotate | ✅ 零回滾。`Run provision-gateway.sh` 這一步正是新的 stdin 傳金鑰路徑 |
| fh-l 開機 | ✅ WoL 後 45–50 秒回來，**自己**解析到新 Gateway（它關機時還是舊 generation） |

**第一次跑暴露的缺陷**：rotate 之後 `mlp status` 把健康的 Gateway 報成
`FAIL: REMOTE HOST IDENTIFICATION HAS CHANGED`。根因是 `pool-status` 釘的是
`~/.mylinuxpool/gateway_known_hosts`——那個檔在 provider 上由 `pool-tunnel`
每 30 秒重寫，但操作者機器上沒有 pool-tunnel，所以它從某次 rotate 之後就凍結。
Linode 又把 generation 11 用過的位址發給了 13，於是「同一個 IP、不同 host key」
直接引爆。改成從 `NODE_GATEWAY.host_key`（宣告）寫暫存 pin。

> 教訓：**衍生檔不該成為讀取「它所衍生自的宣告」的前提。** 兩個檔兩個維護者，
> 而其中一個維護者只存在於某一類機器上——這種不對稱只會在那類機器以外的地方爆。

**一個容易誤判的觀察**：fh-l 開機後 `mlp ls` 一度顯示它的兩個 worker 是 `down`。
那是時間差——容器有 `--restart unless-stopped`，docker 已經把它們拉起來了
（`Up 29 seconds`），只是反向隧道還沒建好。20 秒後全部 `up`。
`mlp ls` 的 `up/down` 讀的是 Gateway 上有沒有 listener，會落後容器啟動。
