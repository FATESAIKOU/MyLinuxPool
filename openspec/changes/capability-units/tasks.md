## 0. 開工前

- [x] 0.1 使用者裁示（2026-10-02）：
  - 能力即 shared-configs 單位
  - pool-sync 自動寫宣告，有變才寫
  - worker 照 profile 宣告，不驗證
  - `via` 保留當叫醒順序，`wol` 只代表資格
  - 鍵名 `wol`，形狀 `{"methods":["unicast"]}`
  - fh-l 也宣告 `github`
  - 註解要少
  - 做到 PR，等使用者看過再 merge
- [x] 0.2 唯讀調查：`team/OUT-recon-capability.md`、`team/OUT-impl-recon-myaientry-caps.md`、`team/OUT-test-recon-capability-tests.md`
- [x] 0.3 通知 MyAiEntry#4（這一輪要變的部分與要對方確認的事）
- [ ] 0.4 唯讀：`mlp verify-capabilities fh-proxy`。no-sudo 那台的 `worker-host` 驗證過不過，要在實作前知道

## 1. 紅燈測試

- [ ] 1.1 契約測試：每個帶 `capability` 的單位都有 `install.sh --check`；每個鍵只由一個單位實作；值的形狀；preflight 會擋重複的鍵
- [ ] 1.2 runner：`capability_plan`、`capability_check`、`capability_declaration`。參數經環境變數傳入；check 失敗的能力不進宣告
- [ ] 1.3 pool-sync：宣告已一致時零寫入（附正對照）；能力壞掉時拿掉；恢復時加回；只 merge `capabilities` 欄位
- [ ] 1.4 register-provider：check 失敗時註冊失敗，而且訊息指出是哪個能力
- [ ] 1.5 create-worker：照 profile 寫入，沒有就寫 `{}`
- [ ] 1.6 `mlp wake`：只試宣告了 `wol` 的代送方，並說明略過原因
- [ ] 1.7 `mlp verify-capabilities`：改用 runner，對現有宣告的輸出不退化

## 2. 實作

- [ ] 2.1 D1–D7

## 3. 驗收

- [ ] 3.1 review：獨立驗收
- [ ] 3.2 PM 閘門、PR
- [ ] 3.3 merge 後真機驗收：
  - 三台的宣告收斂成預期值
  - `mlp wake fh-l` 照常能用
  - 能力壞掉再恢復時，宣告跟著消失、出現
  - 刪掉 `NODE_FH_PROXY.wol_sender`（執行前再跟使用者確認）
