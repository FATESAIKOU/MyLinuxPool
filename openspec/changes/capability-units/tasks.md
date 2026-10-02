## 0. 開工前

- [x] 0.1 使用者裁示（2026-10-02）：
  - 能力即 shared-configs 單位
  - pool-sync 自動寫宣告，有變才寫
  - worker 照 profile 宣告，不驗證
  - `via` 保留當叫醒順序，`wol` 只代表資格
  - 鍵名 `wol`，形狀 `{"methods":["unicast"]}`
  - fh-l 也宣告 `github`
  - 驗證無法確認時保留原值
  - 分三個 PR
  - 註解要少
  - 每個 PR 都等使用者看過再 merge
- [x] 0.2 唯讀調查：`team/OUT-recon-capability.md`、`team/OUT-impl-recon-myaientry-caps.md`、`team/OUT-test-recon-capability-tests.md`、`team/OUT-impl-recon-selecthost-online.md`
- [x] 0.3 通知 MyAiEntry#4
- [x] 0.4 唯讀實測（2026-10-02）：
  - `mlp verify-capabilities --all`：fh-proxy（no-sudo）與 fh-proxy-asus 的 `worker-host` 都 ok；fh-l 關機
  - 兩台的 systemd user manager 都已經有 docker 群組
- [x] 0.5 propose 審查：`team/OUT-review-capability-proposal.md`，修訂已併入 design 與 spec

## 1. PR-A：單位與 runner

- [x] 1.1 紅燈：契約測試。至少要涵蓋 `worker-host`、`github`、`wol` 三個鍵各由一個單位實作；preflight 會擋重複的鍵、沒有單位的鍵、不是 object 的值；`shared-configs/wol/files/pool-wol` 與 `pool-runtime` 舊版逐位元組相同，而且 `pool-runtime` 已經不裝它
- [x] 1.2 紅燈：runner 的三態與參數傳遞（`MLP_CAPABILITY_PARAMS`）。`capability_declaration` 遇到 0、1、2 的組合要算對
- [x] 1.3 紅燈：各單位的 `--check` 判準（D5），用假的 `docker`、`gh`、`id`、`getent`
- [x] 1.4 實作 D1、D2、D3、D5、D7、preflight
- [x] 1.5 review、閘門、PR-A

## 2. PR-B：自動宣告

- [x] 2.1 紅燈：pool-sync 的宣告路徑
  - 已經一致時零寫入，要附正對照
  - 結果 1 就拿掉、2 就保留、恢復就加回
  - 只 merge `capabilities`
  - `needs_root` 的單位照樣驗證但不安裝
  - 宣告失敗不影響 tick
  - 寫入宣告不觸發任何 workflow（`gh workflow run` 零次）；只有隧道金鑰真的寫入時才 dispatch refresh，跟 #11 一樣
- [x] 2.2 紅燈：register-provider
  - 結果不是 0 就失敗，並且指名是哪個能力
  - 全部通過就寫入 runner 的宣告
  - 不再補 `worker-host` 預設
- [x] 2.3 紅燈：`mlp verify-capabilities` 改用 runner，現有的三態輸出與回傳碼不退化；新鍵不用改 mlp 就能報 pass
- [x] 2.4 紅燈：create-worker 照 profile 寫入，沒有就寫 `{}`
- [x] 2.5 實作 D4、D8，provider profile 加 `capabilities`
- [x] 2.5b D10：`pool-runtime`／`wol` 安裝改成換檔，不再原地覆寫（附測試：安裝後目標檔是新的 inode；正在執行的舊版不受影響）
- [x] 2.6 review、閘門、PR-B
- [x] 2.7 merge 後真機驗收：三台收斂成預期的宣告；停掉一台的 docker 再恢復，宣告會跟著消失、出現
  - 2026-10-02 實測：三台在兩個 tick 內收斂；fh-l 停 docker（含 docker.socket）→ worker-host 被拿掉並記 WARN → 恢復後加回；全程零 dispatch、tunnel 沒有重啟

## 3. PR-C：wake 與文件

- [x] 3.1 紅燈：`mlp wake` 只試宣告了 `wol` 的代送方，被略過的也佔序號；沒有任何一台有資格時明確失敗；`verify-capabilities` 會回報 `via` 裡沒宣告 `wol` 的機器
- [x] 3.2 實作 D6
- [x] 3.3 改寫 `docs/CAPABILITY-DESIGN.md`，清理 `docs/ARCHITECTURE.md:138-145`
- [ ] 3.4 review、閘門、PR-C
- [ ] 3.5 merge 後：
  - `mlp wake fh-l` 照常能用
  - 刪掉 `NODE_FH_PROXY.wol_sender`（執行前再跟使用者確認）
  - 更新 MyAiEntry#4
  - archive
