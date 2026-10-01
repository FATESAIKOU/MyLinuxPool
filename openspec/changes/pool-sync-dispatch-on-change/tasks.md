## 0. 開工前

- [x] 0.1 使用者裁示（2026-10-02）：完整開發流程；隊員只用 Muse Spark／Space Bunny／DeepSeek，三個都不行就停下等；不加 refresh-pending 標記，靠每日排程；排程 UTC 20:00；做到 PR、等使用者看過再 merge（真機驗收在 merge 後）
- [x] 0.2 review：唯讀調查 → `team/OUT-recon-issue7.md`；PM 依此定 D1–D4

## 1. 紅燈測試

- [ ] 1.1 test：`scripts/tests/test-tunnel-key-lib.sh`——「已一致」後 `TUNNEL_KEY_CHANGED=0`、「剛寫入」後 `=1`、回傳碼不變；`tunnel_key_mint` 的回傳值不會被後面加的程式碼改掉（附注入）
- [ ] 1.2 test：`shared-configs/pool-runtime/tests/test-pool-sync.sh`——已一致時零 dispatch（附正對照：同一套記帳在剛寫入時量得到一次）、剛寫入時恰好一次、dispatch 失敗時 tick 不失敗且 `check_no_new_state` 仍綠、印出會由每日排程收斂的警告。**要新增一個只讓 `gh workflow run` 失敗的 fake 模式**（例如 `dispatchfail`）：現有的 `FAKE_GH_MODE=writefail` 連 `variable set` 也一起失敗，走不到 dispatch 那一步，不適用
- [ ] 1.3 test：workflow 結構，放在 `scripts/tests/`（CI 會跑）——`refresh-authorized-keys.yml` 有 `schedule` `0 20 * * *`、沒有 `concurrency`；「排程 run 不會被 `refresh-wait.sh` 誤認」寫成**行為測試**（在 `scripts/tests/test-refresh-attribution.sh` 加一個情境：一筆排程 run＋我們自己那筆，必須仍然認出我們的）；**仍然**沒有任何 step 讀 `inputs.*`（回歸護欄，現況就成立）
- [ ] 1.4 test：重複註冊 provider（金鑰已發布）——`register-provider.sh` 仍然 exit 0，而且**仍然呼叫 `dispatch_refresh_and_wait`**（放在 `test-register-provider-tempclone.sh` 或 `test-register-provider-checks.sh`）

## 2. 實作

- [ ] 2.1 impl：D1–D3；註解與 `docs/RUNBOOK.md`／`KEY-DESIGN.md`／`TESTPLAN.md` 相關段落同步；**會變成錯字串的三處**：`docs/RUNBOOK.md:345-346`（逐字引用的 WARN）、`.github/workflows/delete-worker.yml:235`（註解）、`:300-301`（操作者指引「no schedule trigger exists in this repo」）

## 3. 驗收

- [ ] 3.1 review：獨立驗收（呼叫端相容、條件邊界、排程與 refresh-wait 的互動、文件）
- [ ] 3.2 PM 閘門（preflight、全套 `</dev/null`、CI），開 PR
- [ ] 3.3 merge 後（使用者 merge）：量 refresh 的 run 紀錄——`workflow_dispatch` 從每 30 分鐘兩次降到 0；隔天確認有一筆 `schedule` 的 run。spec「一次 dispatch 失敗後」屬人工驗收：要量的話，在 Gateway 上對照「var 有、authorized_keys 沒有」的狀態經過一次排程後是否收斂
