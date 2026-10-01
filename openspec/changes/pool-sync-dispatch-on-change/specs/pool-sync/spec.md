## Purpose

規範 provider 端的定期收斂（`pool-sync.timer`）什麼時候要求 Gateway 刷新 authorized_keys，讓刷新只在隧道金鑰真的變動時發生，並由每日排程收斂其餘的漂移。

## ADDED Requirements

### Requirement: 只在隧道金鑰真的寫入時才要求刷新
`pool-sync` 的每一次 tick MUST 只在「這一次真的把新的隧道公鑰寫進 `NODE_<NAME>`」時，才 dispatch `refresh-authorized-keys.yml`。金鑰已經發布、沒有寫入任何東西時，MUST NOT dispatch。

#### Scenario: 金鑰已經發布
- **WHEN** provider 的 `NODE_<NAME>.tunnel_public_key` 已經等於本機的隧道公鑰，pool-sync 跑一次 tick
- **THEN** 沒有任何 refresh 被 dispatch

#### Scenario: 金鑰剛寫入
- **WHEN** 本機的隧道公鑰還沒發布（或與 var 不同），pool-sync 這一次把它寫進 var
- **THEN** 恰好 dispatch 一次 refresh

#### Scenario: dispatch 失敗
- **WHEN** 金鑰剛寫入，但 dispatch refresh 失敗
- **THEN** pool-sync 記一條警告、這次 tick 不算失敗，而且不在 `~/.mylinuxpool` 底下建立任何新檔案

### Requirement: 金鑰函式回報有沒有寫入
`tunnel_key_ensure_published` MUST 讓呼叫端分得出「已發布、沒有寫入」與「這次寫入了」，而且回傳碼的語意 MUST 維持不變（成功＝0、失敗＝非 0），既有呼叫端不讀新資訊時行為不變。

#### Scenario: 重複註冊 provider
- **WHEN** `register-provider.sh` 在金鑰已經發布的機器上再跑一次
- **THEN** 它跟現在一樣成功，不因「沒有寫入」而失敗

### Requirement: 每日排程刷新
`refresh-authorized-keys.yml` MUST 每天自動執行一次（UTC 20:00），把 Gateway 的 authorized_keys 收斂到 GitHub 上的宣告。手動 dispatch 與等待 refresh 結果的既有呼叫端 MUST 不受排程影響。

#### Scenario: 一次 dispatch 失敗後
- **WHEN** 某台 provider 的新金鑰寫入了，但 dispatch 失敗
- **THEN** 最晚在下一次每日排程之後，Gateway 就會接受這把金鑰

#### Scenario: 等待 refresh 的呼叫端
- **WHEN** 排程的 refresh 跟某次手動 dispatch 的 refresh 同時存在
- **THEN** 等待手動那一次的呼叫端仍然認得出自己的 run，不會把排程的 run 當成自己的
