# MyLinuxPool 運維手冊（RUNBOOK）

> 只給人看的操作文件。系統行為的契約在 `POOL_RUNTIME_SPEC.md`，設計理由在
> `ARCHITECTURE.md`。這裡的指令都假設你站在正確的機器上，照著做即可。

## 目錄

1. [新增一台 provider](#1-新增一台-provider)
2. [Gateway rotate 之後要做什麼](#2-gateway-rotate-之後要做什麼)
3. [更換 GH_POOL_TOKEN](#3-更換-gh_pool_token)
4. [Fh-proxy 的 Windows 側設定](#4-fh-proxy-的-windows-側設定)
5. [故障排除](#5-故障排除)
6. [已知環境限制](#6-已知環境限制)

---

## 1. 新增一台 provider

一台全新的機器加入叢集，只需要**人工跑一次** `provider/register.sh`。
之後無論 Gateway 換幾次，這台機器都不用再碰（見 §2）。

### 1.1 前置：兩個環境變數

`register.sh` 需要兩個環境變數，缺任一個會以退出碼 `2` 中止：

| 變數 | 是什麼 | 從哪來 |
|---|---|---|
| `FILE_CRYPTO_KEY` | 對稱解密金鑰（信任根） | 你保管的密碼，與 GitHub secret 同名 |
| `GH_POOL_TOKEN` | fine-grained PAT，能讀 repo vars、clone 私有 repo | GitHub → Settings → Developer settings → Fine-grained tokens |

這是整套系統中**唯一的人工輸入機密**。不要在指令歷史、log 或聊天中留下它們。

> **`GH_POOL_TOKEN` 只需要 repo 權限（Contents: Read、Variables:
> Read/Write），不要多給。** 實測過：`gh auth login --with-token` 會強制要求
> `read:org`，我們的操作（`gh api` 讀 variable、`gh variable set`、
> `gh repo clone`）完全用不到，所以 `register.sh` 根本不呼叫
> `gh auth login`——見 §1.3 第 2 步與 §3。多給 `read:org` 沒有壞處，但也
> 沒有必要。

### 1.2 操作步驟

在新 provider 上：

```bash
export FILE_CRYPTO_KEY='...'   # 信任根
export GH_POOL_TOKEN='...'     # 取得私有 repo 的鑰匙

bash <(curl -fsSL ...)  # 或：先手動把 repo 的 provider/register.sh 傳上去再執行
bash provider/register.sh --name <node-name> --gateway-port <port>
```

`--name` 是這台機器在叢集中的名字（`gateway`、`fh-l`、`fh-proxy`）。
`--gateway-port` 是它在 Gateway 上佔用的固定埠（provider 段 2220–2299；
現況：`fh-l` = 2222、`fh-proxy` = 2226）。

`--branch <name>`（預設 `master`）：開發期間 `pool/` 還在功能分支上、尚未併回
`master` 時，指向該測試分支，例如：

```bash
bash provider/register.sh --name fh-l --gateway-port 2222 --branch feat/refactor-as-mylinuxpool
```

正式上線（分支已併回 `master`）之後，不帶 `--branch` 直接跑預設值即可。
腳本會在 repo 已存在但分支不對時自動 `fetch` + `checkout` 到指定分支，
不會對錯分支做 `pull`。

`--no-sudo`：這台機器的 sudo 密碼不明或拿不到時使用（例如 fh-proxy）。
第 1 步不會呼叫 `apt`，改成：

- `jq`、`gh`：從 GitHub releases 抓對應平台的執行檔，裝進 `~/.local/bin`
  （並把 `~/.local/bin` 冪等地加進 `~/.bashrc` 的 `PATH`，供你手動操作用；
  `pool-tunnel.service` 另外會被寫入自己的 `Environment=PATH=...`，
  不依賴 shell rc 檔）
- `rclone`：provider 本來就用不到（只有 Gateway 的 `dlpw`/`uppw` 要），
  缺少時只印一則 INFO 跳過
- `git`／`docker`／`openssh-server`：這三個沒有免 root 的裝法，缺少時會
  直接報錯並印出需要請人手動 `sudo apt-get install` 的訊息，**不會**靜默略過

第 7 步（sudoers）在 `--no-sudo` 下整步跳過，只印 INFO：這台機器沒辦法被
遠端 `sudo systemctl poweroff`，`Shutdown Fh-l` 那類電源操作對它不適用——
但本來就只有常駐型 provider（如 fh-proxy）會走 `--no-sudo`，這類機器本來
也不需要遠端關機。

> **殘留的例外**：第 8 步的 `loginctl enable-linger` 一般也需要 root。
> `--no-sudo` 下腳本會先嘗試不帶 sudo執行，若這台主機的 systemd/polkit
> 版本允許使用者自己開 linger 就會成功；若不允許，腳本會報錯並印出
> 唯一還需要人工介入一次的指令：`sudo loginctl enable-linger <user>`。
> 開完之後，其餘所有步驟都不需要再碰 root。

### 1.3 腳本會做的事（你只需要看它跑完）

| # | 階段 | 內容 |
|---|---|---|
| 1 | 前置檢查 | bash、`systemctl --user`、網路；缺 `rclone`/`git`/`gh`/`docker`/`openssh-server` 就以 apt 安裝（`--no-sudo` 下改成使用者層級安裝 `jq`/`gh`，見上） |
| 2 | 存 gh token | 把 `GH_POOL_TOKEN` 寫進 `~/.mylinuxpool/gh_token`（600），並 `export GH_TOKEN`；**不呼叫** `gh auth login`（見上方 `read:org` 說明） |
| 3 | 取得 runtime | clone repo（`--branch` 指定分支，預設 `master`）到 `~/.mylinuxpool/repo`，`pool/bin/*` 複製到 `~/.mylinuxpool/bin/` 並 `chmod +x` |
| 4 | 金鑰 | 從 `static_secret_files/home/sshproxy/.ssh/id_rsa.crypted` 解密出 `~/.ssh/id_pool`（600）。所有 provider 共用同一把，公鑰已在 Gateway 的 `authorized_keys` |
| 5 | 身分 | 寫 `~/.mylinuxpool/config`：`NODE_NAME=<name>` |
| 6 | 登記 | `gh variable set NODE_<NAME>`，內容依 `ARCHITECTURE.md` §3 schema；已存在則合併 |
| 7 | sudoers | 寫 `/etc/sudoers.d/mylinuxpool`（440）：只放行 `systemctl poweroff` 與 `ethtool`。**這步會互動要 sudo 密碼**；`--no-sudo` 下整步跳過 |
| 8 | 常駐 | 安裝 `pool-tunnel.service` 到 user systemd、`enable --now`、`loginctl enable-linger`；`--no-sudo` 下額外把 `~/.local/bin` 寫進 unit 的 `PATH` |
| 9 | 驗收 | 從 Gateway 端確認 `127.0.0.1:<gateway-port>` 回得出 SSH banner |

腳本具冪等性：重複執行安全，每一步先檢查現況再動作。**驗收失敗會以非零退出碼結束並印診斷。**

### 1.4 驗收後自我檢查

在 Gateway 上：

```bash
ss -tlnp | grep <gateway-port>
timeout 2 nc -z -v 127.0.0.1 <gateway-port>
```

在 provider 上：

```bash
systemctl --user status pool-tunnel
journalctl --user -u pool-tunnel -n 30 --no-pager
loginctl show-user "$USER" | grep Linger   # 必須是 Linger=yes
```

---

## 2. Gateway rotate 之後要做什麼

**什麼都不用做。**

原因：provider 需要從外界知道的資訊只有一項 —— `NODE_GATEWAY`。它每 30 秒
自己去 GitHub 讀這個 var（經 `pool-resolve`），發現 `ip` 或 `generation` 變了就
立刻重建隧道。rotate 改的就是這一個 var，所以：

- provider 上的 `NODE_<NAME>` 不用動 —— 它的 `hops` 是 `{"via":"gateway"}`，是遞迴引用，不是寫死 IP；
- provider 上的金鑰、config、service 都不用動；
- 不需要在 provider 上重跑 `register.sh`。

實際斷線時間 ≈ 一個輪詢週期 + 一次 ssh 重建，約 40 秒內自行恢復。

> 若 rotate 後超過 **2 分鐘**還沒恢復，才需要人工介入 —— 直接跳 §5.1。

---

## 3. 更換 GH_POOL_TOKEN

`GH_POOL_TOKEN` 是 fine-grained PAT，**會過期**。過期當天，provider 會開始
拿不到 `NODE_GATEWAY`、隧道重建失敗，journal 會出現 `HTTP 401`。
程序固定是四步：改 secret → 重新加密檔案 → commit → 各 provider 重跑註冊。

### 3.1 產生新 token

GitHub → Settings → Developer settings → Fine-grained tokens → 新建。
權限：**只給這個 repo 的 Variables: Read、Contents: Read**（Worker 用的
`GH_WORKER_TOKEN` 更窄：只有 Variables: Read，另見 `ARCHITECTURE.md` §3）。

### 3.2 更新 GitHub secret

```bash
gh secret set GH_POOL_TOKEN --repo FATESAIKOU/MyLinuxPool
```

（貼上新 token；`GH_WORKER_TOKEN` 若也有 rotate 一併更新。）

### 3.3 重新加密 repo 內的佈署檔

在持有 `FILE_CRYPTO_KEY` 的信任機器上：

```bash
# 1. 解出舊檔
cat static_secret_files/<path>/gh_pool_token.crypted \
  | scripts/decryptStdin.sh "$FILE_CRYPTO_KEY" > /tmp/gh_pool_token

# 2. 換成新 token（編輯 /tmp/gh_pool_token，只留純 token 一行）

# 3. 重新加密回原位
cat /tmp/gh_pool_token \
  | scripts/encryptStdin.sh "$FILE_CRYPTO_KEY" \
  > static_secret_files/<path>/gh_pool_token.crypted

# 4. 立刻清掉明文
rm -f /tmp/gh_pool_token

# 5. commit
git add static_secret_files/<path>/gh_pool_token.crypted
git commit -m "Rotate GH_POOL_TOKEN"
git push
```

> 加解密參數與 `FILE_CRYPTO_KEY` 的用法見 `POOL_RUNTIME_SPEC.md` §7 與
> `scripts/{en,de}cryptStdin.sh`。**明文嚴禁進版控、日誌或指令參數以外的紀錄。**

### 3.4 各 provider 重跑哪一段

不需要整台重新註冊。在每台 provider 上（`fh-l`、`fh-proxy`）：

```bash
export GH_POOL_TOKEN='<新 token>'
export FILE_CRYPTO_KEY='...'

# 冪等，可直接整支重跑；它會依序做：覆寫 ~/.mylinuxpool/gh_token → git pull → 重裝 bin
bash ~/.mylinuxpool/repo/provider/register.sh \
  --name <node-name> --gateway-port <gateway-port>

systemctl --user restart pool-tunnel   # register.sh 第 8 步會做，手動保險亦可
```

對應到 `register.sh` 的**第 2 步（把新 token 寫進 `~/.mylinuxpool/gh_token`）與
第 3 步（git pull + 更新 bin）**；第 6 步之後的登記與常駐設定若無變動會自動跳過。
`pool-tunnel`／`pool-resolve` 下次執行時會自己從 `~/.mylinuxpool/gh_token` 讀到
新 token，不需要任何 `gh auth` 狀態要處理。驗證：

```bash
cat ~/.mylinuxpool/gh_token | wc -c              # 確認檔案內容已換成新 token 的長度
~/.mylinuxpool/bin/pool-resolve gateway --refresh >/dev/null && echo OK
journalctl --user -u pool-tunnel -n 20 --no-pager
```

---

## 4. Fh-proxy 的 Windows 側設定

Fh-proxy 是 WSL2。**Windows 的開機不會自動啟動 WSL，WSL 沒起來 systemd
就不存在，隧道也就不存在。** 這一段無法從 Linux 側自動化，必須在 Windows 上
設定一次。以下皆以 Fh-proxy 的 Windows 主機為準。

### 4.1 已存在的三個工作排程器項目

| 工作名稱 | 作用 |
|---|---|
| `KeepWSL-Ubuntu-24.04-Alive-Boot` | 於**開機時**觸發，把 WSL Ubuntu 24.04 拉起來（`wsl.exe` 執行一個 no-op），讓 WSL 內的 systemd 開始跑，`pool-tunnel.service` 才會被帶起來 |
| `KeepWSL-Ubuntu-24.04-Alive-Minute` | 每分鐘檢查一次，若 WSL 已被關掉（例如閒置回收）就再把它拉起來；WSL 活著時等於 no-op |
| `Start WSL` | 手動用的啟動項目，需要臨時叫醒 WSL 時可直接執行 |

> 這三個項目已經存在，**不需要新建**；本節只是記錄它們的職責。檢查狀態：

```cmd
schtasks /query /tn "\KeepWSL-Ubuntu-24.04-Alive-Boot" /fo LIST /v
schtasks /query /tn "\KeepWSL-Ubuntu-24.04-Alive-Minute" /fo LIST /v
schtasks /query /tn "\Start WSL" /fo LIST /v
```

### 4.2 WoL 需要的靜態 ARP 綁定

`Launch Fh-l` 由 Fh-proxy 的 WSL 以 **unicast** magic packet 送到
`192.168.0.136`。unicast 需要送出端能把 IP 解析成 MAC；fh-l 長時間關機後
ARP 快取會過期（實測狀態是 `Stale`），封包就送不出去。

在 Windows 主機以**系統管理員**身分開 `cmd`，執行（網路介面名稱是 `Wi-Fi`）：

```cmd
netsh interface ip add neighbors "Wi-Fi" 192.168.0.136 b4-2e-99-fb-63-5e store=persistent
```

若回報「物件已存在」，改用：

```cmd
netsh interface ip set neighbors "Wi-Fi" 192.168.0.136 b4-2e-99-fb-63-5e store=persistent
```

`store=persistent` 讓它撐過重開機。驗證：

```cmd
netsh interface ip show neighbors "Wi-Fi"
```

`192.168.0.136 → b4-2e-99-fb-63-5e` 的狀態必須是 **`Permanent`**，不是 `Stale`。

> 為什麼要做在 Windows 而不是路由器：送出端（Windows `192.168.0.199`）與
> 目標在同一個 /24，同網段不經路由器轉送，ARP 是 Windows 自己解析的。

### 4.3 路由器上的 DHCP 位址預約

Windows 靜態 ARP 解決「送得到」，位址預約解決「**醒來後還是同一個 IP**」。
fh-l 長時間關機後租約到期，若拿到別的 IP，unicast 目標就錯了。

在路由器管理介面替 fh-l 建立位址預約：

| 欄位 | 值 |
|---|---|
| 名稱 | `fatesaikou-home`（或你認得的名字） |
| MAC | `B4-2E-99-FB-63-5E` |
| 預約 IP | `192.168.0.136` |
| ステータス／啟用開關 | **必須打開** |

設定完成後，在 Windows 上以 `ipconfig /all` 或 ping 確認 fh-l 開機後仍是
`192.168.0.136`。

---

## 5. 故障排除

> **先跑 `pool/bin/pool-status`。** 它會一次檢查本機前置、Gateway 可達性、
> 每個 provider 的隧道與 SSH banner、以及 worker 埠與佔位檔的一致性，
> 並在 TCP 被立即拒絕時主動提示去查 fail2ban（§7.1 那次事故的正確診斷
> 順序已內建其中）。有 FAIL 才往下看對應小節。


### 5.1 隧道沒起來

**症狀**：從 Gateway `ssh -p <port> 127.0.0.1` 連不上；`Launch`/`Create Worker`
的驗收步驟卡住；`pool-status` 顯示埠不在聽。

在 provider 上：

```bash
systemctl --user status pool-tunnel          # 服務是否在跑、重啟幾次
journalctl --user -u pool-tunnel -n 100 --no-pager
loginctl show-user "$USER" | grep Linger     # 必須 Linger=yes
ls -l ~/.mylinuxpool/run/                    # ControlMaster socket 是否殘留
cat ~/.mylinuxpool/gh_token >/dev/null       # token 檔存在嗎（見 5.3）
~/.mylinuxpool/bin/pool-resolve gateway      # 讀得到 var 嗎
```

判讀：

- 服務一直重啟、journal 出現 `remote port forwarding failed` → Gateway 端舊
  listener 還佔著埠。等 30 秒退避或重啟服務；`ExitOnForwardFailure=yes` 會讓它
  誠實失敗，不會假裝健康。
- journal 出現 `HTTP 401` / `403` → token 過期，跳 §3。
- `Linger=no` → `sudo loginctl enable-linger $USER` 後重啟服務。
- socket 殘留 → 服務重啟時會自行清理；手動清可 `rm -f ~/.mylinuxpool/run/ctl-gateway.sock`。

在 Gateway 上：

```bash
ss -tlnp | grep <port>
timeout 2 nc -z -v 127.0.0.1 <port>
```

若 provider 端一切正常但 Gateway 端埠不在聽，**rotate 一次 Gateway**（或先確認
`NODE_GATEWAY.generation` 是否已變）再看 provider 是否在 30 秒內自己重建。

### 5.2 WoL 喚不醒

依序檢查（每一層都可能單獨壞）：

1. **MAC / IP 是否正確** —— 對 `NODE_FH_L.power.launch` 的 `mac`、`target_ip`。
2. **Windows 靜態 ARP 還在嗎** —— §4.2 的驗證指令，狀態必須 `Permanent`。
3. **fh-l 的網卡 WoL 是否仍開** —— 開機時 `sudo ethtool eno1` 應顯示 `Wake-on: g`，
   `/sys/class/net/eno1/device/power/wakeup` 應為 `enabled`（兩者都要撐過重開機）。
4. **從 Fh-proxy 手動送一次** ——
   `~/.mylinuxpool/bin/pool-wol B4:2E:99:FB:63:5E 192.168.0.136`
   看退出碼（0 = 至少送出成功）與輸出。
5. **交換器 MAC 表** —— fh-l 關機很久時，交換器上的 MAC 條目會老化。理論上未知
   MAC 的 unicast 會被 flooding 到所有埠而仍送達；若第 4 步送出了卻沒醒，
   用 `tcpdump` 在 Fh-l 同網段驗證封包是否真的到達。
6. **路由器位址預約** —— §4.3 的開關是否真的開著（fh-l 可能換了 IP）。
7. **GRUB entry 0** —— 若喚醒後進了 Windows 而非 Ubuntu，Launch 的驗收會卡住；
   開機時肉眼確認，或請人進 console 修 `GRUB_DEFAULT`。

### 5.3 gh token 過期或無效

**症狀**：provider 的 `pool-resolve` 回退出碼 `4`（API 失敗且無快取）、
`pool-tunnel` journal 出現 `HTTP 401`。**沒有 `gh auth status` 這回事**——
`register.sh` 不呼叫 `gh auth login`，token 是透過 `GH_TOKEN` 環境變數
（`pool-resolve` 從 `~/.mylinuxpool/gh_token` 讀入）直接餵給 `gh`。

診斷：

```bash
cat ~/.mylinuxpool/gh_token | wc -c                         # 確認檔案存在、非空
GH_TOKEN="$(cat ~/.mylinuxpool/gh_token)" \
  gh api repos/FATESAIKOU/MyLinuxPool/actions/variables/NODE_GATEWAY --jq .value
```

- 若回報 403 而非 401 → token 還在，但**權限被拔**或 repo 改名，重新核發
  並給 **repo 權限（Contents: Read、Variables: Read/Write）即可，不需要
  `read:org`**。
- 401 → 依 §3 完整走一遍：改 secret → 重新加密 → commit → 各 provider 重跑
  `register.sh`（第 2 步會覆寫 `~/.mylinuxpool/gh_token`）。

> 注意：`pool-tunnel` 自己**不會**直接呼叫 `gh`，一律經 `pool-resolve`；
> 除錯時若看到 token 問題，要往 `pool-resolve` 的快取與 provider 上的
> `~/.mylinuxpool/gh_token` 找，不是 `~/.config/gh/hosts.yml`（那是
> `gh auth login` 的產物，這套流程不會建立它）。

---

## 6. 已知環境限制

這些是實測事實，不要重新假設，也不要嘗試用自動化繞過：

| 限制 | 說明 | 影響 / 對策 |
|---|---|---|
| **Fh-proxy 的 Windows PowerShell 無法使用** | PowerShell 起不來 —— 連經 `cmd.exe` 呼叫、等 35 秒都沒有任何輸出（`cmd.exe` 本身正常、檔案存在）。舊的 `launchfhubuntuForWsl2` 100% 靠 PowerShell 送封包，所以它**從來沒有送出過任何東西** | WoL 一律在 WSL 內用 `pool-wol` 送 unicast；不要設計任何依賴 PowerShell 的流程 |
| **WSL2 的 NAT 會丟掉 broadcast** | 從 WSL 送 `192.168.0.255` 與 `255.255.255.255`，目標端都收不到；**unicast 到 `192.168.0.136` 收得到**（tcpdump 實測）。此機 Windows 10 19045，無法用 mirrored networking | `pool-wol` 必須用 unicast；不要「優化」成廣播 |
| **兩台 provider 的 sudo 都需要密碼** | `fh-l`、`fh-proxy` 皆然 | 只有兩條路：`register.sh` 寫入範圍極窄的 sudoers（`systemctl poweroff`、`ethtool`，見 §1.3 第 7 步），或註冊時互動輸入。**不要把 sudo 密碼放進 GitHub 或任何自動化** |
| **Fh-proxy 的 Windows 側自動啟動無法從 Linux 自動化** | Windows 開機不會自動啟動 WSL；需要工作排程器（已存在，見 §4.1） | 在那之前，Fh-proxy 的「重開機自動復活」只涵蓋 WSL 內部，不涵蓋 Windows 重開機 |
| **Rotate 期間有感知延遲** | provider 每 30 秒輪詢 + ssh 重建 | 斷線約 40 秒內自癒；超過 2 分鐘才需人工（§5.1） |

---

## 附錄：本手冊沒有寫、但你會想知道的

- **日誌**：所有 pool 元件的日誌一律走 stdout/stderr → journald。
  看 log 用 `journalctl --user -u pool-tunnel`，**不要**去找任何檔案 log。
- **禁止事項**（`POOL_RUNTIME_SPEC.md` §7）：不用 autossh、不寫死 Gateway IP／主機名、
  不自行寫 log 檔、`pool-tunnel` 不直接呼叫 `gh`、機密不進 repo／log／命令列參數。
  這四條是紅線，故障排除時也不要為了「快點通」而違反。
- **Gateway 上的 `gh`**：健康檢測與埠配發都用不到它（Gateway 不參與定址輪詢，
  它只需要 `nc`/`timeout`/`flock`/`ss`/`jq`）。但 rotate 仍會裝 `gh`／`git`／`rclone`，
  純粹是為了人工排障方便，以及 `dlpw`／`uppw` 需要 `rclone`。
  **舊機（未經 rotate 重建者）上沒有 `gh`**，排障時別預期它存在。

---

## 7. 事故紀錄與教訓（2026-09-13/14 首次實機驗收）

### 7.1 Gateway 全面失聯 —— 兇手是 fail2ban，不是 sshd

**症狀**：Gateway 所有 TCP 埠瞬間回 RST（22、2226 都是），ICMP 正常，
Linode 顯示 running。從家中兩台機器（Mac 與 fh-l）都連不上。

**誤判過程（值得記住，以免重蹈）**：
先看到 `systemctl is-active ssh` 回 `inactive` 就判定 sshd 死了，於是重開機、
重設 root 密碼。**但 Ubuntu 24.04 預設是 socket 啟動（`ssh.socket`），
`ssh.service` 顯示 inactive 是正常的**，systemd 會按需拉起。那些動作全屬多餘。

**真正的原因**：

```
table inet f2b-table {
    set addr-set-sshd {
        elements = { ..., 138.64.68.94, ... }     ← 家中對外 IP 被封
    }
    chain f2b-chain {
        tcp dport 22 ip saddr @addr-set-sshd reject with icmp port-unreachable
    }
}
```

`reject with icmp port-unreachable` 產生的正是「瞬間 Connection refused」，
且只擋 tcp/22，所以 ICMP 照樣通 —— 症狀完全吻合。

**診斷指令**（下次先跑這個，不要急著重開機）：

```bash
nft list ruleset | head -30          # 看 f2b-table 的封鎖清單
iptables -L INPUT -n --line-numbers  # 舊式規則
systemctl is-active fail2ban
```

**解法**：

```bash
fail2ban-client set sshd unbanip <你的IP>
```

**已做的預防**：`/etc/fail2ban/jail.d/mylinuxpool-ignore.conf` 已把家中
對外 IP 加入 `ignoreip`。**此檔目前只存在於現行 Gateway，尚未納入
`static_normal_files`**——rotate 後會消失，Phase C 必須補上。

### 7.2 Gateway 掛掉會連帶讓 fh-proxy 失聯

fh-proxy 是 NAT 後的 WSL2，**沒有任何 inbound 路徑**：

- Windows 主機 `192.168.0.199` 的 ICMP 與所有常見 TCP 埠（22/135/139/445/
  3389/5985）皆封閉，ARP 解析得到但完全無法連入
- WSL2 本身又在 Windows 的 NAT 之後

它唯一的生命線就是那條對外撥出的隧道。隧道一斷，**遠端無法救援**，
必須有人到機器前面（或用 Google Remote Desktop）。

**這是目前架構最脆弱的一點。** 建議日後在 Windows 側開一個 inbound 通道
（例如 OpenSSH Server 並限制來源網段），作為隧道之外的第二條路。

### 7.3 LISH 主控台的正確設定方式

`linode-cli sshkeys create` 加的是「SSH Keys」清單（給建立新 Linode 時
佈署用），**不是** LISH 用的。LISH 讀的是 profile 上另一個欄位：

```bash
linode-cli profile update --authorized_keys "$(cat ~/.ssh/id_rsa.pub)"
ssh -t <linode帳號>@lish-<region>.linode.com <linode標籤>
```

當 SSH 完全進不去時，這是唯一的救命通道，**建議平時就設好**。

### 7.4 共用金鑰的一致性

repo 佈署的 `sshproxy/.ssh/id_rsa.crypted`，其公鑰**必須**出現在
`authorized_keys.crypted` 裡。首次驗收時這兩者是不一致的，導致所有 provider
都無法建立隧道。詳見 `POOL_RUNTIME_SPEC.md` §4 的不變式說明。

---

## 8. 改了 provision.sh 之後

`gateway/provision.sh` 的改動**只對下一台 rotate 出來的機器生效**。現行
Gateway 是用它被建立當下的那個版本 provision 的，不會自動追上。

這是不可變基礎設施的固有性質：好處是可重現（機器狀態完全由程式碼決定），
代價是「改了 provision 但還沒 rotate」這段期間，跑著的機器與程式碼描述的
機器不一致。

改完 provision 後選一條：

1. **立刻 rotate** —— 最乾淨，機器與程式碼重新對齊。但要花約 6 分鐘且會有
   數十秒的隧道中斷。
2. **手動補齊並記錄** —— 適合小改動或剛 rotate 過不久。補完要在此處記一筆，
   否則下次有人查「為什麼這台機器上有 X 但 provision.sh 沒裝 X」會很困惑。

### 已知的手動補齊紀錄

| 日期 | 機器 | 補了什麼 | 原因 |
|---|---|---|---|
| 2026-09-14 | `fws` (172.105.219.60) | `~/pool/bin/*` | provision.sh 當時還沒有安裝 pool/bin 的步驟（step 4），是 create-worker 首次執行才發現這個缺口。該機於 00:48 rotate 出來，早於修正。 |

> 判斷方式：`pool-status` 若在 Gateway 相關檢查出現 FAIL，先確認現行機器是
> 用哪個版本的 provision 建的（`NODE_GATEWAY.rotated_at` 對照 git log），
> 再決定是補齊還是 rotate。
