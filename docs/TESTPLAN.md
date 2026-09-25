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
| `test-pool-sync.sh` | 47 | 收斂邏輯：GitHub 掛掉必須 exit 0、無變更不得重啟 tunnel、`needs_key` 的 unit 跳過、暫存目錄三種離開路徑都清、token 不入 argv 與 log、**跑完不新增任何檔案** |
| `test-install-check.sh` | 18 + 3 injection | `pool-runtime` 的 `--check` 做的是**內容比對**而非存在性檢查（整個 pool-sync 設計的地基） |
| `test-register-provider-tempclone.sh` | 9 | 註冊後不留 `~/.mylinuxpool/repo`、舊的會被刪、`gh_token` 保留、暫存目錄失敗時也清 |
| `test-mlp-fwd.sh` | 68（含 13 注入） | `mlp fwd` 的四態健康檢測、bind 重疊判準、分層邊界、上色後的欄寬 |
| `test-wake-via.sh` | 20（含 11 注入） | `via` 清單的 fallback：觸發條件是機器有沒有真的醒、等待預算、「無法驗證」不得說成「沒醒」 |
| `test-register-provider-checks.sh` | 17（含 6 注入） | 登錄流程的三個宣告：埠、curl、docker 群組，各自都要有能失敗的檢查 |

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
