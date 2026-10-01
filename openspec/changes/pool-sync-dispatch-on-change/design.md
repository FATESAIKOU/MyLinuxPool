## Context

調查報告：PM scratchpad `team/OUT-recon-issue7.md`（2026-10-02，唯讀，附 `檔案:行號`）。重點：

- `tunnel_key_publish` 的「已一致」（`scripts/lib/tunnel-key.sh:89-92`）與「剛寫入」（`:102`）兩條路都回 0；`tunnel_key_ensure_published` 回的就是 publish 的回傳碼。
- 只有兩個生產呼叫端：`pool-sync:372-378`（回 0 就 dispatch）與 `register-provider.sh:670`（非 0 就 `exit 1`）。
- `tunnel_key_mint` 沒有顯式的 `return 0`，靠最後一個 `if` 陳述式回 0。在它後面加任何一行，都會悄悄改掉它的回傳值。
- `pool-sync:19-22` 明寫「不保存狀態、不建立新檔案」，`test-pool-sync.sh` 的 `check_no_new_state` 釘著這條。
- `refresh-wait.sh` 靠 run 的 displayTitle（`run-name` 裡帶 nonce）認出自己 dispatch 的那一次。
- 其他會 dispatch refresh 的地方都只在有人主動操作時才跑，其中三個是硬失敗（register-provider、create-worker、delete-worker）。
- provider 每個 tick 都從 master 的新 clone source `tunnel-key.sh`，同一個 tick 也收斂 pool-runtime。

## Goals / Non-Goals

**Goals：** 金鑰沒變就不 dispatch；新金鑰仍會觸發一次 refresh；其餘漂移由每日排程收斂。

**Non-Goals（使用者決定或刻意不做）：**
- 失敗重試標記（`refresh-pending`）：不做，pool-sync 維持不保存狀態，dispatch 失敗交給每日排程
- `concurrency` group：不加
- 改 `register-provider.sh` 的 dispatch：不動。重複註冊時，Gateway 上可能根本還沒有那把金鑰（例如先前的 refresh 失敗過）；如果跳過 dispatch，step 9 的驗證就永遠過不了。它的等待正是 step 9 的前提

## Decisions

**D1. 用輸出變數回報有沒有寫入，不改回傳碼。**
`tunnel_key_publish` 進門把 `TUNNEL_KEY_CHANGED` 設為 0，真的寫入成功後才設為 1；`tunnel_key_ensure_published` 透傳。回傳碼照舊。如果改成用回傳碼區分，`register-provider.sh:670` 碰到「已一致」會 `exit 1`，pool-sync 每個 tick 也會印一條假的 `tunnel key convergence failed`。`tunnel_key_mint` 同時補上顯式的 `return 0`。

**D2. pool-sync 只在 `TUNNEL_KEY_CHANGED=1` 時 dispatch。**
dispatch 失敗時記警告並註明「會由每日排程收斂」，tick 本身不失敗，也不寫任何檔案。

**D3. 每日排程 `cron: "0 20 * * *"`（UTC），加在 `workflow_dispatch` 旁邊。**
排程 run 沒有 dispatch input，`inputs.nonce` 求值為空字串。`refresh-wait.sh` 只認 16 位十六進位的 nonce，所以排程 run 不會被誤認（`team/OUT-review-issue7-schedule-title.md`：用 `refresh-wait.sh:127` 原樣的比對邏輯，跑 10 個合成視窗驗過）。這個檔案裡沒有任何 step 讀 `inputs.*`。
另外做兩項強化：
- `run-name` 改成 `refresh-authorized-keys ${{ github.event_name }} ${{ inputs.nonce }}`，排程 run 在標題上就看得出來（驗收 3.3 用得到）
- 在 `run-name` 旁加註解：它是 `refresh-wait.sh` 認 run 的依據，不能刪，也不能只剩空白（只剩空白時 GitHub 會改用事件資訊當標題）；`on:` 底下必須保留 `workflow_dispatch`，因為 `inputs` 依賴它

**D4. 一次上線，不拆兩個 PR。**
同一個 tick 裡，provider 從同一份 clone 拿到新的 lib，並收斂 pool-runtime，但這個 tick 執行的仍是舊版 pool-sync：舊版不讀 `TUNNEL_KEY_CHANGED`，照舊 dispatch，行為跟現在一樣。下一個 tick 才執行新邏輯。中間的混合狀態最多多派一次 refresh，所以不需要拆成兩個 PR。

## Risks / Trade-offs

- [D2 條件寫錯，會讓「金鑰第一次產生」時不 dispatch] → 測試要覆蓋「剛寫入就恰好一次」，並附注入
- [dispatch 失敗後最壞 24 小時才收斂] → 使用者接受；會產生新金鑰的只有首次 sync 或金鑰重建，而 register-provider 自己會 dispatch 並等待
- [GitHub 的排程會延遲，Actions 被停用時排程完全不跑，而且排程只在預設分支上存在，所以「最多 24 小時」從 merge 之後起算、也不是嚴格上界] → 已知限制；repo 目前是 public
- [排程 run 的空 nonce] → 已查證安全；`test-refresh-attribution.sh` 加行為情境釘住（tasks 1.3）

## Migration Plan

merge 後 provider 自己收斂，最壞約 60 分鐘生效。驗收是在 merge 之後量 refresh 的 run 紀錄：`workflow_dispatch` 次數從每 30 分鐘兩次降到 0，而且有 `schedule` event 的 run。退回＝revert。
