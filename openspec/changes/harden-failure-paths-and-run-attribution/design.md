## Context

動機見 proposal.md 的 Why，行為要求見 `specs/`。這裡只記影響做法的現況與限制：

- delete-worker 的步驟依序是：S5 刪容器 → S6 釋放埠佔位 → S7 刪帳本（`POOL_WORKERS`）→ S8 refresh → S9／S10 推 state cache，全程沒有 `if: failure()`。**尋找 worker 只讀 Gateway 上的佔位**（`pool-port-alloc --list`），不讀帳本。
- `dispatch_refresh_and_wait`（`scripts/lib/refresh-wait.sh`）有三個呼叫端：`register-client`（非 0 → WARN）、`register-provider`（非 0 → abort），以及 create／delete workflow 內的 refresh。舊實作用 `gh run list --limit 1` 取最新一筆。
- 本機是 macOS bash 3.2，CI 是 ubuntu bash 5.x，兩邊都要能跑。preflight（`ops-scripts/preflight`）會把 `run:` 區塊裡看起來像函式呼叫的字眼，當成「沒 source 就呼叫」來報錯。
- 團隊分工：impl 寫程式、test 寫守衛、review 獨立驗收；commit 由 PM 做。工單與報告在 PM 的 scratchpad（本 change 是它們的持久摘要）。

## Goals / Non-Goals

**Goals:**
- 失敗時的說明可以照做，而且說明本身不可能失敗
- 歸屬判斷寧可「認不出、報失敗」，也不要假綠

**Non-Goals（使用者裁示不做）：**
- delete-worker 其餘三個失敗點（S7／S8／S9–10）的補救；rotate 回滾時自己寫變數失敗的補救
- 失敗補救（重推 state cache、重刷 key）的真機驗證（A3）
- `per_page` 翻頁、`wf_follow` 無上限迴圈（C4）；統一結束碼、失敗時上傳 log（F2 的 R2／R3）
- 修改 MyAiEntry（另一個 repo，由它自己的團隊負責）

## Decisions

**D1. delete-worker 只加說明，不加自動補救。**
只重試 S6 會清掉佔位，但帳本、key、快取還在。因為尋找 worker 只讀佔位，原本重跑就能全癒的情況，會變成要手動改帳本。完整補救要複刻 S7–S10（其中包含 S6 當時還不存在的 Gateway outputs），等於侵入被裁示為已知限制的三個失敗點。這個情況的歷史頻率是 0／46，影響範圍是 100 個埠中的 1 個，自動化的風險大於收益。
替代方案：`if: failure()` 重試 S6（否決，理由如上）；全尾補救（否決，範圍與風險過大）。

**D2. 說明分三岔，以 S6 的 `outcome` 判斷死在哪一段。**
S6 加上 `id: release`，說明步驟以 `steps.release.outcome` 區分「寫入前死／S6 死／S6 之後死」。說明步驟只 echo，同時寫 log 與 `$GITHUB_STEP_SUMMARY`（舊版的 Summary 步驟在失敗時會被跳過）。
手動配方裡的函式名不放在 preflight 會當成「命令位置」的地方，以免被誤判成未 source 的呼叫；不為了滿足檢查器去加 `source`，因為那會讓保證不會失敗的步驟多出一個失敗模式。

**D3. 關聯值走 `run-name:` 加選填輸入，四支 workflow 用同一套機制。**
`rotate-gateway` 既有的輸入只有 `dry_run`，不唯一，所以一定要有專用的關聯輸入。nonce 取自 `/dev/urandom`（16 hex）；缺 urandom 時才退回低熵格式，並在註解寫明。比對在 `gh` 自己的 `--jq` 裡做，不多依賴本地 jq。nonce 的字元集是 `[0-9a-f-]`，內插進 `--jq` 字串是安全的。
替代方案：用時間戳（否決，同秒會撞）；沿用既有輸入（否決，不唯一）；REST `dispatches` 取 run id（API 不回傳）。

**D4. 列表一次看 50 筆，超出就「認不出」。**
外部 refresh 約 10 分鐘一次，300 秒的窗內約 30 筆。超出窗時安全地回非 0，代價是可用性，不是正確性。分頁不做。

**D5. 真機驗證是成敗的分水嶺。**
`run-name` 內插 `inputs.*` 之後會不會出現在 `displayTitle`，離線測不到。先用無害的 refresh 驗；不過就 revert 並停下，不繞路。D2b 的三支也都要真跑（使用者核准，含 rotate）。rotate 之後用 `linode-cli` 確認沒有殘留計費中的 preview。

## Risks / Trade-offs

- [`run-name` 在 GitHub 上不展開] → 每次都「認不出」，register 和 create 會報失敗（方向正確但不能用）→ 以 D5 的真機驗證立刻發現，revert
- [`run-name` 改變 run 的顯示標題，MyAiEntry 若依賴標題會壞] → D2b 開工前先盤點跨 repo 契約；只能改 MyAiEntry 才不壞的話就停，交給使用者決定
- [失敗說明從未在真實失敗上跑過（S6 的歷史失敗次數是 0）] → 以靜態覆蓋測試證明它會跑，並加上順序斷言，防止說明步驟被挪到 S6 之前
- [測試只釘住關鍵字，分不出是哪個步驟印的] → 刻意構造的 decoy 可以騙過；已記在測試檔頭的限制段，不修
- [外部 refresh 在 300 秒內超過 50 筆] → 認不出，回非 0；以目前的量測有餘量，但沒有保證
- [rotate 真跑失敗，Gateway 壞掉或留下計費中的 preview] → 照 RUNBOOK 處理並用 `linode-cli` 查核；救不回就停手，等使用者

## Migration Plan

每一批單獨 commit，CI 綠之後再進下一批：C3 → D2a → D2a 真機驗證 → D2b → D2b 真機驗證。
回滾：每批都是可以單獨 `git revert` 的 commit；新輸入都是選填，revert 之後外部呼叫端不受影響。

## Open Questions

- D2b 對 MyAiEntry 的影響（盤點中，`OUT-client-impact.md`）。結果依使用者裁示的規則處理：不受影響或能在本 repo 做成相容 → 照做；只能改 MyAiEntry → 停。
