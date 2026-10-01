## Why

issue #7：每台 provider 的 `pool-sync.timer` 每 30 分鐘 tick 一次，每次都會 dispatch `refresh-authorized-keys.yml`，不管隧道金鑰有沒有變。兩台 provider 加起來每天約 96 次無用的 refresh。repo 改成 public 之後，這不再吃 Actions 額度，但 run 紀錄被淹沒，而且這次 refresh 的語意也錯了：它本來是「剛發布新金鑰，請 Gateway 授權它」。根因是 `tunnel_key_publish` 在「已經一樣、什麼都沒寫」時也回 0，pool-sync 只看回傳碼就 dispatch。

## What Changes

- `tunnel_key_publish`／`tunnel_key_ensure_published` 回報**這一次有沒有真的寫入**（輸出變數，回傳碼維持原樣：成功＝0、失敗＝非 0），讓呼叫端分得出「沒變動」與「剛寫入」。`tunnel_key_mint` 補上顯式的成功回傳。
- `pool-sync` **只在真的寫入了新的隧道金鑰時**才 dispatch refresh。dispatch 失敗只記警告，不留任何標記檔；pool-sync「`~/.mylinuxpool` 底下不保存狀態」的原則維持不變（使用者決定）。
- `refresh-authorized-keys.yml` 加一個**每日排程**（UTC 20:00，台灣時間 04:00），當作保險：dispatch 失敗、有人直接在 GitHub UI 改 `CLIENT_*`／`NODE_*`、Gateway 上被手動加了金鑰，這些情況過去靠 pool-sync 那個 bug 順手收斂，修好之後改由排程收斂（最多 24 小時）。
- **不加** `concurrency` group。加了之後排隊中的 refresh 會被取消，結論變成 `cancelled`，會誤傷等待 refresh 結果的硬失敗呼叫端（register-provider、create-worker、delete-worker）。

## Capabilities

### New Capabilities
- `pool-sync`：provider 端的定期收斂（`pool-sync.timer`），本次只規範它與 Gateway authorized_keys 刷新之間的關係。

### Modified Capabilities
（無）

## Impact

- 程式：`scripts/lib/tunnel-key.sh`、`shared-configs/pool-runtime/files/pool-sync`、`.github/workflows/refresh-authorized-keys.yml`。
- 呼叫端：`register-provider.sh` 不讀新的輸出變數，行為不變（它自己 dispatch 並等待）。
- 測試：`shared-configs/pool-runtime/tests/test-pool-sync.sh`、`scripts/tests/test-tunnel-key-lib.sh`，以及 workflow 的結構測試。
- 部署：provider 下一個 tick 從 master 收斂到新的 pool-runtime，再下一個 tick 才執行新邏輯，所以從 merge 到生效最壞約 60 分鐘。
- 文件：`docs/RUNBOOK.md`、`docs/KEY-DESIGN.md`、`docs/TESTPLAN.md` 裡描述 refresh 觸發時機的段落。
