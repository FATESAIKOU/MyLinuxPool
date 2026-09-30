## ADDED Requirements

### Requirement: 用 `mlp fwd` 轉發到 repair 機器
使用者 MUST 能用 `mlp fwd add`，以 repair 機器的名字或它在跳板段內的 port 為目標，把 Mac 本機的一個 port 轉到 repair VM 上的 port，或經 repair VM 轉到家人區網上的主機。repair 的轉發 MUST 跟其他機器的轉發一樣出現在 `mlp fwd ls`、能用 `mlp fwd rm` 移除，並且只存在於客戶端（不寫任何池子狀態）。不帶參數的 `mlp fwd add` 選單 MUST 列出在線的 repair 機器；選到的 repair 列 MUST 以該列的 port 為目標。名字同時對到多台 repair 機器時，`mlp fwd add <名字>` MUST 拒絕並列出候選的 port，而不是任選一台。

#### Scenario: 轉到家人的路由器
- **WHEN** repair 機器 `mom-pc` 在線，使用者執行 `mlp fwd add mom-pc 8080:192.168.0.1:80`
- **THEN** 在 Mac 上開 `http://localhost:8080` 看到的是 `mom-pc` 所在區網裡 `192.168.0.1:80` 的回應，而且 `mlp fwd ls` 列出這條轉發

#### Scenario: 用 port 指定
- **WHEN** 使用者以 repair 機器的 port（例如 `2401`）當目標執行 `mlp fwd add`
- **THEN** 轉發建立在那個 port 的 repair 機器上

#### Scenario: 同名的 repair 機器
- **WHEN** 兩台在線的 repair 機器同名，使用者以那個名字執行 `mlp fwd add`
- **THEN** 指令拒絕、非零結束，並列出兩台的 port

#### Scenario: 選單
- **WHEN** 使用者不帶參數執行 `mlp fwd add`
- **THEN** 選單裡有在線的 repair 機器，選它就以它的 port 建立轉發

### Requirement: repair 離線時轉發自然失效
repair 機器離線，或重新連線換了 port 時，既有的轉發 MUST NOT 自動改接到其他 port 或其他機器。它 MUST 自然失效，且 `mlp fwd ls` MUST 不再把它顯示為正常；使用者要自己重建。

#### Scenario: 家人關掉視窗
- **WHEN** 已經有一條到 `mom-pc` 的轉發，而 `mom-pc` 離線
- **THEN** 那條轉發不再能用，`mlp fwd ls` 顯示它不在或 down，不會出現一條接到其他機器的轉發

#### Scenario: 另一台接手同一個 port
- **WHEN** 原本那台 repair 機器離線後，另一台 repair 機器接上了同一個 port
- **THEN** 舊的轉發不會經由那個 port 連到新的那台機器
