## Why

issue #3：使用者以為能力的登錄與參照機制早就寫完了，實際上只有形狀與兩個寫死的驗證器。三台 provider 都讀得到 MyBrain，卻沒有一台宣告 `github`；fh-proxy-asus 實測叫醒過 fh-l，卻沒有任何宣告。原因是宣告靠人手寫，之後沒有人維護。

使用者這一輪的方向：**每個 member（provider／worker）自己能做什麼，由它自己說**，並且要有一個共通的「設定」與「說」的機制。能力就是可以安裝的東西，wol 也是其中一個能力。

## What Changes

- **每個能力就是一個 `shared-configs` 單位。** `unit.json` 新增 `capability` 欄位，寫明它實作哪一個能力鍵。`install.sh` 負責安裝，`--check` 負責驗證這個能力是否成立（帶入宣告的參數）。這一輪有三個：
  - `worker-host`：新單位，驗證方式是以宣告的使用者身分跑 `docker info`。
  - `github`：沿用 `gh` 單位，驗證方式是對宣告的每個 repo 照權限驗證。
  - `wol`：把 `pool-wol` 從 `pool-runtime` 拆出來成為獨立單位，形狀是 `{"methods":["unicast"]}`。
- **設定＝profile。** `profiles/<role>/<name>/profile.json` 的 `capabilities` 寫這個角色要有哪些能力，以及各自的參數。
- **說＝自動推導，有變才寫。**
  - **provider**：pool-sync 每個 tick 對 profile 列的每個能力跑該單位的 `--check`，用通過的能力組成宣告；跟 `NODE_<NAME>.capabilities` 不同時才 merge 進去（跟發布隧道金鑰同一個做法）。`--check` 沒過的能力會從宣告裡拿掉。需要金鑰或 root 的單位，由 register-provider 安裝；pool-sync 只驗證、只寫宣告。
  - **worker**：profile 用到哪些能力就有哪些能力，不另外驗證。create-worker 照 profile 寫進 `POOL_WORKERS`。
- **共用的 runner。** `mlp`、`register-provider.sh`、pool-sync、create-worker 只呼叫同一支共用的能力 runner，不再各自寫死任何能力鍵。目前寫死的地方有五處。
- **register-provider 驗證要能失敗**（issue #3 的 g1）：照宣告逐一跑 `--check`，沒過就讓註冊失敗。
- **wol 的叫醒**：`NODE_FH_L.power.launch.via` 保留，繼續代表叫醒順序；能不能當代送方，由代送方自己宣告的 `wol` 決定。`mlp wake` 只試 `via` 裡宣告了 `wol` 的機器；跳過哪一台、為什麼跳過，都要明說。
- **Gateway 不宣告 wol**：Gateway 的 profile 不列 wol 單位，因為它碰不到家裡的區網。
- **清掉殘留**：刪掉 `NODE_FH_PROXY.wol_sender`（9/13 的舊 schema）；`docs/CAPABILITY-DESIGN.md` 照新的機制改寫，並更正其中記錯的 wol 裁定。

## Capabilities

### New Capabilities
- `capabilities`：member 能力的設定（profile）、驗證（單位的 `--check`）與宣告（`NODE_*`／`POOL_WORKERS`）的共通機制。

### Modified Capabilities
（無）

## Impact

- 程式：`shared-configs/{worker-host,wol,gh,pool-runtime}/`、`scripts/lib/`（新的能力 runner）、`shared-configs/pool-runtime/files/pool-sync`、`ops-scripts/register-provider.sh`、`ops-scripts/mlp`（`verify-capabilities`、`wake`）、`scripts/create-worker.sh`、`scripts/lib/profile.sh`、`profiles/*/*/profile.json`。
- 主本：這次改動之後，pool-sync 會自己寫 `NODE_*.capabilities`。三台 provider 預期會變成 `worker-host`＋`github`＋`wol`。
- MyAiEntry：只多了 `wol` 鍵，以及 `github` 的出現，這兩件 app 都能讀，`via` 不動，所以 **app 不用改**。另外要查 app 挑 `github` 機器時會不會先看在不在線，因為 fh-l 關機時，它的宣告會停在上一次開機寫下的值。這件事已經寫進 MyAiEntry#4，請對方確認。
- 測試：`test-capability-flags.sh`、`test-pool-sync.sh`、`test-install-check.sh`、wake 的相關測試，另外新增一支「每個能力單位的契約測試」。
