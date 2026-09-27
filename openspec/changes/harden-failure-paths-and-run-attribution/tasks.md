## 0. 本輪稍早已完成（紀錄）

- [x] 0.1 失敗的 create-worker 收殘骸＋CI 每次 push 跑全套（a2c318c）
- [x] 0.2 三個小修正：埠段與 master 欄位從宣告處讀取（306a9b8）
- [x] 0.3 CI 測試迴圈在 errexit 下第一個失敗就中止 → 修成跑完再報告（d6e2501）
- [x] 0.4 auditd 覆蓋範圍與 fh-proxy 盲區寫進 `docs/AUDIT.md`（4564841）

## 1. delete-worker 釋放埠失敗的說明（C3）

- [x] 1.1 impl：S6 加 `id: release`，新增三岔失敗說明步驟；證明測試 `test-delete-release-port.sh`
- [x] 1.2 impl：說明文字避開 preflight 誤判；分岔三補上可照做的手動配方與完整 refresh 指令
- [x] 1.3 test：獨立驗收（修法選擇、對 qa 的更正、自做注入、說明文字可操作性、bash 3.2／5.x）
- [x] 1.4 test：補順序斷言 3e（說明步驟必須在 `id: release` 之後），並以注入證明會紅
- [x] 1.5 test：commit 前閘門（乾淨 worktree 只放本批 2 檔，preflight＋全套綠；驗證分岔三配方）
- [x] 1.6 PM：commit＋push，CI 綠（78f8b23，新測試檔補 100755，CI 36258226578 綠 42/42）

## 2. refresh 認領自己那次 run（D2a）

- [x] 2.1 test：先寫行為測試 `test-refresh-attribution.sh`（對舊碼紅），review 驗證它對最小正確實作會綠
- [x] 2.2 impl：`refresh-authorized-keys.yml` 加 `nonce`＋`run-name:`；`dispatch_refresh_and_wait` 改標題比對、認不出就明說
- [x] 2.3 review：獨立驗收（4 支測試的 fake 改動沒有放水、不猜、nonce、本批單獨成立、真機步驟可判定）
- [x] 2.4 PM：commit＋push，CI 綠（最終 12d3a2b；0137929 推上後 CI 紅 2/2：test-mlp-fwd injection-fail 1；對照 4564841 綠 → 01:30 revert 為 73766a1）
- [x] 2.4a review：找出 CI 紅的根因 → **與 D2a 無關**：test-mlp-fwd 注入 27 在 Linux 上惰性（只 patch fallback 行），押在 RTT 抖動（306a9b8 那次也是它）
- [x] 2.4b impl：修注入 27（兩條 RTT 路徑都 patch），強制條件修前紅／修後綠；commit `9c860b9`，CI 36262354720 綠 42/42
- [x] 2.4c PM：revert 73766a1 讓 D2a 回到 master（`12d3a2b`），CI 36262470600 綠 43/43
- [x] 2.5 真機驗證（review，4 次 dispatch，`OUT-d2a-live.md`）：過。帶 nonce dispatch，標題裡有 nonce；不帶 nonce 時標題合理；連發兩次各自認到自己。不過 → revert、停下

## 3. create／delete／rotate 與 mlp 同一套機制（D2b）

- [x] 3.1 impl：跨 repo 影響盤點（MyAiEntry 的依賴清單、`run-name` 會不會改變它讀的欄位、`mlp` 使用者可見的變化）
- [x] 3.2 使用者選路線 → **C：run id 為主、nonce 為退路**。盤點結果是 MyAiEntry 不會壞，但發現 `return_run_details`（dispatch 直接回 run id）→ nonce 路線 vs run id 路線，待使用者決定
- [x] 3.2a test：不綁做法的 `wf_dispatch` 歸屬測試 `test-wf-dispatch-own-run.sh`（現碼紅 9/8；A、B 丟棄式實作皆 17/0；既有 attribution 測試在兩路線下要翻的斷言見 OUT-test-d2b-agnostic §6；未 commit，隨 D2b 一起進）
- [x] 3.3 workflow 端的結構守衛：impl 在 C 路線一併加了 0b（四支 yml 必須宣告 `nonce`、`run-name` 必須引用它）
- [x] 3.4 impl（`OUT-d2b-route-c.md`，全套 44/44）：三支 workflow 加 `nonce`＋`run-name:`；`wf_dispatch` 先取 `gh workflow run` 印出的 run id、拿不到才比對標題、都沒有回 rc 3；升級既有 attribution 測試並列出每條翻轉
- [x] 3.5 review：獨立驗收（`OUT-verify-d2b.md`：找到空 nonce 假綠 → impl 補護欄 → §9 複驗過）
- [x] 3.6 PM：commit＋push，CI 綠（`c7113b3`，CI 36281257576 綠 44/44）
- [x] 3.7 真機驗證（review，`OUT-d2b-live.md`）：rotate dry run 經 `mlp` 走主路徑認到自己的 run、preview 建了也刪了；`mlp worker new` 只能互動，create／delete 改用 `gh workflow run` 帶 nonce 驗 run-name（皆過，delete 同時是 C3 新版的首次真機成功路徑）；前後 `mlp ls`／`mlp state`／Linode 清單一致

## 4. 封關

- [x] 4.1 已知限制總表 → `known-limitations.md`
- [ ] 4.2 E1：把本輪發現寫進 MyBrain，開 PR 給使用者 review
- [ ] 4.3 打掃：隊員的 `/tmp` 暫存、worktree、docker image
- [ ] 4.4 本 change 的 tasks 全部勾完後 commit；是否 archive 由使用者決定
