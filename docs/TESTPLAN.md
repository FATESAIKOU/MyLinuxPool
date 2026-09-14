# 測試計畫

給人 review 用。分成三層：**純函式**（已存在、每次改動都跑）、
**整合**（跨元件，半自動）、**實機驗收**（人工觸發，驗真實行為）。

原則（`REDESIGN.md` N4）：**每個檢查都必須「有能力失敗」。**
新增任何一條，都要附一個證明它會失敗的案例。

---

## 1. 純函式測試（已實作，230 個斷言）

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

執行：`FILE_CRYPTO_KEY=$(cat crypto_key) scripts/tests/<file>`

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
| V10 | **worker 跟隨檔遺失** | 刪掉 `gateway/gateway.json`，worker 仍能在下次 rotate 跟上 | ❌ 未測 |
| V11 | **主本與實際分歧** | 手動讓 `POOL_WORKERS` 少一筆，rotate 後該 worker 不應被靜默丟棄 | ❌ 未測 |

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
