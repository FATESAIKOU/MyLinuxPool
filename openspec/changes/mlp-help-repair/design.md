## Context

`team/OUT-review-mlp-help-gap.md`（2026-10-02，唯讀）：`mlp` 的錯誤訊息大多早就認得 repair，但說明文字停在 repair 之前。三個必修的事實（附行號）：

- `ops-scripts/mlp:1107-1108`：`mlp ssh` 的 notfound 路徑，只在 `TARGET_DETAIL` 非空時多印一行（那是未設定段的警告），所以 repair 段已設定、機器只是不在線時，只會印出 `no such node or worker`。
- `ops-scripts/mlp:2713`：`fwd add` 已經有一行說明「repair 只在線上時才看得到」，但它叫使用者去看「the repair section of "mlp ls"」，而那個分區在 PR #8 的畫面調整時已經併進主表了。
- `ops-scripts/mlp:147-148`：`usage()` 的 `ls`、`ssh` 沒有提到 repair；同一段裡的 `fwd` 那幾行早就寫了 repair。
- `docs/REPAIR-HOST.md:100-105`：示範的輸出有 `repair:` 分區標題，而 `test-mlp-repair.sh:527-528` 專門擋這個標題。

測試現況：`test-mlp-repair.sh:555`（1d）只檢查有沒有那句 generic；`test-mlp-fwd.sh` R5 要求 fwd 路徑的 generic 是最後一行。這次只加行、不改 generic，兩者都不會紅。

## Goals / Non-Goals

**Goals：** 上面四處跟實際行為一致。
**Non-Goals：** 盤點出的其餘 15 處建議（使用者決定）。

## Decisions

**D1. `mlp ssh` 與 `mlp fwd add` 共用同一句說明。**
抽成一個函式或常數，兩邊印一樣的字，避免以後又分歧。說明行只在 repair 段已設定時印；未設定時，維持現在的 `TARGET_DETAIL` 警告。

**D2. 說明指向「`mlp ls` 裡 TYPE 為 repair 的列」。**

**D3. `usage()` 只改兩行的說明文字，不動格式。**

**D4. `REPAIR-HOST.md` 的示範用真的表頭與列形狀**，例如 `NAME TYPE PROVIDER PORT STATE` 加上 `dad-pc repair - 2403 up`；刪掉「示意／還沒實作」那句。

## Risks / Trade-offs

- [改了 fwd 那行的措辭，可能有測試釘著原字串] → 調查報告說沒有，紅燈階段再確認一次
