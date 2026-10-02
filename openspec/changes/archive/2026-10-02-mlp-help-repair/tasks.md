## 0. 開工前

- [x] 0.1 使用者裁示（2026-10-02）：只做三個必修（`mlp ssh` 離線說明、`--help` 的 ls／ssh、REPAIR-HOST.md 的示範）；PM 把 fwd 那行的「repair section」併進第一項（共用同一句）；做到 PR、等使用者看
- [x] 0.2 review：盤點 → `team/OUT-review-mlp-help-gap.md`

## 1. 紅燈測試

- [x] 1.1 （H1–H5，含文件護欄；注入改用形狀錨點，刪掉註解也照樣有效）test：`mlp ssh <不在線的 repair 名字>`（段已設定）→ 非零、stderr 有說明行、最後一行仍是 generic；段未設定 → 不印說明行；`mlp fwd add` 與 `mlp ssh` 的說明行一字不差、而且不含「repair section」；`usage()` 的 ls／ssh 兩行提到 repair。每條附注入

## 2. 實作

- [x] 2.1 impl：D1–D4（`REPAIR-HOST.md` 另外清掉 5 處「待實作確認」與圖例；註解精簡）

## 3. 驗收

- [x] 3.1 review：獨立驗收（`team/OUT-review-mlp-help-impl.md`：七項 PASS、必修 0）
- [x] 3.2 PM 閘門（preflight、全套 53 支）、PR
