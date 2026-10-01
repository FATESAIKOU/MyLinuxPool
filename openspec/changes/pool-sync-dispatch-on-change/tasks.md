## 0. 開工前

- [x] 0.1 使用者裁示（2026-10-02）：完整開發流程；隊員只用 Muse Spark／Space Bunny／DeepSeek，三個都不行就停下等；不加 refresh-pending 標記，靠每日排程；排程 UTC 20:00；做到 PR、等使用者看過再 merge（真機驗收在 merge 後）
- [x] 0.2 review：唯讀調查 → `team/OUT-recon-issue7.md`；PM 依此定 D1–D4

## 1. 紅燈測試

- [ ] 1.1 test：`scripts/tests/test-tunnel-key-lib.sh`——「已一致」後 `TUNNEL_KEY_CHANGED=0`、「剛寫入」後 `=1`、回傳碼不變；`tunnel_key_mint` 的回傳值不會被後面加的程式碼改掉（附注入）
- [ ] 1.2 test：`shared-configs/pool-runtime/tests/test-pool-sync.sh`——已一致時零 dispatch（附正對照：同一套記帳在剛寫入時量得到一次）、剛寫入時恰好一次、dispatch 失敗時 tick 不失敗且 `check_no_new_state` 仍綠、印出會由每日排程收斂的警告
- [ ] 1.3 test：workflow 結構——`refresh-authorized-keys.yml` 有 `schedule` `0 20 * * *`、沒有 `concurrency`、排程 run 的 displayTitle 不會被 `refresh-wait.sh` 誤認、`inputs.*` 為空時沒有步驟會失敗

## 2. 實作

- [ ] 2.1 impl：D1–D3；註解與 `docs/RUNBOOK.md`／`KEY-DESIGN.md`／`TESTPLAN.md` 相關段落同步

## 3. 驗收

- [ ] 3.1 review：獨立驗收（呼叫端相容、條件邊界、排程與 refresh-wait 的互動、文件）
- [ ] 3.2 PM 閘門（preflight、全套 `</dev/null`、CI），開 PR
- [ ] 3.3 merge 後（使用者 merge）：量 refresh 的 run 紀錄——`workflow_dispatch` 從每 30 分鐘兩次降到 0；隔天確認有一筆 `schedule` 的 run
