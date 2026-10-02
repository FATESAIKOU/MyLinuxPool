## Purpose

讓每個 member（provider 與 worker）自己說自己能做什麼。
- **設定**：寫在 profile。
- **驗證**：由提供該能力的安裝單位負責。
- **宣告**：系統照設定與驗證結果寫進主本。

消費端（`mlp`、MyAiEntry）只讀宣告。

## ADDED Requirements

### Requirement: 每個能力由一個安裝單位實作
每個能力鍵 MUST 恰好由一個 `shared-configs` 單位實作。該單位的 `unit.json` MUST 用 `capability` 欄位寫明它實作哪個鍵，並 MUST 提供 `install.sh --check`，從 `MLP_CAPABILITY_PARAMS` 讀參數，回傳下列三種值之一：
- `0`：能力成立
- `1`：確定不成立
- `2`：這次無法確認

新增一個能力 MUST NOT 需要修改 `mlp`、`register-provider.sh`、pool-sync 或 create-worker。

#### Scenario: 新增一個能力
- **WHEN** 有人新增一個帶 `capability` 欄位的單位，並在某個 provider profile 的 `capabilities` 列出它
- **THEN** 用那個 profile 的 provider 會照該單位的 `--check` 驗證並宣告這個能力，共用 runner 以外的程式碼都不用改

#### Scenario: 兩個單位實作同一個鍵
- **WHEN** 兩個單位的 `capability` 是同一個鍵
- **THEN** preflight 失敗，並列出這兩個單位

#### Scenario: profile 列了沒有單位實作的鍵
- **WHEN** profile 的 `capabilities` 有一個鍵，但沒有任何單位實作它
- **THEN** preflight 失敗，並指出那個鍵與 profile

### Requirement: provider 的宣告由 pool-sync 依驗證結果寫入
pool-sync 的每個 tick MUST 對 profile 列出的每個能力，帶入 profile 的參數跑對應單位的 `--check`，不管該單位要不要金鑰或 root，並且 MUST NOT 因此安裝任何單位。宣告的組法：
- 結果 `0` 的能力：放進宣告，值是 profile 的參數。
- 結果 `1` 的能力：MUST NOT 出現在宣告裡。
- 結果 `2` 的能力：MUST 保留 `NODE_<NAME>.capabilities` 裡原本的值；原本沒有就不加。

新宣告與 `NODE_<NAME>.capabilities` 在正規化之後不同時，MUST 只寫入 `capabilities` 這一個欄位；相同時 MUST NOT 寫入。宣告這一段的任何失敗 MUST NOT 讓 tick 失敗。

#### Scenario: 能力都成立，宣告也已一致
- **WHEN** profile 的每個能力都回 `0`，而且 `NODE_<NAME>.capabilities` 已經等於推導出的宣告
- **THEN** 這個 tick 沒有寫入任何 var

#### Scenario: 某個能力壞掉了
- **WHEN** 某個能力的 `--check` 回 `1`（例如 docker 停了）
- **THEN** 那個能力從 `NODE_<NAME>.capabilities` 被拿掉，其他欄位不變，並記一條警告

#### Scenario: 某個能力這次無法確認
- **WHEN** `github` 的 `--check` 因為 API 逾時回 `2`
- **THEN** `NODE_<NAME>.capabilities.github` 維持原值，這個 tick 不因此寫入

#### Scenario: 能力恢復
- **WHEN** 先前回 `1` 的能力又回 `0`
- **THEN** 它重新出現在宣告裡

#### Scenario: 需要 root 的單位
- **WHEN** profile 列了 `github`，而 `gh` 單位是 `needs_root`
- **THEN** pool-sync 照樣跑它的 `--check`，但不會嘗試安裝它

### Requirement: 註冊時照宣告驗證並寫入
`register-provider.sh` MUST 用同一個 runner 驗證 profile 的每個能力。任何一個結果不是 `0`，註冊 MUST 失敗，並說明是哪一個能力、是不成立還是無法確認。全部通過時，MUST 寫入與 pool-sync 同一個函式算出的宣告。register-provider MUST NOT 自己補任何預設的能力。

#### Scenario: docker 不能用
- **WHEN** 註冊一台 docker 不能用的 provider，而它的 profile 列了 `worker-host`
- **THEN** 註冊失敗，訊息指出 `worker-host`

### Requirement: 從使用者電腦驗證時用同一份驗證
`mlp verify-capabilities` MUST 在目標機器上跑宣告鍵所屬單位的 `--check`，MUST NOT 另外實作驗證邏輯。宣告的鍵沒有單位實作時，MUST 報 `unverifiable`，MUST NOT 報 `pass`。

#### Scenario: 新能力不用改 mlp
- **WHEN** 某台宣告了一個新能力，它的單位 `--check` 回 `0`
- **THEN** `mlp verify-capabilities` 對它報 pass

### Requirement: worker 的能力來自 profile
create-worker MUST 把 image profile 的 `capabilities` 原樣寫進 `POOL_WORKERS` 的那一筆。沒有宣告時 MUST 寫 `{}`，MUST NOT 寫 `null`。worker 的能力 MUST NOT 另外驗證。

#### Scenario: 建一個 worker
- **WHEN** 用一個宣告了能力的 profile 建 worker
- **THEN** `POOL_WORKERS` 那一筆的 `capabilities` 等於 profile 的 `capabilities`

### Requirement: 宣告的形狀
每個能力的值 MUST 是 object，沒有參數時是 `{}`。
- `wol` 的形狀 MUST 是 `{"methods":["unicast"]}`。
- `github` 的形狀 MUST 是 `{"repos":{"<owner>/<repo>":["read"]}}`。

#### Scenario: 值不是 object
- **WHEN** profile 裡某個能力的參數不是 object
- **THEN** preflight MUST 拒絕，register-provider 也 MUST 拒絕

### Requirement: 叫醒只交給有資格的代送方
`mlp wake` MUST 照被叫醒方 `power.launch.via` 的順序嘗試，但 MUST 只嘗試宣告了 `wol` 的代送方。
- 略過任何一台時，MUST 說明原因，而且那台 MUST 照樣佔一個序號。
- `via` 裡沒有任何一台宣告 `wol` 時，MUST 失敗並說明原因。
- Gateway 的 profile MUST NOT 列 `wol`。
- `mlp verify-capabilities` MUST 回報 `via` 裡沒宣告 `wol` 的機器。

#### Scenario: 第一順位沒宣告 wol
- **WHEN** `via` 是 `[A, B]`，只有 B 宣告了 `wol`
- **THEN** `mlp wake` 印出 A 被略過與原因（序號 1/2），接著用 B 嘗試（序號 2/2）

#### Scenario: 沒有任何代送方有資格
- **WHEN** `via` 裡沒有任何一台宣告 `wol`
- **THEN** `mlp wake` 失敗，不送任何封包，並說明原因
