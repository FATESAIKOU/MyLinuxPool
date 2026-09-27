## Purpose

delete-worker 在寫入叢集狀態之後失敗時，操作者必須從該次 run 本身得知留下了哪些殘骸、重跑能不能收乾淨、不能的話要手動做什麼。

## ADDED Requirements

### Requirement: 釋放埠失敗時交代殘骸與收法
delete-worker 在「釋放 Gateway 埠佔位」這一步失敗時，該次 run MUST 在 log 與 job summary 寫出：受影響的埠號與 worker 名稱、仍然殘留的狀態（佔位、帳本、authorized keys、state cache），以及可以直接照貼的重跑指令。

#### Scenario: 釋放埠失敗
- **WHEN** 容器已刪除，而釋放埠佔位的步驟失敗
- **THEN** job summary 列出該埠號與 worker 名稱、說明四項狀態仍在，並給出以同一個埠重跑 delete-worker 的完整指令

#### Scenario: 照說明重跑可以全癒
- **WHEN** 操作者照說明，以同一個埠重跑 delete-worker
- **THEN** 重跑成功，而且佔位、帳本、authorized keys、state cache 都不再宣告該 worker

### Requirement: 釋放埠之後失敗時不承諾重跑可癒
釋放埠已成功、之後的步驟（刪帳本、refresh、推 state cache）失敗時，說明 MUST 明講「重跑不能收乾淨」，並給出手動收拾步驟：取出帳本現值、移除該埠、寫回帳本、dispatch refresh。

#### Scenario: 帳本或 refresh 失敗
- **WHEN** 釋放埠成功，但刪帳本或 refresh 失敗
- **THEN** job summary 說明重跑會在尋找 worker 時失敗，並列出可照做的手動收拾步驟，其中包含完整的 `gh workflow run refresh-authorized-keys.yml` 指令

### Requirement: 寫入前失敗不誤報殘骸
尚未寫入任何叢集狀態就失敗時（例如找不到該 worker），說明 SHALL 只要求修正輸入後重新 dispatch，不得描述不存在的殘骸。

#### Scenario: 找不到 worker
- **WHEN** 輸入的埠號或名稱找不到對應的佔位
- **THEN** 說明只要求修正輸入再 dispatch 一次

### Requirement: 失敗說明本身不得失敗
失敗說明步驟 MUST 只輸出文字，不執行 ssh、`gh` 或任何會改變狀態的指令，而且 MUST 排在釋放埠那一步之後，確保它在釋放埠失敗時會被執行。

#### Scenario: 說明步驟的位置與內容
- **WHEN** 檢查 delete-worker 的步驟順序與說明步驟的內容
- **THEN** 說明步驟位於釋放埠步驟之後，且不含任何網路或寫入操作
