## Context

動機見 proposal.md，行為要求見 `specs/repair-host/spec.md`。影響做法的現況（出自 2026-09-28 的唯讀調查，證據附 `檔案:行號`，存在 PM 的 scratchpad `OUT-issue6-recon.md`）：

- **隧道金鑰沒有任何限制**：Gateway 上 `sshproxy` 的 authorized_keys 全是裸公鑰。一把外洩的隧道私鑰能拿到 `sshproxy` 的 shell（不是 root），也能監聽任意 port。使用者決定本輪**不收窄**。
- **`pool-tunnel` 的靜態模式**：`POOL_GATEWAY_HOST/PORT/USER` 三個都給時，不呼叫 `pool-resolve`、不碰 GitHub。但它**不設 Gateway 的 SSH port**，最後會用預設的 22；Gateway 實際是 2100。
- **`register-provider` 只能在節點本身上跑**，第 2 步會把 `GH_POOL_TOKEN` 存進節點。能在 Mac 上代做的只有第 4、5 步（config、`NODE_<NAME>`）與金鑰的 publish／refresh。
- **create-worker 不看 capabilities**，只要 `role=provider` 就能被指名。
- **fail2ban 用 Ubuntu 預設**（repo 沒有覆寫）：10 分鐘內 5 次失敗就封 10 分鐘。`pool-tunnel` 的 backoff 上限 30 秒，金鑰失效時約 1 分鐘就會被封。
- **provider port（2220–2299）是人工挑的**，沒有配發器。
- **MyAiEntry 會把每台 `role=provider` 都列給 AI**，而列出來就等於 AI 能在上面執行指令。使用者決定讓 AI 看到這台。
- 使用者的 Mac 是 Apple Silicon，無法在本機跑 x86 的 VirtualBox VM。

## Goals / Non-Goals

**Goals:**
- 家人那端沒有任何需要設定的東西，也不碰 GitHub
- 家人的電腦裡不放能控制整座池的東西（GitHub 權杖）
- 家人網路上的其他裝置碰不到 VM

**Non-Goals（使用者決定）：**
- 收窄隧道金鑰的權限
- 不讓 AI 看到這台
- 橋接網路、mDNS、掃區網
- 不隨 Gateway rotate 改變的穩定名稱（DDNS 已廢；rotate 後由家人重新輸入 IP）

## Decisions

**D1. VM 用 Ubuntu cloud image ＋ cloud-init NoCloud 開機資料，不在 Mac 上建整份映像。**
Mac（Apple Silicon）跑不了 x86 的 VirtualBox，所以不能在本機用 Packer 建映像再匯出。改成：映像用官方的 Ubuntu cloud image（amd64），每台家人電腦的差異全部放進一份 NoCloud 開機資料（seed ISO）。內容包括隧道私鑰、登入公鑰、節點名稱、provider port、`pool-tunnel` 腳本與 systemd unit。開機資料在 Mac 上就能產生，只要檔案工具，不需要跑 VM。
前提要先驗：cloud image 在沒有網路安裝套件的情況下，就能跑起 `pool-tunnel`（它需要的是 bash 和 ssh）。
替代方案：Packer 或 Vagrant 建整份映像（否決，Mac 上做不到）；WSL2（否決，Win10 上的 WSL2 無法單獨成為一台被登入的機器，行為也跟 VM 不同）。

**D2. 啟動器和 VM 之間怎麼傳 Gateway IP 與連線狀態：先做 spike 再定。**
候選有三個，spike 要在一台 Win10 上實測：
- VirtualBox guest property：需要 VM 裡有 Guest Additions，cloud image 沒有
- 每次啟動時重建一份小的設定 ISO：PowerShell 可以透過 Windows 內建的 IMAPI2 COM 產生
- VM 經 NAT 的 `10.0.2.2` 向啟動器在 `127.0.0.1` 上開的小服務取值、回報狀態
選擇的標準依序是：不需要系統管理員權限、零額外安裝、能雙向傳（啟動器需要知道隧道有沒有接上，才能顯示 spec 要求的「連不上」訊息）。

**D3. `pool-tunnel` 的靜態模式加一個選填的 SSH port 環境變數（例如 `POOL_GATEWAY_SSH_PORT`）。**
沒給時維持現在的行為（22），所以既有呼叫端（worker 的退路）不受影響。維修承載機的開機資料寫入 2100。家人只輸入 IP，不用輸入 port。

**D4. 在 Mac 上登錄的新指令，和 `register-provider` 共用寫 `NODE_<NAME>` 的邏輯，不另抄一份。**
新指令（暫名 `register-repair-host`）接收名稱、provider port、登入公鑰：
- 檢查 port 沒被其他 `NODE_*` 佔用
- 在 Mac 上產生隧道金鑰。這是刻意偏離「私鑰不離開產生它的機器」的規則：私鑰的目的地本來就是家人的 VM，而家人那端不能做任何設定
- 寫入 `NODE_<NAME>`：`role: provider`、`capabilities: {}`、沒有 `power`、`hops` 指向 VM 裡的登入使用者
- publish 公鑰、觸發 refresh，產出開機資料
`register-provider` 裡寫 `NODE_<NAME>` 的那段抽成共用函式，兩邊一起用。

**D5. 權杖守衛放兩處：開機資料產生時，以及 VM 啟動隧道前。**
開機資料的產生器拒絕任何含 GitHub 權杖的輸入。VM 上的 unit 在啟動前檢查：權杖檔存在，或環境裡有 `GH_*` 權杖變數，就拒絕啟動並記錄原因。

**D6. create-worker 在寫入任何狀態之前，檢查 provider 有沒有宣告 `worker-host`。**
放在現有「`role == provider` 且名字在清單」那一步。沒有宣告就失敗並說明原因。這會同時擋住既有 provider 裡沒宣告 `worker-host` 的機器，實作時要先查三台現役 provider 都有宣告，否則會把它們擋掉。

**D7. 維修承載機的重試節奏：連續被拒時把間隔拉到 fail2ban 的觀察窗以上。**
預設值下（10 分鐘內 5 次封 10 分鐘），連續認證失敗後的重試間隔要讓 10 分鐘內的失敗次數不到 5 次。確切的數字與「被拒」的判斷方式由實作決定並寫進註解。只有維修承載機的模式這樣做，其他節點的 backoff 不動。

**D8. 登入公鑰預先放進開機資料。**
撤銷的方式是使用者登入後自己改，或重做一份開機資料。這比一般 provider 難撤，但 sshd 只聽 loopback，要登入必須先能進 Gateway，等於多了一道門。

## Risks / Trade-offs

- [家人電腦裡的隧道私鑰外洩 → 對方拿到 Gateway 上 `sshproxy` 的 shell，也能監聽任意 port] → 使用者知情後決定本輪不收窄；寫進 known limitations，之後要收窄全池時一併處理
- [AI 能在家人的網路裡執行指令] → 使用者決定；MyAiEntry 會把它列成「承載機，未宣告能力清單」
- [Gateway rotate 後 IP 會變，VM 只能 `accept-new` 新的 host key] → 家人重新輸入 IP，啟動器顯示看得懂的訊息；`accept-new` 的風險是第一次連線時可能連到假冒的 Gateway，但對方最多拿到一個指向 VM sshd 的轉發，登入仍要使用者的金鑰
- [Windows 那一端在 Mac 上測不了] → 啟動器只做靜態檢查與單元測試；D2 的 spike 和最終驗收都要一台真的 Win10，**需要使用者安排**
- [家人的電腦已經開了 Hyper-V，VirtualBox 會退到比較慢的模式] → 寫進操作文件
- [D6 可能擋掉現役的 provider] → 實作前先查三台現役 provider 的 capabilities
- [多台家人電腦] → 一台一份開機資料（名稱、port、金鑰各自獨立）；port 仍然人工挑，但 D4 會擋掉衝突

## Migration Plan

新功能，不影響既有節點。只有兩處會碰到既有行為：D3 在不給新變數時維持原狀；D6 會讓指名沒宣告 `worker-host` 的 provider 失敗。
撤掉一台維修承載機：刪掉 `NODE_<NAME>`、觸發 refresh（它的隧道公鑰就會從 Gateway 移除），家人電腦上的 VM 從此接不上。

## Open Questions

- D2 的傳遞方式：spike 決定，不影響 specs
- VirtualBox 安裝檔要不要跟啟動器一起打包，還是請家人另外下載（授權與檔案大小）：spike 時一起確認
