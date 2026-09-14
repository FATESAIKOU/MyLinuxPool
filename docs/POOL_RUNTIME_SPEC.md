# pool runtime 實作規格

> 本文件是實作契約。Phase A/B 的產出必須完全符合此處定義的介面、
> 退出碼與檔案位置。有疑義時以本文件為準，不要自行發明介面。
> 背景與設計理由見 `ARCHITECTURE.md`。

## 0. 共通約定

- **語言**：POSIX sh 或 bash（provider 上保證有 bash 5.x）。Python 3 可用於
  需要二進位封包處理的地方（`pool-wol`）。不要引入其他執行期依賴。
- **狀態目錄**：`~/.mylinuxpool/`
  - `cache/` — GitHub var 的快取
  - `run/` — ControlMaster socket、pid、鎖
  - `bin/` — 已安裝的 pool 指令（由 register.sh 佈署）
  - `config` — 本機身分（見 §3）
- **日誌**：一律寫 stdout/stderr，交給 systemd journald。
  **禁止**自行寫檔案 log（既有系統就是這樣灌出 1.3 MB 垃圾的）。
- **每一行日誌**前綴 `[YYYY-MM-DDTHH:MM:SSZ] <level> ` ，level ∈ `INFO|WARN|ERROR`。
- **退出碼**：`0` 成功；`1` 一般錯誤；`2` 用法錯誤；其餘見各指令。

## 1. `pool/bin/pool-resolve`

讀取並展開節點定義。**所有其他元件都透過它取得連線資訊，不准自己呼叫 `gh`。**

```
pool-resolve <node-name> [--field <jq-path>] [--expand-hops] [--refresh]
```

- `<node-name>`：例如 `gateway`、`fh-l`、`fh-proxy`。
  對應的 var 名為 `NODE_` + 大寫 + `-` 換成 `_`（`fh-l` → `NODE_FH_L`）。
- 預設輸出該 var 的完整 JSON。
- `--field`：以 jq path 取單一欄位，輸出純值（例如 `--field .ip`）。
- `--expand-hops`：輸出**完全展開**的 hop 陣列 JSON。展開規則：
  - 若 `<node-name>` 本身沒有 `hops` 欄位（它就是終點，例如
    `pool-resolve gateway --expand-hops`）→ 套用下面同一條 base case，
    輸出只含一段、由它自己連線欄位合成的 hop。這是 `pool-ssh`
    （§9.3）能直接對 `gateway` 這種單跳目標一致呼叫
    `--expand-hops` 的前提，不要只在 `via` 分支裡做這件事。
  - hop 物件若含 `via`，以該名稱遞迴 resolve X。
    - 若 X 有 `hops` 欄位 → 遞迴展開，原地取代（既有邏輯）。
    - 若 X 沒有 `hops` 欄位（X 是鏈的終點，例如 Gateway）→ **base
      case**：從 X 自己的連線欄位合成一段終端 hop：
      `{ host: X.ip, port: X.port // 22, user: X.user, key_secret: X.key_secret }`。
      注意用的是 `user`（管理身分），不是 `tunnel_user`（反向隧道專用、
      不可混用）。X 連 `ip`/`user` 都沒有則視為展開失敗，退出碼 `5`。
      **不要**為了省這段合成邏輯而反過來給 Gateway 補一個 `hops` 欄位——
      那會讓 IP 同時存在兩處，rotate 要改兩個地方，違反「改一個 var
      全叢集自動正確」的設計核心。
  - 最大深度 **5**，超過回傳退出碼 `5`。
  - 需偵測環（A→B→A），回傳退出碼 `5`。
- `--refresh`：忽略快取強制重讀。

**快取**：寫入 `~/.mylinuxpool/cache/<node-name>.json`，TTL **30 秒**。
TTL 內直接讀快取，不打 GitHub API。讀取失敗且快取存在時，
**使用過期快取並輸出 WARN** —— 網路暫時不通不該讓隧道死掉。

**退出碼**：`3` var 不存在；`4` gh 未認證或 API 失敗且無快取；`5` hop 展開失敗。

## 2. `pool/bin/pool-wol`

送 Wake-on-LAN magic packet。**必須用 unicast**，理由見 `ARCHITECTURE.md`。

```
pool-wol <MAC> <target-ip> [<target-ip>...]
```

對每個目標的 UDP port `9` 與 `7` 各送 3 份。任一送出成功即退出碼 `0`。
已有可用原型（Python 3，`socket` + `SO_BROADCAST`），沿用即可。

## 3. `pool/bin/pool-tunnel`

反向隧道的監督程式。**這是整套系統唯一不能出錯的元件。**

```
pool-tunnel [--name <node-name>] [--once]
```

`--name` 未給時讀 `~/.mylinuxpool/config` 的 `NODE_NAME=`。
`--once` 只建立一次隧道後退出（供測試用）。

### 3.1 啟動

1. `pool-resolve <name>` 取得 `gateway_port` 與本機 `key_secret` 對應的私鑰路徑
   （私鑰由 register.sh 放在 `~/.ssh/id_pool`，見 §4）。
2. `pool-resolve gateway` 取得 `ip` / `tunnel_user` / `generation`。
   **注意：反向隧道一律以 `tunnel_user`（`sshproxy`）登入，不是 `user`。**
   `user`（`fatesaikou`）是給 Actions 做管理操作用的，兩者不可混用 ——
   `sshproxy` 是專門用來終結隧道的受限帳號。
3. 建立 ControlMaster：
   ```
   ssh -M -S <ctl> -o ControlPersist=no -o ExitOnForwardFailure=yes \
       -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
       -o StrictHostKeyChecking=accept-new -o AddressFamily=inet \
       -N -R 127.0.0.1:<gateway_port>:localhost:22 <tunnel_user>@<gwip>
   ```
   - `<ctl>` = `~/.mylinuxpool/run/ctl-gateway.sock`
   - **`ExitOnForwardFailure=yes` 必要**：遠端埠若被殘留連線佔住，
     必須讓 ssh 立刻失敗而不是假裝成功。這正是 autossh 會誤判的情境。
   - **`-R` 必須明寫 `127.0.0.1:` 作為 bind 位址**（2026-09-13 實機踩到）：
     只寫 `-R <port>:localhost:22` 時，若 IPv4 已被佔用，sshd 仍會成功綁上
     `[::1]:<port>`，而 **ssh 視「部分成功」為成功**，`ExitOnForwardFailure`
     因此不會觸發，隧道被誤判為建立成功。明寫 bind 位址（搭配
     `AddressFamily=inet`）可讓 IPv4 被佔時乾淨地失敗。

### 3.2 健康檢測迴圈（每 2 秒）

```
timeout 2 ssh -S <ctl> <tunnel_user>@<gwip> \
  "timeout 1 nc 127.0.0.1 <gateway_port> </dev/null | head -c 4" | grep -q '^SSH-'
```

- **逾時、非零、或回應不以 `SSH-` 開頭 ⇒ 不健康。** 門檻就是 2 秒，不要放寬。
- **必須讀 SSH banner，不可只用 `nc -z`**（2026-09-13 實機踩到）：
  `nc -z` 只證明「某個東西在聽那個埠」，不證明「那個東西是我們的隧道」。
  實測中一個冒牌 listener 佔住 IPv4 埠時，`nc -z` 回報成功，健康檢測因此
  謊報健康。舊版腳本以 SSH banner 判斷這點反而是對的，不要退化。
- 騎在既有 ControlMaster 上，不重新握手（成本為毫秒等級），
  2 秒門檻才站得住。Gateway 上已確認有 `nc` 與 `timeout`。
- 連續 **2 次**不健康才重建（單次可能是瞬時抖動），
  但兩次間隔仍是 2 秒，所以最差偵測延遲為 4 秒。

### 3.3 Gateway 換人檢測（每 30 秒）

```
pool-resolve gateway --refresh --field .ip
pool-resolve gateway --field .generation
```

`ip` 或 `generation` 與目前使用中的不同 ⇒ **立刻重建，不等健康檢測失敗**。

### 3.4 重建程序

1. `ssh -S <ctl> -O exit` 關閉舊 master（忽略失敗）
2. 刪除 socket 檔
3. 重新 §3.1
4. 退避：連續失敗時 `2, 4, 8, 16, 30, 30, ...` 秒（上限 30 秒）。
   **成功一次就重設退避。**

### 3.5 必須處理的四種情境（驗收項目）

| # | 情境 | 期望行為 |
|---|---|---|
| 1 | 網路中斷後恢復 | 4 秒內偵測到，退避重連，恢復後自行穩定 |
| 2 | Gateway 換 IP | 30 秒內偵測到並重建，不需人工介入 |
| 3 | Gateway 端埠被殘留連線佔住 | 明寫 `-R 127.0.0.1:` 使建立乾淨失敗 → 進退避重試，**不可回報健康**。健康檢測亦須讀 SSH banner，確認對面是自己的隧道而非冒牌 listener |
| 4 | ControlMaster socket 殘留 | 啟動時若 socket 存在但 `-O check` 失敗，刪除後重建 |

## 4. `provider/register.sh`

```
register.sh --name <node-name> --gateway-port <port> [--role provider]
```

需要的環境變數：`FILE_CRYPTO_KEY`、`GH_POOL_TOKEN`。缺任一則以退出碼 `2` 中止。

步驟：

1. **前置檢查**：bash、systemd（`systemctl --user`）、網路。缺 `rclone`/`git`/`gh`/
   `docker`/`openssh-server` 則以 apt 安裝（需要 sudo，見第 7 步）。
2. `gh auth login --with-token`（吃 `GH_POOL_TOKEN`）。
3. clone repo 到 `~/.mylinuxpool/repo`（已存在則 `git pull`）。
   把 `pool/bin/*` 複製到 `~/.mylinuxpool/bin/` 並 `chmod +x`。
4. **金鑰**：若 `~/.ssh/id_pool` 不存在，從 repo 的
   `static_secret_files/home/sshproxy/.ssh/id_rsa.crypted` 以 `FILE_CRYPTO_KEY`
   解密取得（所有 provider 共用這把 sshproxy 金鑰）。權限 `600`。

   > **不變式（2026-09-13 實機踩到）**：`id_rsa.pub.crypted` 的內容**必須**
   > 出現在 `authorized_keys.crypted` 之中。這兩個檔案原本是不一致的 ——
   > repo 佈署了一把私鑰，但它的公鑰不在授權清單裡，導致所有 provider 都
   > 無法建立隧道（`Permission denied (publickey,password)`）。已修正。
   > 日後若更換這把共用金鑰，**兩個檔案必須一起更新**，否則整個叢集斷線。
5. **寫 `~/.mylinuxpool/config`**：`NODE_NAME=<name>`。
6. **`gh variable set NODE_<NAME>`**：依 `ARCHITECTURE.md` §3 的 schema 組出 JSON。
   已存在則**合併**而非覆蓋（保留既有的 `power` 等欄位）。
7. **sudoers**：寫入 `/etc/sudoers.d/mylinuxpool`（`440`，先 `visudo -c` 驗證）：
   ```
   fatesaikou ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff, /usr/sbin/ethtool
   ```
   此步驟需要密碼，以互動方式向使用者索取。
8. **systemd user service**：安裝 `pool/systemd/pool-tunnel.service` 到
   `~/.config/systemd/user/`，`systemctl --user daemon-reload`、`enable --now`，
   並執行 `loginctl enable-linger $USER`（**fh-proxy 目前是 `Linger=no`，必須開**）。
9. **驗收**：從 Gateway 端確認 `127.0.0.1:<gateway-port>` 回得出 SSH banner。
   失敗則以非零退出碼結束並印出診斷。

**冪等性**：重複執行必須安全。每一步都先檢查現況再決定是否動作。

## 5. `pool/systemd/pool-tunnel.service`

```ini
[Unit]
Description=MyLinuxPool reverse tunnel to gateway
After=network-online.target

[Service]
Type=simple
ExecStart=%h/.mylinuxpool/bin/pool-tunnel
Restart=always
RestartSec=5
# 不要設 StandardOutput=file，日誌一律走 journald

[Install]
WantedBy=default.target
```

## 6. 環境事實（實測，不要重新假設）

| 項目 | 事實 |
|---|---|
| Gateway | `172.104.94.124`，Ubuntu 24.04，user `fatesaikou` / `sshproxy` |
| Gateway 已有 | `nc` `timeout` `flock` `ss` `jq` `git` `rclone` `docker` |
| Gateway 缺 | `gh` `autossh` `socat` `ncat`（健康檢測不需要） |
| fh-l | 裸機 Ubuntu 24.04，`192.168.0.136`，MAC `b4:2e:99:fb:63:5e`，埠 `2222` |
| fh-proxy | WSL2 Ubuntu 24.04，埠 `2226`，`Linger=no`（要開），兼 WoL 發送者 |
| 兩台 provider | `sudo` 都需要密碼（故有第 7 步） |
| fh-proxy 的 Windows | **PowerShell 壞的，不可使用**；`cmd.exe` 正常 |
| WSL2 網路 | NAT，**broadcast 送不出去**，unicast 可以 |

## 7. 禁止事項

- 禁止使用 `autossh`（理由見 `ARCHITECTURE.md` §4）。
- 禁止寫死 Gateway 的 IP 或任何主機名稱 —— 一律經 `pool-resolve`。
- 禁止自行寫 log 檔。
- 禁止在 `pool-tunnel` 裡直接呼叫 `gh`；一律經 `pool-resolve`。
- 禁止把任何機密寫進 repo 或寫進日誌。
- 禁止把機密當作命令列參數傳遞，**唯一例外**：既有的
  `scripts/decryptStdin.sh <key>` 介面（金鑰為 argv[1]，會短暫出現在
  `ps` 輸出中）。這是 repo 沿用已久的慣例，且使用者已明確決定
  「加密機制維持現狀不改」，故視為**已知並接受的風險**，不要為此改寫
  既有腳本介面。新寫的程式一律不得比照辦理。

## 8. 實機驗收紀錄（2026-09-13/14，fh-l）

`pool-resolve`、`pool-tunnel`、`register.sh` 三者已在 fh-l 上完成驗收。

### 8.1 pool-resolve（Mac，gh 2.95.0）

| 項目 | 結果 |
|---|---|
| 取完整 JSON / `--field` | ✅ |
| var 不存在 → 退出碼 3 | ✅ |
| 快取建立與命中 | ✅ 0.03s（vs API 約 1s） |
| 環狀 `via` → 退出碼 5 | ✅ 並印出環的路徑 |

### 8.2 register.sh（fh-l）

首次執行九步驟全過（step 9 因當時 §4 的金鑰不一致而失敗，修正後通過）。
**第二次執行驗證冪等性**：step 2/4/7/8 全部正確偵測既有狀態並跳過，
step 6 正確 deep-merge，step 9 verified。

### 8.3 pool-tunnel —— §3.5 四種情境

| # | 情境 | 結果 | 反應時間 |
|---|---|---|---|
| 1 | 網路中斷後恢復 | ✅ | Gateway 中斷約 45 分鐘後自行恢復，零人工介入 |
| 2 | Gateway generation 改變 | ✅ | **6 秒**（規格要求 30 秒內） |
| 3 | 遠端埠被佔住 | ✅ | 正確判定建立失敗並退避，未謊報健康 |
| 4 | ControlMaster socket 殘留 | ✅ | **2 秒**（偵測 1 秒 + 重建 1 秒） |

情境 3 在第一次驗收時**不通過**，暴露了兩個缺陷（IPv4/IPv6 部分綁定、
健康檢測只用 `nc -z`），修正後才通過。詳見 §3.1 / §3.2 的說明。

### 8.4 尚未驗收

- **fh-proxy 尚未註冊** —— 它在 Gateway 失聯期間重開機，隧道未恢復，
  且無 inbound 路徑，需要本機操作。見 `RUNBOOK.md` §7.2。
- Phase C（Gateway rotate）與 Phase D（Worker）尚未開始。

## 9. Phase C：Gateway rotate 實作規格

背景與流程見 `ARCHITECTURE.md` §5。本節定義實作契約。

### 9.1 `gateway/cloud-config.yaml`（瘦身版）

cloud-init 只負責「開機後能被 ssh 進來」這件事，其餘交給 `provision.sh`：

- 建立兩個使用者：
  - `fatesaikou` — `groups: sudo`、`sudo: ALL=(ALL) NOPASSWD:ALL`、shell bash
  - `sshproxy` — shell bash，**不給 sudo**（它只是隧道終結點）
  - 兩者的 `ssh_authorized_keys` 由 cloud-init 直接帶入（從 secret 注入），
    **不要**再用 `plain_text_passwd` —— 純金鑰認證，密碼路徑整條廢除
- `package_update: true` / `package_upgrade: false`
  （**不要** upgrade：285 天沒重建的舊機正是因為累積更新債才出事，
  但在 cloud-init 階段 upgrade 會拖長 rotate 且可能中途失敗。
  新機用的是最新 image，本來就不需要）
- 安裝：`curl` `ca-certificates` `git` `jq` `netcat-openbsd` `util-linux`
  （`flock`）`iproute2`（`ss`）`fail2ban`
- **不裝**：nodejs、python3-pip、ipython、grc、vim、tmux、gcc、make
  （Gateway 是純 Gateway，不是工作站）

### 9.2 `gateway/provision.sh`

在新機開機後、由 Actions 以 root 執行。必須冪等。

1. **sshd 硬化**：寫 `/etc/ssh/sshd_config.d/10-mylinuxpool.conf`：
   ```
   PasswordAuthentication no
   PermitRootLogin no
   KbdInteractiveAuthentication no
   ```
   `sshd -t` 驗證通過才 reload。**現行機是 `PasswordAuthentication yes`，
   這是要一併修掉的既有弱點。**
2. **fail2ban ignoreip**：從 `POOL_TRUSTED_IPS` var 渲染
   `/etc/fail2ban/jail.d/mylinuxpool-ignore.conf`：
   ```
   [DEFAULT]
   ignoreip = <POOL_TRUSTED_IPS 的內容>
   ```
   > **這一步不可省略。** 2026-09-13 的事故就是 fail2ban 封了家用 IP，
   > 導致整個叢集失聯 45 分鐘。設定只存在於當時那台機器上，
   > rotate 後會消失並重演。見 `RUNBOOK.md` §7.1。
3. **佈署檔案權限**：scp 過來的檔案要修正擁有者與權限 ——
   `/home/<user>` 遞迴 chown 給對應使用者；
   **所有私鑰（`id_rsa`、`id_pool`）必須是 `600`**，
   `authorized_keys` 與 `*.pub` 為 `644`。
   > 現行機的 `/home/sshproxy/.ssh/id_rsa` 原本是 644（全系統可讀的私鑰），
   > 是實機發現的既有弱點，新機不可重蹈。
4. **安裝 pool-runtime**：呼叫 `shared_config/pool-runtime/install.sh`，
   把 `pool-resolve`/`pool-tunnel`/`pool-wol`/`pool-status`/
   `pool-port-alloc` 與 `pool-tunnel.service` 裝到 **`/home/fatesaikou/.mylinuxpool/bin/`**
   （見 `docs/LAYOUT.md`；這個 unit 自己管檔案的擁有者與權限，不再
   依賴上一步的 `chown -R`）。
   > **2026-09-14 補上的缺口**：`ARCHITECTURE.md` §5 step 4「安裝 Gateway
   > runtime」原本就包含這一份 runtime，但實作只裝了
   > `docker`/`rclone`/`gh`。少了它，`pool-port-alloc` 在 Gateway 上無處
   > 可跑，`create-worker`/`delete-worker` 第一次連線就失敗
   > （`pool-resolve not found`）。
   > **2026-09-15 修正**：本節原本寫的目的地是 `~/pool/bin/`，與
   > provider/worker 用的 `~/.mylinuxpool/bin/`（本文 §0 與
   > `pool-tunnel.service` 的 `ExecStart=%h/.mylinuxpool/bin/...` 早就這樣
   > 定）不一致——這是本規格自己寫錯，不是兩種故意不同的慣例。
   > `create-worker.yml`/`delete-worker.yml` 曾經照著錯的那份呼叫
   > `~/pool/bin/pool-port-alloc`，現已統一改回 `~/.mylinuxpool/bin/`。
5. **安裝 runtime**：`docker.io`、`rclone`、`gh`
   （`gh` 用 apt 即可，Gateway 不跑 `pool-resolve` 所以版本不拘）。
6. **建立 `~/pool/workers.d/`**（worker 埠登記表的位置，見 `ARCHITECTURE.md` §5）。
7. **驗收**：`sshd -t` 通過、`fail2ban-client status` 正常、
   `nc`/`flock`/`ss`/`jq` 皆存在，且 `~/.mylinuxpool/bin/pool-port-alloc` 存在並可執行。

### 9.3 `.github/actions/pool-ssh`（composite action）

四條 workflow 共用。職責：

```yaml
inputs:
  node:     # 節點名稱，例如 fh-l
  command:  # 要執行的指令
  timeout:  # 選填
```

1. `pool-resolve <node> --expand-hops` 取得完整跳板鏈
2. 依每一跳的 `key_secret` 從 secrets 取出私鑰，載入暫時的 ssh-agent
   （**私鑰只進 agent，不落地成檔案**；若必須落地則 `600` 且結束時刪除）
3. 組出 `ssh -J hop1,hop2,... <最後一跳>` 並執行 `command`
4. 輸出 stdout/stderr 與退出碼

> Actions runner 本身沒有 `pool-resolve` 的執行環境假設 —— 它需要 `gh` 與
> `jq`，runner 皆內建。`GH_TOKEN` 由 workflow 以 `secrets.GITHUB_TOKEN` 或
> `GH_POOL_TOKEN` 提供。

### 9.4 `.github/workflows/rotate-gateway.yml`

`workflow_dispatch`，流程見 `ARCHITECTURE.md` §5 的九個步驟。額外要求：

- **`dry_run` 輸入**（預設 `false`）：為 `true` 時建立 preview 機、佈署、
  provision、驗收，但**不切換 `NODE_GATEWAY` var、不刪舊機**，
  最後把 preview 機刪掉。用於安全地驗證整條流程。
- 切換點（step 5）之後的每一步失敗都必須觸發回滾：var 寫回舊 IP 與
  舊 generation，並刪除 preview 機。
- 等待 provider 歸隊（step 6）時，逐一輪詢每個 `role=provider` 的節點的
  `gateway_port`，全部出現才算成功；上限 180 秒。
- 孤兒清掃：刪除任何存在超過 2 小時、label 以 `-preview` 結尾的機器。

## 10. Phase D：Worker 實作規格

背景見 `ARCHITECTURE.md` §1（拋棄式身分）與 §5（Create Worker 七步驟）。

### 10.1 埠配發：`pool/bin/pool-port-alloc`

**在 Gateway 上執行**（由 workflow 經 `pool-ssh` 呼叫已安裝在
`~/.mylinuxpool/bin/pool-port-alloc` 的那份，見 §9.2 step 4——不要用送原始碼字串
給 `bash -c` 的方式執行；那樣 `BASH_SOURCE` 不是真實檔案路徑，
`pool-port-alloc` 內用來找 `pool-resolve` 的 `SCRIPT_DIR` 會解析錯誤）。

```
pool-port-alloc --claim <provider> <image>   # 配發並佔位，印出埠號
pool-port-alloc --release <port>             # 釋放
pool-port-alloc --list                       # 列出目前登記
```

- 範圍取自 `NODE_GATEWAY.ports.worker`（目前 2300–2399），**但** Gateway
  依 §10.2b 的設計刻意不持有任何 GitHub 憑證，`pool-resolve` 在那裡本來
  就跑不起來。因此 `--claim` 讀取範圍時**優先看環境變數
  `POOL_WORKER_PORT_RANGE`**（格式 `"<lo> <hi>"`），有設就直接用、
  完全不呼叫 `pool-resolve`；只有兩者都沒有時才 fallback 呼叫
  `pool-resolve gateway --field .ports.worker`（供未來 Gateway 若真的
  裝了憑證時的獨立手動使用）。workflow 呼叫時一律先在 Actions runner
  （有 `GH_TOKEN` 的那一端）resolve 好範圍，再以此環境變數傳入。
- **必須以 `flock` 序列化**，避免兩個 CreateWorker 同時搶到同一個埠
- 判定「空」的依據是**兩者皆須成立**：`ss -tln` 顯示該埠沒有 listener，
  且 `~/pool/workers.d/<port>.json` 不存在
- 佔位檔內容：`{provider, image, port, created_at, container}`
- 範圍用盡時退出碼 `6` 並明確說明

> 埠的**真實狀態以 `ss` 為準**，佔位檔只用來記「這個埠是誰的」。
> 兩者不一致時（例如 rotate 後佔位檔隨舊機蒸發），以 `ss` 為準。

### 10.2 `workers/base/Dockerfile`

標準 Linux 工作環境。要求：

- 基底 `ubuntu:24.04`
- 安裝：`openssh-server` `ca-certificates` `curl` `git` `jq`
  `netcat-openbsd` `rclone` `gh`（依決策，每台 worker 必裝 rclone/git/gh）
- 建立非 root 使用者 `worker`，可 sudo
- sshd 設定為**純金鑰認證**
- **image 內不得含任何機密**（規格 §7）。金鑰與 token 一律 `docker run`
  時以 env 或 mount 注入
- entrypoint：起 sshd → 起 `pool-tunnel`（與 provider 共用同一支程式）

### 10.2b Worker profile：宣告需要哪些機密

每個 `workers/<image>/` 底下放一份 `profile.json`，宣告這個 worker 需要什麼。
**只寫 secret 的名稱，不寫值** —— 與 node var 用 `key_secret` 指向 secret
名稱是同一個模式。

```json
{
  "name": "base",
  "description": "標準 Linux 工作環境",
  "secrets": {},
  "env": {}
}
```

```json
{
  "name": "ai-dev",
  "description": "容器內跑 AI agent 做開發",
  "secrets": {
    "GH_TOKEN": "GH_DEV_TOKEN",
    "ANTHROPIC_API_KEY": "ANTHROPIC_API_KEY"
  },
  "env": { "GIT_AUTHOR_NAME": "mylinuxpool-worker" }
}
```

- `secrets` 是「容器內的環境變數名稱 → GitHub secret 名稱」的對應。
  `create-worker` 依此逐一取出並以 `-e` 注入。
- **profile 進版控，值永遠不進。** 換 token 只需改 profile 裡的名字，
  不必動任何程式碼。
- 若 profile 宣告的 secret 在 repo 中不存在，`create-worker` 必須以明確
  錯誤中止（列出缺哪一個），不可靜默注入空值。
- `base` 的 `secrets` 是空的 —— 它完全不帶任何 GitHub 憑證。

> **為什麼隧道不走這條路。** 隧道所需的 Gateway 位址與埠由
> `create-worker` 在 `docker run` 當下直接注入（見 §10.3），與 profile 無關。
> 因此一個沒宣告任何 secret 的 worker 仍能連回 Gateway，容器內卻沒有任何
> GitHub 憑證可被竊取。容器內的工作需要什麼權限，由 profile 明確宣告，
> 而不是繼承一把萬用 token。

### 10.3 Worker 的隧道身分

Worker 沿用 `pool-tunnel`，但它的「節點定義」不在 GitHub var 裡
（worker 是拋棄式的，不該污染耐久登記表）。因此：

- `pool-tunnel` 需支援從**環境變數**取得自身設定，作為 `pool-resolve <name>`
  的替代路徑：`POOL_GATEWAY_PORT`、`POOL_NODE_NAME`
- **Gateway 的位址也一併由環境變數注入**：`POOL_GATEWAY_HOST`、
  `POOL_GATEWAY_USER`。三者皆設定時，`pool-tunnel` 完全不呼叫
  `pool-resolve`，因此 worker **不需要任何 GitHub 憑證即可建立隧道**。
- 若 `POOL_GATEWAY_PORT` 已設定，就不去讀 `NODE_<NAME>` var
- 代價：worker 無法偵測 Gateway 換人，rotate 後連不回來。這正是預期行為
  —— worker 是拋棄式的（`ARCHITECTURE.md` §1），rotate 後重跑
  `create-worker` 即可。

### 10.4 workflows

- `create-worker.yml`：輸入 `provider`、`image`（`workers/` 下的目錄名）、
  `name`（選填）。流程見 `ARCHITECTURE.md` §5。成功時輸出連線指令。
- `delete-worker.yml`：輸入 `port` 或 `name`。停止並移除 container、
  釋放佔位檔。

### 10.5 驗收條件

1. 在 fh-l 與 fh-proxy 上各開一個 worker，皆能經 Gateway 的動態埠 ssh 進入
2. 同時開兩個 worker，埠不衝突（驗證 `flock`）
3. `delete-worker` 後埠確實釋放，可被下一個 worker 取得
4. worker image 內不含任何機密（`docker history` 與 `docker run ... env` 檢查）
