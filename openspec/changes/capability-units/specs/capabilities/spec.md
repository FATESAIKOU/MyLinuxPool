## Purpose

讓每個 member（provider 與 worker）能做什麼由它自己說：能力的「設定」寫在 profile，「驗證」由提供該能力的安裝單位負責，「宣告」由系統依設定與驗證結果寫進主本；消費端（`mlp`、MyAiEntry）只讀宣告。

## ADDED Requirements

### Requirement: 每個能力由一個安裝單位實作
每個能力鍵 MUST 恰好由一個 `shared-configs` 單位實作，該單位的 `unit.json` MUST 以 `capability` 欄位寫明它實作的鍵，並提供 `--check` 來驗證「這台機器在宣告的參數下確實具備這個能力」。新增一個能力 MUST NOT 需要修改 `mlp`、`register-provider.sh`、pool-sync 或 create-worker。

#### Scenario: 新增一個能力
- **WHEN** 有人新增一個帶 `capability` 欄位的安裝單位，並在某個 profile 的 `capabilities` 列出它
- **THEN** 使用那個 profile 的 provider 會照它的 `--check` 驗證並宣告這個能力，而共用 runner 以外的程式碼都不必修改

#### Scenario: 兩個單位實作同一個鍵
- **WHEN** 兩個單位的 `capability` 是同一個鍵
- **THEN** preflight 失敗，並列出這兩個單位

### Requirement: provider 的宣告由 pool-sync 依驗證結果寫入
pool-sync 的每一次 tick MUST 對 profile 列出的每個能力，帶入 profile 的參數跑對應單位的 `--check`，以通過的能力（值即 profile 的參數，空參數為 `{}`）組成宣告；宣告與 `NODE_<NAME>.capabilities` 不同時 MUST 寫入，相同時 MUST NOT 寫入。`--check` 失敗的能力 MUST NOT 出現在宣告裡。需要金鑰或 root 的單位，pool-sync MUST NOT 安裝，但 MUST 仍然驗證。

#### Scenario: 能力都成立、宣告已一致
- **WHEN** profile 的每個能力都通過 `--check`，而且 `NODE_<NAME>.capabilities` 已經等於推導出的宣告
- **THEN** 這次 tick 沒有寫入任何 var

#### Scenario: 某個能力壞掉了
- **WHEN** 某個能力的 `--check` 失敗（例如 docker 停了）
- **THEN** 那個能力從 `NODE_<NAME>.capabilities` 裡被拿掉，並記一條警告

#### Scenario: 能力恢復
- **WHEN** 先前失敗的能力又通過了 `--check`
- **THEN** 它重新出現在宣告裡

### Requirement: 註冊時照宣告驗證
`register-provider.sh` MUST 用同一個 runner 安裝並驗證 profile 的每個能力；任何一個 `--check` 失敗，註冊 MUST 失敗並說明是哪一個能力。

#### Scenario: docker 不能用
- **WHEN** 註冊一台 docker 不能用的 provider，而 profile 宣告了 `worker-host`
- **THEN** 註冊失敗，訊息指出 `worker-host`

### Requirement: worker 的能力來自 profile
create-worker MUST 把 image profile 的 `capabilities` 原樣寫進 `POOL_WORKERS` 的那一筆；沒有宣告時 MUST 寫 `{}`，MUST NOT 寫 `null`。worker 的能力 MUST NOT 另外驗證。

#### Scenario: 建一個 worker
- **WHEN** 用一個宣告了能力的 profile 建 worker
- **THEN** `POOL_WORKERS` 那一筆的 `capabilities` 等於 profile 的 `capabilities`

### Requirement: 宣告的形狀
每個能力的值 MUST 是 object（沒有參數時是 `{}`）。`wol` 的形狀 MUST 是 `{"methods":["unicast"]}`；`github` 的形狀 MUST 是 `{"repos":{"<owner>/<repo>":["read"]}}`。

#### Scenario: 值不是 object
- **WHEN** profile 裡某個能力的參數不是 object
- **THEN** preflight 或註冊拒絕，不寫入任何宣告

### Requirement: 叫醒只交給有資格的代送方
`mlp wake` MUST 依被叫醒方 `power.launch.via` 的順序嘗試，但 MUST 只嘗試宣告了 `wol` 的代送方；略過任何一台時 MUST 說明它被略過的原因（例如「via 裡有它，但它沒有宣告 wol」）。Gateway MUST NOT 宣告 `wol`。

#### Scenario: 第一順位沒宣告 wol
- **WHEN** `via` 是 `[A, B]`，只有 B 宣告了 `wol`
- **THEN** `mlp wake` 印出 A 被略過與原因，接著用 B 嘗試
