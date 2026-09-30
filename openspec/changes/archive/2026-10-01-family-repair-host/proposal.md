## Why

使用者要能遠端維修家人家裡的網路與電腦（issue #6）。家人不懂技術，所以必須是：家人在自己的 Win10 上點兩下，一台 Linux 就自動開起來、經反向隧道接上 Gateway。使用者從 Gateway 登入那台 Linux，再從它碰到家人家裡的網路。

現在的池子做不到這件事。provider 的登錄只能在節點本身上跑，而且會把 `GH_POOL_TOKEN`（整座池的控制權）存進節點。家人的電腦不能放這把權杖。

## What Changes

- **臨時跳板（ephemeral repair host），全家共用一把隧道金鑰。** 它**不是**
  `role=provider` 的機器：不寫 `NODE_*`、不進 state 快取，`mlp` 直接掃
  Gateway 的 listener 找在線的跳板（跟 provider、worker 分開一區）。
  MyAiEntry（手機）完全不知道它們存在。它**不承載 worker**、**不持有
  GitHub 權杖**、**不跑 `pool-sync`**，只跑 `pool-tunnel` 的靜態模式。
- **在使用者的 Mac 上做一次設定、打一份全家共用的包。** 新的
  `ops-scripts/setup-repair-key` 產生隧道金鑰對、把公鑰寫進
  `REPAIR_TUNNEL_PUBKEY`、觸發 authorized keys 的刷新並等結果；新的
  `ops-scripts/package-repair-host` 讀 CLIENT_* 快照與 `NODE_GATEWAY`
  的 SSH port 和 repair 段，產出安裝包（含共用隧道私鑰、登入公鑰、設定）。
  家人那邊不必做任何設定。
- **VM 與 Windows 啟動器。** 用 VirtualBox 跑 Ubuntu cloud image，網路用 NAT。sshd 只聽 `127.0.0.1`，家人網路上的其他裝置碰不到它。啟動器（PowerShell）做五件事：問並記住 Gateway IP **與這台的名字**、把兩者交給 VM、無頭開機、顯示「維修連線中，關掉此視窗即中斷」。首次需要安裝 VirtualBox 並按一次 UAC。
- **`pool-tunnel` 的靜態模式可以指定 Gateway 的 SSH port。** 現在它寫死 22，Gateway 實際跑在 2100，照原樣做會連不上。
- **兩道守衛。** 一道擋「權杖出現在維修承載機上」；另一道讓 create-worker 拒絕沒有宣告 `worker-host` 的 provider（跳板不在 `NODE_*` 裡，連指名都指名不到，閘門保留是擋既有 provider 的情形）。
- **撤銷＝換金鑰。** 沒有「只撤一台」的開關；換共用金鑰、全家重裝（家人不多，可接受）。

**不在範圍內**（使用者決定）：
- 收窄隧道金鑰的權限：現況每把隧道金鑰都能在 Gateway 上拿到 `sshproxy` 的 shell，本輪不改（全家共用一把，外洩影響全家，見已知限制）。
- 認證家人輸入的名字：誰拿到包都能自稱任何名字；`mlp ssh` 同名時改用 port。
- 橋接網路：只做 NAT。

## Capabilities

### New Capabilities
- `repair-host`：臨時跳板——全家共用一把隧道金鑰、不寫 `NODE_*`、不持有 GitHub 權杖的承載機，從使用者的 Mac 設定一次、打一份全家共用的包，在家人的 Win10 上以 VM 形式運作並自動接上 Gateway（名字與 IP 由啟動器在開機時給）。

### Modified Capabilities
（無；本 repo 的 openspec 目前沒有主規格）

## Impact

- 新增：`profiles/provider/repair/`（沿用目錄，內容已改版）、`ops-scripts/setup-repair-key`、`ops-scripts/package-repair-host`（改新介面）、共用隧道公鑰 var `REPAIR_TUNNEL_PUBKEY`、Gateway `2400–2499` repair 段（`NODE_GATEWAY.ports.repair` 宣告）、啟動器素材（名字＋IP 輸入、`/gw` 兩行）、`docs/` 下一份設計與操作文件、對應的測試
- 修改：`shared-configs/pool-runtime/files/pool-tunnel`（靜態模式的 port）、`refresh`／`rotate` 共用的 sshproxy 組裝（收錄共用公鑰）、`mlp`（掃描 Gateway 列 repair 區、同名處理）
- 刪除：`ops-scripts/register-repair-host` 及其測試、parity 守衛（第一版每台登錄 `NODE_*` 的路）
- 跨 repo：MyAiEntry 不用改——跳板不出現在它讀的任何資料裡，AI 看不到
- 真機：Gateway 的 sshproxy 清單多一把共用隧道公鑰（經 refresh／rotate 收錄）；`2400–2499` 段由 VM 現場挑空埠；最終驗收要在一台真的 Win10 上做
