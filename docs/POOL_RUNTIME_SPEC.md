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
  - hop 物件若含 `via`，以該名稱遞迴 resolve，並用其 hops 原地取代。
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
