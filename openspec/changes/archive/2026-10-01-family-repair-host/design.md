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
spike 已驗（2026-09-29）：noble amd64 cloud image 只給 NoCloud seed、沒有 `packages:`，在 VirtualBox NAT 下約 35 秒接上隧道；映像已內建 bash、openssh、jq、netcat、curl、python3（沒有 bzip2）。實作要注意：
- Ubuntu 24.04 的 sshd 是 socket activation：首次開機時 `ListenAddress` 生效得比 cloud-init 寫設定早，sshd 會先聽 `0.0.0.0:22` 約 30 秒，`runcmd` 要 `systemctl daemon-reload && systemctl restart ssh.socket`（NAT 沒有 port forward，這段時間外面也連不到）
- 屬於 cloud-init 建立的使用者的檔案要 `write_files … defer: true`
- unit 用 system unit 加 `User=`，比 user unit 加 linger 在 cloud-init 裡簡單
- 家人的區網若剛好是 `10.0.2.0/24`，會跟 VirtualBox NAT 的預設網段撞，要能用 `--natnet1` 換
替代方案：Packer 或 Vagrant 建整份映像（否決，Mac 上做不到）；WSL2（否決，Win10 上的 WSL2 無法單獨成為一台被登入的機器，行為也跟 VM 不同）。

**D2. 啟動器和 VM 之間用 HTTP：啟動器在 `127.0.0.1` 上開一個小服務，VM 經 NAT 的 `10.0.2.2` 連過去。**（2026-09-29 spike 定案，`OUT-spike-repair.md`）
VM 從這個服務取得 Gateway IP，並把隧道狀態回報給它（啟動器用來顯示「連不上」的訊息）。實測結果：在非系統管理員的 token 下，`http://127.0.0.1:<port>/` 的 HttpListener 不需要 URL ACL；VirtualBox NAT 會把 `10.0.2.2` 轉到主機的 loopback；兩端都只用內建工具（PowerShell 5.1／.NET、映像自帶的 curl）。啟動器建 VM 時要**明確**設 `--nat-localhostreachable1 on`，不依賴預設值；固定 port 要有備案（撞埠時換下一個）。
另外保留**序列埠寫檔**（`--uart-mode1 file`）當診斷通道，讓啟動器看得到 VM 的開機紀錄。
替代方案：(a) VirtualBox guest property——可行也是雙向，雲映像的核心已帶 vboxguest 驅動，但 VM 裡要放一份跟 VirtualBox 版本綁在一起的 `VBoxControl`，列為備案；(b) 每次啟動重做一張設定 ISO（IMAPI2，不用系統管理員）——只能單向，否決。

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
- [以一般使用者（非系統管理員）身分執行 `VBoxManage` 沒有實證] → spike 在提權的 ssh session 裡做，模擬一般使用者的 token 又被 VirtualBox COM 拒絕（`E_ACCESSDENIED`，是模擬方法的限制）。三種 D2 方案都要用 `VBoxManage`，所以**真機驗收一定要在桌面 session、非提權的狀態下跑一次**；文件要提醒家人不要「以系統管理員身分」開 VirtualBox（提權與非提權的 VirtualBox 行程彼此連不上）
- [`restrict`＋`permitlisten` 擋不住遠端執行指令] → spike 在 Win32-OpenSSH 上實測；OpenSSH 的語意相同。日後若要收窄隧道金鑰，光靠 permitlisten 不夠，而 `pool-tunnel` 的健康檢查與 state 抓取都要在遠端執行指令，也不能直接加 `command=`
- [Windows 那一端在 Mac 上測不了] → 啟動器只做靜態檢查與單元測試；D2 的 spike 和最終驗收都要一台真的 Win10，**需要使用者安排**
- [家人的電腦已經開了 Hyper-V，VirtualBox 會退到比較慢的模式] → 寫進操作文件
- [D6 可能擋掉現役的 provider] → 實作前先查三台現役 provider 的 capabilities
- [多台家人電腦] → 一台一份開機資料（名稱、port、金鑰各自獨立）；port 仍然人工挑，但 D4 會擋掉衝突

## 改版：臨時跳板（2026-09-30）

使用者在第一版真機驗收後要求改成「臨時跳板」。D4（每台在 Mac 上登錄一個 `NODE_<NAME>`）、D8 的一部分、與「AI 看得到這台」一起作廢；其餘決定照舊。使用者的裁示：
- `mlp` 自己掃出在線的跳板，不寫進 GitHub var
- 跳板用自己的 port 段，約 100 個，跟 provider、worker 分開
- 手機（MyAiEntry）完全不知道它們存在
- GitHub var 只登錄**一把**公鑰，所有跳板共用；**不收窄**（跟其他隧道金鑰一樣）
- 名字由家人在啟動器裡、跟 Gateway IP 一起輸入
- 撤銷任何一位＝換掉共用金鑰、全家重裝（家人不多，可接受）
- 在同一分支上改，第一版不 merge

**D9. 一把共用的隧道金鑰。** 使用者在 Mac 上跑一次設定指令：產生金鑰對、把公鑰寫進 GitHub var `REPAIR_TUNNEL_PUBKEY`（單行公鑰，不是 JSON；名字刻意避開 `NODE_`／`CLIENT_` 前綴，前者會被當 JSON 檢查、後者會進登入清單）、觸發 refresh；私鑰留在 Mac 本機（不進 repo）。收錄寫在 refresh 與 rotate **共用**的組裝函式裡——只改 refresh workflow 的話，rotate 出來的新 Gateway 會漏掉它、全家失聯。變數不存在＝沒有跳板，照常；存在但不是合法公鑰＝大聲失敗。換金鑰＝重跑同一條指令，舊金鑰隨下一次 refresh 失效。

**D10. 專用 port 段 2400–2499。** Gateway 端不用改設定（反向轉發只綁 loopback，沒有防火牆或 `PermitListen`）。VM 開機時從段首開始試，被佔用（`remote port forwarding failed`）就換下一個；整段都滿就從頭再繞，啟動器沿用「一直沒接上」的逾時訊息（不另加狀態；家庭規模遠低於 100）。forward 失敗發生在認證成功之後，現行分類已歸為不計入 fail2ban 的快退；換 port 只在這一類失敗發生，**認證失敗絕不換 port**，並補測試。

**D11. `mlp` 掃描 Gateway 找出在線的跳板。** `mlp ls` 顯示它們（跟 provider、worker 分開一區），`mlp ssh <名字>` 與 `mlp ssh <port>` 能連上。取名（2026-09-30 定案，依 `OUT-recon-ephemeral.md` §3）：VM 在 port 接上後，經同一條隧道連線在 Gateway 上寫 `~sshproxy/repair/<port>`（內容是名字），正常關機時刪掉。`mlp` 在一次 Gateway 連線裡同時讀這個目錄與實際的 listener：**listener 是事實，檔案只是名牌**——有檔沒 listener 不顯示，有 listener 沒檔顯示為「無名」。同名時列出 port，`mlp ssh <名字>` 拒絕並要求改用 port。不做「登入 VM 讀 hostname 驗證」：冒名者一樣改得了 hostname，擋不住冒名。
port 段的唯一來源是 `NODE_GATEWAY.ports.repair`（`[2400,2499]`）；`mlp` 讀它（讀不到就大聲拒絕，不寫死 fallback），VM 端的值在打包時從它抄進開機資料。`pool-status` 的「Gateway listener 2000–2999」摘要行會自然列出跳板的 port（只有數字、沒有名字），不改。

**D12. 啟動器同時問名字與 IP，並記住兩者。** 名字的格式限制在啟動器與 VM 兩端都檢查（小寫英數與 `-`）。VM 用它當 hostname。

**D13. 安裝包不含任何「每台不同」的東西。** 同一份包可以交給全家；內容：共用隧道私鑰、CLIENT_* 公鑰快照（照舊排除 CLIENT_ACTIONS）、Gateway 的 SSH port、映像的 SHA256。打包不碰 GitHub（除了讀 CLIENT_* 快照）。

**D14. 手機看不到。** 不寫 `NODE_*`、不進 state 快取、不出現在 MyAiEntry 讀的任何資料裡。

**第一版的處置：** `register-repair-host` 與它的測試、parity 守衛由新指令取代；D3（靜態模式 port）、D5（權杖守衛）、D6（create-worker 閘門）、D7（退避）、D1／D2（VM 與啟動器）保留。現役的 `fam-test`（`NODE_FAM_TEST`、2240）在新版真機驗收通過後撤掉。

**改版帶來的新風險：**
- 共用私鑰：任何一位家人的電腦外洩，對方拿到 Gateway 上 `sshproxy` 的 shell，也能冒充任何一位家人、佔住整段 port。使用者知情後決定不收窄
- 名字是家人自己打的，沒有認證：任何拿到包的人都能自稱任何名字；`mlp ssh` 連上後仍要使用者的金鑰才能登入，但**使用者可能登入到冒名的機器**
- 撤銷要全家重裝

## Migration Plan

新功能，不影響既有節點。只有兩處會碰到既有行為：D3 在不給新變數時維持原狀；D6 會讓指名沒宣告 `worker-host` 的 provider 失敗。
撤掉一台維修承載機：刪掉 `NODE_<NAME>`、觸發 refresh（它的隧道公鑰就會從 Gateway 移除），家人電腦上的 VM 從此接不上。

## Open Questions

- VirtualBox 安裝檔要不要跟啟動器一起打包，還是請家人另外下載（授權與檔案大小）：spike 時一起確認
