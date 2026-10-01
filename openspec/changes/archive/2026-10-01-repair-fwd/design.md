## Context

調查報告在 PM 的 scratchpad `OUT-recon-fwd.md`（2026-10-01，唯讀，stub 量測，證據附 `ops-scripts/mlp:行號`）。影響做法的現況：

- **名字形式已經能用**：`fwd_add` 走 `target_resolve`，而 `target_resolve` 已經認得 repair 名字（issue #6 加的），得到 `TYPE=repair USER=repair PORT=<listener>`。
- **port 形式是錯的**：`mlp fwd add <段內 port>` 走 `target_resolve` 的裸數字分支，被當成 worker，第二跳用 `worker@127.0.0.1`。repair VM 上沒有這個帳號，所以認證一定失敗。`mlp ssh <段內 port>` 在 `do_connect` 裡另有短路，不受影響。
- **host key 不會衝突**：第二跳（`127.0.0.1:<port>`）不驗 known_hosts，只有 Gateway 那跳才驗。所以 VM 重裝換 key、不同 VM 輪流用同一個 port，都不影響 fwd。
- **選單沒有 repair**：`fwd_menu_add` 只列 `gateway` 與 `gather_targets`。
- **訊息缺兩格**：`fwd_view_add` 沒有 `repair-ambiguous`（同名時說成「no such node or worker」），也沒有 notfound 前的 `TARGET_DETAIL` 行。
- **`fwd ls` 不重新解析名字**：repair 斷線後，那筆顯示 `down/unknown`，NODE 欄變 `-`。本來就符合「自然斷掉」。

## Goals / Non-Goals

**Goals：**
- `mlp fwd add` 用名字、port、選單三種方式都能以正確的帳號連到 repair VM
- 同名、離線、未設定段時的訊息跟 `mlp ssh` 一致

**Non-Goals（使用者決定）：**
- repair 換 port 或離線時自動跟上
- 原生 ssh／ssh-config

## Decisions

**D1. 「段內的 port＝repair」抽成一個共用判斷，`do_connect` 與 `fwd_add` 各呼叫一次。**
不直接刪 `do_connect` 的短路：`test-mlp-repair.sh` §4 釘著「零 pool-resolve、零 ControlMaster」。未設定 `ports.repair` 時，裸數字維持舊行為（worker）。

**D2. fwd 選單的 repair 候選以 port 當選項。**
每台在線的 repair 一列，顯示名字（或 `?`）與 port，選到的值是 port，靠 D1 解析。這跟 `mlp ssh` 的選單同一種做法，同名與 `?` 都選得到、也不會選錯。未設定段時不列 repair，也不讓選單壞掉。

**D3. `fwd_view_add` 的訊息比照 `do_connect`。**
`repair-ambiguous` 列出候選 port，並提示改用 port；notfound 前印 `TARGET_DETAIL`（未設定段的警告）。另外加一行說明：repair 機器只在線上時才找得到，因為 listener 是唯一事實，分不出「從來沒有」和「現在不在線」。「no such node or worker」這個字串維持原樣，因為 `test-mlp-fwd.sh` 7d 有回歸測試釘著。

**D4. 不加任何跟隨或重試機制。**
fwd 的 master 是端到端到 VM 的 ssh 連線，經 Gateway 上的反向轉發。家人的 VM 一斷，Gateway 就收掉那條反向轉發，master 的連線也就跟著斷。所以舊的 fwd 不可能改接到之後拿到同一個 port 的另一台機器。使用者 2026-10-01 在 mom-pc 上關掉啟動器親自驗過。

## Risks / Trade-offs

- [D1 改變 `target_resolve <段內 port>` 的語意] → 只在段已設定且 port 落在段內時才改；測試同時釘住「未設定段時仍是 worker」
- [master 的生命週期（D4）] → 使用者 2026-10-01 在 mom-pc 上關掉啟動器驗過
- [名字沒有認證] → fwd 沿用 listener 事實，沒有新增冒名風險；已記在 repair-host 的已知限制

## Migration Plan

純客戶端變更，不影響 Gateway、provider、VM。退回＝revert 這個 change 的 commit。
