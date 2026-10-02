## Context

調查報告在 `team/OUT-recon-capability.md`（程式碼）、`team/OUT-impl-recon-myaientry-caps.md`（MyAiEntry）、`team/OUT-test-recon-capability-tests.md`（測試）。重點：

- 形狀契約（`key: object`，空能力寫 `{}`，`null` 永遠不合法）、兩個驗證器（`worker-host` 與 `github`）、遷移器都已經存在，三台的 live var 也已經是新形狀（`docs/CAPABILITY-DESIGN.md`）。
- 能力鍵寫死在五處：`mlp` 兩處、`register-provider.sh` 兩處、`scripts/lib/profile.sh` 一處。驗證的分派點是 `mlp` 裡一個寫死的 `case`。
- `unit.json` 的 `provides` 寫的是**指令名稱**（例如 pool-runtime 寫 `pool-wol`、`pool-tunnel`），而且沒有任何程式讀它。
- pool-sync 只收斂「不需金鑰、不需 root」的單位，實際上只有 `pool-runtime`。
- `pool-wol` 由 `pool-runtime` 裝到每台 provider，**也裝在 Gateway**。
- `POOL_WORKERS` 的三筆都沒有 `capabilities` 欄位，也沒有任何 backfill。
- MyAiEntry 只用 `parseCapabilities()` 這一個地方解析能力，未知的鍵原樣保留；它實際只檢查 `worker-host` 與 `github`；不讀 `POOL_WORKERS[].capabilities`；`via` 一不見就會丟掉整個 `launch`。
- CI 只跑 `scripts/tests/`，`shared-configs/*/tests/` 從來沒被 CI 跑過（已補進 issue #13）。

## Goals / Non-Goals

**Goals：**
- 新增一個能力只要新增一個單位，再在 profile 列出它
- provider 的宣告永遠跟驗證結果一致
- worker 的宣告就是它的 profile

**Non-Goals：**
- 拿掉 `power.launch.via`（使用者決定保留它當叫醒順序）
- 回頭補寫現有 worker 的 `capabilities`：現有容器重建時才會補上
- `github` 的 `write`、`trigger-actions` 這些權限（沒有驗證方式，照設計不得使用）

## Decisions

**D1. 能力用一個新欄位 `capability` 對應到單位，不重新定義 `provides`。**
`unit.json` 新增 `"capability": "<鍵>"`。`provides` 照舊列指令名稱，兩者意思不同，不要混在一起。preflight 檢查每個鍵只由一個單位實作。

**D2. `--check` 的介面：參數以 JSON 經環境變數傳入。**
單位的 `install.sh --check` 從 `MLP_CAPABILITY_PARAMS` 讀 JSON 參數，例如 `{"repos":{...}}`。回傳 0 代表能力成立。有能力的單位，`--check` 的語意就是「能力成立」，不再只是「檔案是不是最新的」；需要比對內容的單位，兩件事都要檢查。

**D3. 共用 runner：`scripts/lib/capability.sh`。**
對外只有三個函式：
- `capability_plan <profile.json>`：從 profile 列出 `{鍵 → 單位、參數}`
- `capability_check <鍵> <參數>`：找到單位並跑它的 `--check`
- `capability_declaration <profile.json>`：對每個能力跑 check，組出宣告 JSON

pool-sync、register-provider、`mlp verify-capabilities`、create-worker 都只呼叫這三個。

**D4. pool-sync 的寫入照 `tunnel-key.sh` 的做法。**
讀出 `NODE_<NAME>`，只 merge `capabilities` 欄位，內容相同就不寫。寫入失敗只警告，不讓 tick 失敗。

**D5. 單位分工。**

| 單位 | 能力 | 誰安裝 | 參數 |
|---|---|---|---|
| `worker-host`（新） | `worker-host` | register-provider（要 root） | `{"runtime":"docker"}` |
| `gh` | `github` | register-provider（要 root） | `{"repos":{"FATESAIKOU/MyBrain":["read"]}}` |
| `wol`（新，從 `pool-runtime` 拆出 `pool-wol`） | `wol` | pool-sync（不要金鑰、不要 root） | `{"methods":["unicast"]}` |

provider 的 `default` 與 `no-sudo` 兩個 profile 都列這三個能力；Gateway 的 profile 不列 `wol` 單位。

**D6. `mlp wake`：`via` 決定順序，`wol` 決定資格。**
依 `via` 的順序，只嘗試宣告了 `wol` 的代送方。跳過的那一台照 `WAKE-VIA-DESIGN.md` 的輸出格式印出原因。四態與時間預算的邏輯都不動。

**D7. 拆掉 `pool-wol` 時的相容。**
過渡期間，有些 provider 的 pool-runtime 還是舊的，`pool-wol` 會同時存在兩處。新的 `wol` 單位要裝到同一個路徑（`~/.mylinuxpool/bin/pool-wol`），這樣兩者共存也不衝突；舊版 pool-runtime 收斂到新版之後，就不再裝 `pool-wol` 了。

## Risks / Trade-offs

- [`--check` 不穩，宣告就會來回跳，而 MyAiEntry 是照宣告挑機器的] → 驗證要做成可重現、不依賴網路短暫狀態；`github` 的驗證只打一次 API
- [fh-l 關機時，它的宣告停在上一次開機的值] → 使用者接受；已在 MyAiEntry#4 請 app 挑機器時先看在不在線
- [no-sudo 的 fh-proxy 能不能通過 `worker-host` 驗證，現在不知道] → 實作前先跑一次 `mlp verify-capabilities fh-proxy`（唯讀）。不過的話，它的宣告就會少 `worker-host`，承載機選單也會少這一台，要先告訴使用者
- [pool-sync 開始寫 `NODE_*.capabilities`，等於主本多了一個自動寫入者] → 只 merge 這個欄位，其他欄位不碰；寫入記一條 INFO

## Migration Plan

1. merge 後，provider 下一個 tick 收斂到新的 pool-runtime，並裝上 `wol` 單位；再下一個 tick 開始寫宣告。
2. 刪掉 `NODE_FH_PROXY.wol_sender`。這是對 live var 的變更，使用者在 issue #3 已經裁定，執行前再跟使用者確認一次。
3. 真機驗收：三台的 `capabilities` 收斂成預期的值；`mlp wake fh-l` 照常能用；停掉一台的 docker 再恢復，宣告會跟著消失、出現。
