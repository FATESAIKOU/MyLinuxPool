## Why

維修跳板是為了讓使用者修家人家裡的網路。那個網路裡有很多東西是網頁介面，例如路由器管理頁、NAS、印表機。現在使用者只能 `mlp ssh` 進 repair VM，在 shell 裡操作。`mlp fwd` 已經能把 provider／worker 的 port 帶到 Mac 的 localhost，但對 repair 機器不能用：`mlp fwd add` 的選單不列 repair，其餘路徑也沒有驗證過。

## What Changes

- `mlp fwd add <repair 名字或 port> <spec>` 可以把本機 port 轉到 repair VM，或經 VM 轉到家人區網上的主機。例如 `mlp fwd add mom-pc 8080:192.168.0.1:80`，就能在 `http://localhost:8080` 看到家人的路由器。
- 不帶參數的 `mlp fwd add` 選單會列出在線的 repair 機器（跟 provider／worker 並列）。選到 repair 那一列時，用它的 port 解析，所以同名或 `?` 的列也不會連錯。
- `mlp fwd ls`／`mlp fwd rm` 對 repair 的轉發跟其他機器一樣處理。錯誤訊息不再只寫「node or worker」。
- **不自動跟上**（使用者裁示）：repair 離線，或重新連線換了 port，它的 fwd 就自然斷掉，`mlp fwd ls` 顯示為不在或 down，使用者自己重建。不重新解析名字，所以舊的 fwd 不會接到之後同名的別台機器。

不在範圍內：repair 的原生 `ssh`／ssh-config（`Host repair-*`）。

## Capabilities

### New Capabilities
（無）

### Modified Capabilities
- `repair-host`：新增「使用者能用 `mlp fwd` 把本機 port 轉到 repair 機器，並經由它轉到家人區網上的主機」的需求。

## Impact

- 程式：只改 `ops-scripts/mlp` 的 fwd 解析、選單、顯示與訊息。
- 測試：`scripts/tests/test-mlp-fwd.sh` 和／或 `scripts/tests/test-mlp-repair.sh`，沿用既有的假 Gateway／名牌 fixture。
- 不動 Gateway、provider、workflow、GitHub vars、VM、Windows 啟動器。fwd 仍然只存在於客戶端。
- 真機驗收：使用者的 repair 機器 `mom-pc`，轉到家人路由器的登入頁（只 GET、不登入）。
