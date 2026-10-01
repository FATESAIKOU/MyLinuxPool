## Why

repair 跳板與 `mlp fwd` 已經可以用了，但 `mlp` 自己的說明沒有跟上（`team/OUT-review-mlp-help-gap.md` 列了 19 處）。其中三處會讓使用者走錯路：`mlp ssh <名字>` 遇到沒開機的 repair，只說「no such node or worker」，好像那台不存在；`mlp --help` 的 `ls`、`ssh` 沒有提到 repair；`docs/REPAIR-HOST.md` 示範的 `mlp ls` 輸出，是測試明確禁止的舊格式。使用者決定這次只修這三個必修。

## What Changes

- `mlp ssh <名字>` 找不到目標、而 repair 段已設定時，在原本那句「no such node or worker」之前，多印一行說明：repair 只有在線時才看得到，關機或關窗的跟從來沒有的看起來一樣，請用 `mlp ls` 看 TYPE 為 repair 的列。原本那句保持在最後一行、措辭不變。
- `mlp fwd add` 既有的同一行說明裡寫的「the repair section of "mlp ls"」改成「TYPE 為 repair 的列」，因為 `mlp ls` 已經沒有 repair 分區。
- `mlp --help` 的 `ls`、`ssh` 兩行說明提到 repair。
- `docs/REPAIR-HOST.md` 的 `mlp ls` 示範改成真正的輸出（主表裡 `TYPE repair` 的一列），並刪掉「示意／還沒實作」。

另外 16 處建議不在這次範圍內（使用者決定）。

## Capabilities

### New Capabilities
（無）

### Modified Capabilities
- `repair-host`：新增「`mlp ssh` 對不在線的 repair 名字要說明為什麼找不到」的需求。

## Impact

- 程式：`ops-scripts/mlp`（一個錯誤訊息、一個既有訊息的措辭、`usage()` 兩行）。
- 文件：`docs/REPAIR-HOST.md`。
- 測試：`scripts/tests/test-mlp-repair.sh`（ssh 的說明行、usage）、`scripts/tests/test-mlp-fwd.sh`（既有的 fwd 說明行改了措辭）。
