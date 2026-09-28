## Why

使用者要能遠端維修家人家裡的網路與電腦（issue #6）。家人不懂技術，所以必須是：家人在自己的 Win10 上點兩下，一台 Linux 就自動開起來、經反向隧道接上 Gateway。使用者從 Gateway 登入那台 Linux，再從它碰到家人家裡的網路。

現在的池子做不到這件事。provider 的登錄只能在節點本身上跑，而且會把 `GH_POOL_TOKEN`（整座池的控制權）存進節點。家人的電腦不能放這把權杖。

## What Changes

- **新的承載機種類：維修承載機（repair host）。** 在池裡是一台 `role=provider` 的機器：`mlp ls` 看得到，AI 的機器清單也看得到（使用者決定）。它**不承載 worker**、**不持有 GitHub 權杖**、**不跑 `pool-sync`**，只跑 `pool-tunnel` 的靜態模式。
- **在使用者的 Mac 上替它完成全部登錄。** 新的 `ops-scripts` 指令會產生隧道金鑰、寫入 `NODE_<NAME>`、觸發 authorized keys 的刷新，並把私鑰、登入公鑰與設定打包成 VM 用的開機資料。家人那邊不必做任何設定。
- **VM 與 Windows 啟動器。** 用 VirtualBox 跑 Ubuntu cloud image，網路用 NAT。sshd 只聽 `127.0.0.1`，家人網路上的其他裝置碰不到它。啟動器（PowerShell）只做四件事：問並記住 Gateway IP、把 IP 交給 VM、無頭開機、顯示「維修連線中，關掉此視窗即中斷」。首次需要安裝 VirtualBox 並按一次 UAC。
- **`pool-tunnel` 的靜態模式可以指定 Gateway 的 SSH port。** 現在它寫死 22，Gateway 實際跑在 2100，照原樣做會連不上。
- **兩道守衛。** 一道擋「權杖出現在維修承載機上」；另一道讓 create-worker 拒絕沒有宣告 `worker-host` 的 provider。現在「不承載 worker」只是慣例，有人指名這台就會嘗試在上面建 worker。

**不在範圍內**（使用者決定）：
- 收窄隧道金鑰的權限：現況每把隧道金鑰都能在 Gateway 上拿到 `sshproxy` 的 shell，本輪不改。
- 不讓 AI 看到這台：AI 會看到它，並且能在家人的網路裡執行指令。
- 橋接網路：只做 NAT。

## Capabilities

### New Capabilities
- `repair-host`：不承載 worker、不持有 GitHub 權杖的承載機，從使用者的 Mac 登錄，在家人的 Win10 上以 VM 形式運作並自動接上 Gateway。

### Modified Capabilities
（無；本 repo 的 openspec 目前沒有主規格）

## Impact

- 新增：`profiles/provider/repair/`（或同等名稱）、`ops-scripts/` 下的登錄與打包指令、啟動器素材、`docs/` 下一份設計與操作文件、對應的測試
- 修改：`shared-configs/pool-runtime/files/pool-tunnel`（靜態模式的 port）、`.github/workflows/create-worker.yml`（capability 閘門）
- 跨 repo：MyAiEntry 不用改。它會把這台列成「承載機，未宣告能力清單」
- 真機：Gateway 會多一把隧道公鑰和一個 provider port（2220–2299 段，人工挑選）；最終驗收要在一台真的 Win10 上做
