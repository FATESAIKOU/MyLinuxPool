## Why

2026-09-25～26 的稽核發現，池子的控制平面在兩類地方會**安靜地說錯話**：

1. **失敗路徑沒有交代。** 某一步寫入之後失敗，會留下半套狀態，卻沒有任何說明。例如 delete-worker 在釋放埠時死掉：容器已刪，但埠佔位、帳本、authorized keys、state cache 全都還在，`mlp state` 仍顯示 consistent。
2. **dispatch 之後認不出自己那次 run。** GitHub 的 `workflow_dispatch` API 回 204，不告訴呼叫端建立了哪一次 run，所以呼叫端只能用到達順序猜。`refresh-authorized-keys` 被外部程序約每 10 分鐘觸發一次（2 天 294 次，歷史 384/384 success），於是 `dispatch_refresh_and_wait` 幾乎必然拿別人的成功當自己的。它會回報「鑰匙已收斂」，實際上自己那次可能還沒跑完：孤兒鑰匙留在 Gateway，沒有人會知道。

本輪範圍凍結為「只修真 bug，不收 enhance」。

## What Changes

- **delete-worker 釋放埠失敗時的說明**：S6（釋放埠）加上 `id: release`。新增一個只印字的 `if: failure()` 步驟，依失敗位置分三岔（寫入前／S6／S7 之後），在 log 與 job summary 寫出殘骸現況與收拾步驟。**不做自動補救**：只重試 S6 會清掉重跑時用來找 worker 的佔位，讓原本重跑可全癒的情況變成要手動改帳本。
- **refresh 認領自己那次 run（D2a）**：`refresh-authorized-keys.yml` 加選填 `nonce` 輸入與 `run-name:`。`dispatch_refresh_and_wait` 產生不可預測的 nonce，用標題比對認出自己那次；認不出就回非 0，不退回去猜。
- **create／delete／rotate 與 `mlp` 同一套機制（D2b）**：三支 workflow 各加選填關聯輸入與 `run-name:`；`ops-scripts/mlp` 的 `wf_dispatch` 改用標題比對，並更新它的殘留限制註解。**前提**：不破壞 MyAiEntry 對這些 workflow 的依賴（盤點中）。
- 本輪稍早已進 master、不在本 change 的 spec 範圍內（列入 tasks 作為紀錄）：失敗的 create-worker 收殘骸＋CI（a2c318c）、三個小修正（306a9b8）、CI 迴圈 errexit（d6e2501）、auditd 覆蓋文件（4564841）。

無 **BREAKING**：新增的輸入都是選填，不傳時行為與標題仍然合理（外部程序與手動 UI 發動都不傳）。

## Capabilities

### New Capabilities
- `worker-delete-failure-guidance`：delete-worker 在寫入之後失敗時，必須交代留下了什麼、怎麼收。
- `workflow-run-attribution`：呼叫端 dispatch workflow 後，必須能指認自己那次 run，認不出時明說，而不是猜。

### Modified Capabilities
（無；本 repo 在此之前沒有 OpenSpec specs）

## Impact

- 程式：`.github/workflows/{delete-worker,refresh-authorized-keys,create-worker,rotate-gateway}.yml`、`scripts/lib/refresh-wait.sh`、`ops-scripts/mlp`
- 測試：新增 `scripts/tests/test-delete-release-port.sh`、`scripts/tests/test-refresh-attribution.sh`；另外 4 支既有測試的假 `gh` 跟上「標題帶 dispatch 參數」的新契約（斷言語意不變）
- 呼叫端：`mlp register client`、`register-provider.sh`、create／delete worker workflow 內的 refresh 等待
- 跨 repo：MyAiEntry 的手機 app 會透過 GitHub API 操作這些 workflow。`run-name` 會改變 run 的顯示標題，要確認它沒有依賴標題或名稱
- 真機：D2a 以 refresh、D2b 以 create／delete／rotate 各實際 dispatch 驗證（使用者已核准，池目前未在使用）
