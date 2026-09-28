## Purpose

讓使用者從 Gateway 遠端維修家人家裡的網路：家人在自己的 Win10 上點兩下就開起一台 Linux，那台 Linux 經反向隧道接上 Gateway，而且家人的電腦裡不放任何能控制整座池的權杖。

## ADDED Requirements

### Requirement: 登錄全部在使用者的 Mac 上完成
使用者 MUST 能在自己的 Mac 上，以一條指令替一台維修承載機完成登錄：產生隧道金鑰、寫入 `NODE_<NAME>`（`role: provider`、不宣告 `worker-host`、沒有 `power`）、觸發 authorized keys 的刷新，並產出一份給 VM 用的開機資料（含隧道私鑰、登入公鑰、節點名稱、provider port）。指定的 port 已被佔用時，這條指令 MUST 拒絕執行。

#### Scenario: 登錄一台新的維修承載機
- **WHEN** 使用者以名稱、provider port 與登入公鑰執行登錄指令
- **THEN** `NODE_<NAME>` 出現且 `role` 是 `provider`、沒有 `worker-host` 與 `power`；Gateway 的 authorized keys 含有它的隧道公鑰；本機產出一份開機資料

#### Scenario: port 已被佔用
- **WHEN** 指定的 provider port 已經屬於另一台機器
- **THEN** 指令拒絕執行，不寫任何 variable

### Requirement: 維修承載機不持有 GitHub 權杖
維修承載機上 MUST NOT 出現任何 GitHub 權杖。它不跑 `pool-sync`、`pool-resolve` 或其他需要 GitHub 的程式，只跑 `pool-tunnel` 的靜態模式。開機資料若含權杖，或 VM 上出現權杖檔，MUST 大聲失敗、拒絕啟動隧道。

#### Scenario: 開機資料不含權杖
- **WHEN** 檢查登錄指令產出的開機資料
- **THEN** 裡面沒有 `GH_POOL_TOKEN` 或任何 GitHub 權杖

#### Scenario: 權杖被放進 VM
- **WHEN** VM 上出現 GitHub 權杖檔
- **THEN** 隧道不啟動，並記錄原因

### Requirement: 家人只要點兩下
首次安裝之後，家人 MUST 只需要雙擊捷徑、確認或輸入 Gateway IP、按確定，VM 就會無頭開機並接上 Gateway。啟動器 MUST 記住上一次輸入的 IP，並顯示一個「維修連線中，關掉此視窗即中斷」的視窗；關掉這個視窗 MUST 讓 VM 關機。首次安裝可以需要系統管理員權限（UAC 按一次「是」）。

#### Scenario: 第二次以後的啟動
- **WHEN** 家人雙擊捷徑，並在上次記住的 IP 上按確定
- **THEN** VM 無頭開機，數分鐘內使用者就能從 Gateway 登入它

#### Scenario: 關掉視窗
- **WHEN** 家人關掉「維修連線中」的視窗
- **THEN** VM 關機，隧道中斷

### Requirement: 隧道能接上現在的 Gateway
`pool-tunnel` 的靜態模式 MUST 可以指定 Gateway 的 SSH port。維修承載機 MUST 使用 Gateway 實際的 SSH port（目前是 2100），而不是寫死的 22。

#### Scenario: 靜態模式指定 port
- **WHEN** 靜態模式帶著 Gateway 的 host、user 與 SSH port 啟動
- **THEN** 隧道連線使用那個 port

#### Scenario: 沒有指定 port 的既有用法
- **WHEN** 既有的呼叫端沒有提供 SSH port
- **THEN** 行為與現在相同

### Requirement: 家人網路上的其他裝置碰不到 VM 的 sshd
VM 的網路 MUST 使用 NAT，sshd MUST 只聽 loopback，並且只接受金鑰登入。使用者經由反向隧道登入之後，MUST 能從 VM 連到家人家裡區網上的裝置（例如路由器的管理頁面）。

#### Scenario: 從家人區網連 VM
- **WHEN** 家人區網上的另一台裝置嘗試連 VM 的 22 port
- **THEN** 連不上

#### Scenario: 從 VM 連家人的路由器
- **WHEN** 使用者經隧道登入 VM，連家人路由器的區網位址
- **THEN** 連得上

### Requirement: 不承載 worker 是機制，不是慣例
create-worker MUST 拒絕沒有宣告 `worker-host` 的 provider，並且 MUST 在寫入任何狀態之前就拒絕，訊息要說明原因。

#### Scenario: 指名維修承載機建 worker
- **WHEN** 有人以維修承載機當 provider dispatch create-worker
- **THEN** workflow 在寫入任何狀態之前失敗，並說明這台不承載 worker

### Requirement: 失敗時家人看得懂該做什麼
連不上 Gateway 時（例如 Gateway rotate 後 IP 換了），啟動器 MUST 顯示一段家人看得懂的訊息，告訴他們去向使用者要新的 IP，而不是一直無聲地重試。重試間隔 MUST 夠長，不會讓 Gateway 的 fail2ban 反覆封鎖家人家的 IP。

#### Scenario: Gateway 的 IP 換了
- **WHEN** 輸入的 IP 連不上 Gateway 超過一段時間
- **THEN** 啟動器顯示「連不上，請向使用者索取新的 IP」之類的訊息

#### Scenario: 金鑰被拒時的重試節奏
- **WHEN** 隧道一直被 Gateway 拒絕
- **THEN** 重試間隔拉長到不會在 fail2ban 的觀察窗內累積到封鎖門檻
