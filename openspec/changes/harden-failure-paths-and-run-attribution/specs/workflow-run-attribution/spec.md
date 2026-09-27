## Purpose

呼叫端 dispatch 一支 workflow 之後，必須能從外部指認「哪一次 run 是我發動的」，只依那一次的結論判斷成敗；指認不出來時要明說，不能拿別人的 run 充數。

## ADDED Requirements

### Requirement: workflow 接受選填的關聯值並放進 run 標題
`refresh-authorized-keys`、`create-worker`、`delete-worker`、`rotate-gateway` 四支 workflow MUST 各自接受一個選填的關聯輸入，並把它放進該次 run 的顯示標題。沒有傳入時，標題 MUST 仍是可讀的靜態字串，而且 run 正常執行。

#### Scenario: 帶關聯值發動
- **WHEN** 以關聯值 X dispatch 其中一支 workflow
- **THEN** 該次 run 在 `gh run list --json displayTitle` 裡的標題包含 X

#### Scenario: 不帶關聯值發動
- **WHEN** 外部程序或手動從 UI dispatch，且沒有提供關聯值
- **THEN** run 正常執行，標題為該 workflow 的靜態名稱，不出現錯誤

### Requirement: 呼叫端以不可預測的關聯值認領自己的 run
dispatch 並等待結果的呼叫端（refresh 等待函式與 `mlp`）MUST 每次產生不可預測的關聯值（不得由時間戳推得），並且只依「標題包含該值」的那一次 run 的結論判斷成敗。

#### Scenario: 外部 run 先完成
- **WHEN** 呼叫端 dispatch 之後，另一個外部發動的同名 workflow 先完成且成功
- **THEN** 呼叫端不採用那一次的結論，繼續等待自己的 run

#### Scenario: 連發兩次
- **WHEN** 兩個呼叫端幾乎同時各自 dispatch 同一支 workflow
- **THEN** 兩者各自認到標題帶自己關聯值的那一次 run

### Requirement: 認不出時明說，不猜
呼叫端在期限內找不到帶有自己關聯值的 run 時，MUST 以非 0 結束，訊息說明「認不出自己的 run」；MUST NOT 退回用到達順序或「最新一筆」判斷。找到了但期限內沒完成時，訊息 MUST 與「認不出」可以區分。

#### Scenario: 期限內沒出現
- **WHEN** 等待期限內，沒有任何 run 的標題包含呼叫端的關聯值
- **THEN** 呼叫端以非 0 結束，訊息寫明認不出，而不是回報成功或採用其他 run 的結論

#### Scenario: 出現但逾時
- **WHEN** 已認到自己的 run，但期限內它沒有完成
- **THEN** 呼叫端以非 0 結束，訊息寫明是逾時，且與「認不出」不同

### Requirement: 不破壞既有的跨 repo 使用者
加上標題與關聯輸入之後，MyAiEntry 目前依賴這些 workflow 的方式（檔名、輸入、run 的查詢方式）MUST 繼續運作。

#### Scenario: MyAiEntry 照舊操作
- **WHEN** MyAiEntry 以它現有的方式 dispatch 並查詢這些 workflow
- **THEN** 行為與變更前一致
