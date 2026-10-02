## ADDED Requirements

### Requirement: 找不到 repair 名字時說明原因
repair 段已設定、而 `mlp ssh <名字>` 找不到任何 provider、worker 或在線的 repair 符合時，`mlp` MUST 在「no such node or worker」那行之前多印一行說明：repair 機器只在線上時才找得到，關機或關掉「維修連線」的看起來跟從來沒有的一樣，並且指向 `mlp ls` 裡 TYPE 為 repair 的列。原本那行 MUST 維持在最後一行，措辭不變。`mlp fwd add` 的同一種說明 MUST NOT 叫使用者去看不存在的「repair section」。

#### Scenario: mom-pc 沒開
- **WHEN** repair 段已設定，`mom-pc` 不在線，使用者執行 `mlp ssh mom-pc`
- **THEN** 非零結束，stderr 先印說明行，最後一行是 `no such node or worker: mom-pc`

#### Scenario: 沒有設定 repair 段
- **WHEN** `NODE_GATEWAY.ports.repair` 沒有設定，使用者執行 `mlp ssh 不存在的名字`
- **THEN** 不印 repair 的說明行，照舊印未設定段的警告與 `no such node or worker`

#### Scenario: 說明指向的是真的東西
- **WHEN** `mlp fwd add` 或 `mlp ssh` 印出 repair 的說明行
- **THEN** 那行指向 `mlp ls` 裡 TYPE 為 repair 的列，而不是「repair section」
