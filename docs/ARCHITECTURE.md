# MyLinuxPool 架構

> 定案日期：2026-09-13。本文件為實作的唯一依據，與 `REQ.md`（需求）分工：
> REQ.md 說「要什麼」，本文件說「怎麼做」。

把三台各自為政、靠 DDNS 定址的機器，收束成一座由 GitHub 當真實來源、
由 Gateway 的 loopback 埠當唯一入口的叢集。

---

## 1. 核心模型

整座叢集只有三種實體，差別在於**誰擁有身分、誰是拋棄式的**：

| 實體 | 數量 | 身分存在哪 | 職責 |
|---|---|---|---|
| **Gateway** | 1 | GitHub var `NODE_GATEWAY` | 唯一公開 IP。終結所有反向隧道，把它們攤在 `127.0.0.1` 上。可被整台換掉。 |
| **Provider** | N（長存） | GitHub var `NODE_<NAME>` | 提供算力、當 worker 的 docker host。自己主動撥出隧道到 Gateway。 |
| **Worker** | M（拋棄式） | Gateway 上 `~/pool/workers.d/` | 跑在 provider 上的 container，自己撥出隧道。Gateway 一換就全部作廢。 |

**兩層登記表，一刀切開。** 耐久的身分（機器）放 GitHub vars，rotate 不會動到；
短命的身分（worker 佔了哪個埠）放 Gateway 本機檔案，rotate 時隨舊機一起蒸發。
這正好對應「Provider 自動重掛、Worker 拋棄式」的決定，不需要額外的清理邏輯。

## 2. 拓樸

設計的關鍵在於**箭頭的方向**：NAT 底下的機器沒有公開 IP，所以連線一律由下往上
撥出，Gateway 只負責把撥進來的隧道攤在自己的 loopback 上。任何人要用這座叢集，
都是先 ssh 進 Gateway，再跳進某個埠。

```
                   GitHub Actions（控制平面）
                   workflow_dispatch ×4 · vars ＝ 真實來源
                              │  ssh · 跳板鏈
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ GATEWAY   Linode · 純 Gateway              [:22 唯一公開埠] │
   │ 127.0.0.1 — 僅本機可見，外界一律先進 :22 再跳                │
   │  ┌──────────────────────┬─────────────────────────────┐  │
   │  │ PROVIDER 固定段       ┆ WORKER 動態段                │  │
   │  │ 2220–2299            ┆ 2300–2399                   │  │
   │  │  [:2222]   [:2226]   ┆  [:2301] [:2302] …          │  │
   │  └──────────────────────┴─────────────────────────────┘  │
   └──────▲──────────────▲──────────────────▲─────────────────┘
          │              │                  │
- - - - - │ - - - - - - -│- - - - - - - - - │- - - - - - - - - - - - - -
   家用 NAT 邊界 — 以下皆無公開 IP，連線一律由下往上撥出
          │ 反向隧道      │ 反向隧道           ┆ 反向隧道
   ┌──────┴──────┐ ┌─────┴───────┐  ┌────────┴──────────┐
   │ Fh-l        │ │ Fh-proxy    │  │ Worker containers │
   │ 裸機 Ubuntu  │ │ WSL2 · 常駐  │  │ 跑在任一 provider  │
   │ WoL 喚醒     │ │ 兼 WoL 發送者│  │ 拋棄式 · 自撥隧道   │
   └─────────────┘ └─────────────┘  └───────────────────┘

   ssh -J gateway -p <埠>  ＝ 進入叢集任一節點的唯一路徑
```

## 3. 定址：一台機器一個 var

每台機器一個 GitHub repo variable，內容是一份 JSON。
**ssh 私鑰不進 var，var 只記 secret 的名字。**

### NODE_GATEWAY

```json
{
  "name": "gateway",
  "role": "gateway",
  "ip": "172.104.94.124",
  "user": "fatesaikou",
  "tunnel_user": "sshproxy",
  "key_secret": "SSH_KEY_ACTIONS",
  "linode_label": "fws",
  "ports": { "provider": [2220, 2299], "worker": [2300, 2399] },
  "generation": 7,
  "rotated_at": "2026-09-13T08:00:00Z"
}
```

> Gateway 有**兩個**使用者身分，不可混用：`user`（`fatesaikou`）供 Actions 做
> 管理操作；`tunnel_user`（`sshproxy`）是專門終結反向隧道的受限帳號，
> provider 與 worker 一律以它登入。

### NODE_FH_L（provider，含跳板鏈與電源控制）

```json
{
  "name": "fh-l",
  "role": "provider",
  "user": "fatesaikou",
  "key_secret": "SSH_KEY_ACTIONS",
  "gateway_port": 2222,
  "hops": [
    { "via": "gateway" },
    { "host": "127.0.0.1", "port": 2222,
      "user": "fatesaikou", "key_secret": "SSH_KEY_ACTIONS" }
  ],
  "capabilities": ["docker", "worker-host"],
  "power": {
    "launch":   { "method": "wol-unicast", "via": "fh-proxy",
                  "mac": "B4:2E:99:FB:63:5E", "target_ip": "192.168.0.136" },
    "shutdown": { "method": "ssh", "command": "sudo systemctl poweroff" }
  }
}
```

> **`key_secret` names an identity, not a destination** (2026-09-14
> incident). It used to be per-machine — `SSH_KEY_GATEWAY`,
> `SSH_KEY_FH_L`, `SSH_KEY_FH_PROXY` — which looked reasonable but was
> wrong: Actions is *one* identity across the whole cluster (it manages
> every node with the same account-equivalent access), so naming the
> secret after the destination just forces a new, identical-purpose
> secret per machine. The real bug this caused: `create-worker` failed on
> its very first run because `NODE_FH_L`'s second hop declared
> `SSH_KEY_FH_L`, and that secret never existed — only Rotate Gateway had
> ever been exercised for real, and it only ever jumps the first hop
> (straight to the Gateway), so the missing-secret gap on hop 2 went
> unnoticed. Fixed by giving Actions one key — `SSH_KEY_ACTIONS` — and
> pointing every node's `key_secret` (top-level and every hop) at it.
> The tunnel identity stays a **separate** key on purpose: it
> authenticates the opposite direction (a provider/worker dialing *in* to
> end its own reverse tunnel) and is deliberately more restricted than
> Actions' own management access — collapsing the two into one key would
> hand tunnel-only machines Actions-level reach.
>
> It is not, however, a separate *secret*. Until 2026-09-16 the same private
> key shipped in the repo as `ssh-tunnel-client/files/id_rsa.crypted`, which
> is how providers got it; Actions held `FILE_CRYPTO_KEY` and decrypted it
> into its agent. **KEY-DESIGN §5/§8 ended that**: every machine now mints
> its own tunnel key and publishes only the public half, so there is no
> shared private key left to keep in either place.
> `SSH_KEY_SSHPROXY` was a second copy of the same bytes that had to be
> kept in sync by hand, so it was removed on 2026-09-14.

### NODE_FH_PROXY

同上，差異：`gateway_port: 2226`，
`capabilities: ["docker","worker-host","wol-sender","wsl2"]`，
並帶 `wol_sender.shell` 指向
`/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`。

> **`{"via":"gateway"}` 是這份 schema 的重點。**
> 跳板鏈不重複寫 Gateway 的 IP，而是遞迴引用 `NODE_GATEWAY`。
> 因此 rotate 只要改**一個** var，全叢集的跳板鏈自動正確——
> 沒有任何地方需要同步更新，也就沒有漏改的可能。

### Secrets

| Secret | 處置 | 用途 |
|---|---|---|
| `FILE_CRYPTO_KEY` | 保留 | 對稱解密 `.crypted`；維持 aes-256-cbc，現有檔案不動 |
| `LINODE_TOKEN` | 保留 | Rotate 時建／刪／改名機器 |
| `SSH_KEY_ACTIONS` | 新增（取代 `SSH_KEY_GATEWAY`/`SSH_KEY_FH_L`/`SSH_KEY_FH_PROXY`） | Actions 對整座叢集的**唯一**管理身分；每個 node var 的 `key_secret`（含每一跳）都指向它，不再依目的地各配一把 |
| ~~`SSH_KEY_SSHPROXY`~~ | 2026-09-14 刪除 | 隧道身分本身仍然存在且**與 `SSH_KEY_ACTIONS` 不可合併**，但它不需要當成 secret 保存：同一把私鑰已經以 `shared-configs/ssh-tunnel-client/files/id_rsa.crypted` 隨 repo 分發，Actions 用 `FILE_CRYPTO_KEY` 自己解得開 |
| `CSIE_IO_TOKEN` | 刪除 | DDNS 廢除後無用 |
| `SSHPROXY_PASS` | 刪除 | 改純金鑰認證，Gateway 關閉 `PasswordAuthentication` |
| `GH_POOL_TOKEN` | 加密佈署 | 放 `static_secret_files`，給 provider 讀 var／clone repo |
| `GH_WORKER_TOKEN` | 加密佈署 | **只讀 var** 的低權限 token，給 worker 用 |

> **順帶的硬化。** 現在 Gateway 是 `PasswordAuthentication yes`，而 `sshproxy` 的
> `authorized_keys` 本來就已經在佈署了。改成純金鑰認證不增加工作量，
> 卻直接關掉一整類攻擊面。

## 4. pool-tunnel：可靠度的核心

整套系統唯一不能出錯的元件。**autossh 整個拿掉**，換成自己的監督程式。

### 為什麼 autossh 不夠

autossh 監看的是它自己建的一組回音埠——它只證明「ssh 連線還活著」。
但真正會壞的情況是：連線活著，**Gateway 那端的 listener 根本沒 bind 成功**
（前次連線殘留佔著埠、或 remote forward 被拒）。這種時候 autossh 回報一切正常，
而隧道其實是死的。

### 端到端探測

```bash
# 每 2 秒 —— 走既有的 ControlMaster，不重新握手，成本 ~毫秒
timeout 2 ssh -S "$CTL" gateway "nc -z 127.0.0.1 $MY_PORT"
#        └─ 逾時或非零 ⇒ 判定不健康 ⇒ 拆掉 master，立刻重建

# 每 30 秒 —— 問 GitHub 現在的 Gateway 是誰
gh variable get NODE_GATEWAY --repo FATESAIKOU/MyLinuxPool --jq .ip
#        └─ IP 變了 ⇒ 不等健康檢測失敗，直接重建
```

探測是從 **Gateway 端**打向 loopback 埠的，量到的就是使用者實際會走的那條路。
因為騎在既有的 ControlMaster 連線上，每次探測不需要新的 ssh 握手，
2 秒的門檻才站得住。

### 常駐方式

- **systemd user service** `pool-tunnel.service`，`Restart=always` / `RestartSec=5`
- 日誌走 journald（根治現在那個持續膨脹的 log 檔）
- `loginctl enable-linger` 讓它不需要登入就跑
  （Fh-l 已是 `Linger=yes`；**Fh-proxy 是 `no`，要開**）
- 同一支程式原封不動放進 worker container 當隧道監督者

> **Fh-proxy 有一個無法從 Linux 側自動化的步驟。**
> WSL2 的 systemd 只在 WSL 被啟動後才存在，而 Windows 開機並不會自動啟動 WSL。
> 需要在 Windows 側建一個工作排程器項目，於開機／登入時執行
> `wsl.exe -d <distro> -u root /bin/true`。詳見 `RUNBOOK.md`。

## 5. 四個操作

全部是 `workflow_dispatch`。共用 composite action `.github/actions/pool-ssh`：
讀 var → 把需要的私鑰載進暫時的 ssh-agent → 依 `hops` 組出 `ssh -J` 指令。
這就是「跳板指令陣列」的實體。

### Rotate Gateway（藍綠）

1. 建 `fws-preview`（Linode API）
2. cloud-init：建 `fatesaikou`／`sshproxy`、純金鑰 sshd、基礎套件
3. 佈署 bundle：`static_normal_files` ＋ 解密後的 `static_secret_files`（**無 S3**）
4. 安裝 Gateway runtime：docker、rclone、git、gh、pool-runtime（裝到 `~/.mylinuxpool/bin/`）
5. **切換點** — `gh variable set NODE_GATEWAY` 寫入新 IP、`generation+1`
6. 等待 provider 歸隊：輪詢新機 `127.0.0.1` 上每個 provider 的 `gateway_port`（上限 180 秒）
7. 成功 → 刪舊 `fws` → `fws-preview` 改名 `fws` → 回寫 var 的 `linode_label`
8. 失敗 → var 回滾舊 IP → 刪 `fws-preview` → 舊機續命
9. 孤兒清掃：任何存在超過 2 小時的 `fws-preview` 一律刪除（成本保護）

第 5 步取代舊流程的「切 csie.io DNS」，第 6 步取代「`nc -z localhost 2223`」。
Provider 每 30 秒輪詢，實際斷線時間 ≈ 一個輪詢週期 + 一次 ssh 重建，**約 40 秒內**。

### Launch Fh-l

1. Actions → Gateway → Fh-proxy（依 `NODE_FH_PROXY.hops`）
2. 在 Fh-proxy 的 WSL 內以 `pool-wol` 送 **unicast** magic packet 到 `192.168.0.136:9`
3. 成功判定 ＝ Gateway 的 `127.0.0.1:2222` 出現（上限 5 分鐘）

> **為什麼是 unicast 而不是 broadcast**（2026-09-13 實機診斷，兩個獨立的斷點）：
>
> 1. **Fh-proxy 的 Windows PowerShell 起不來** —— 連經由 `cmd.exe` 呼叫、35 秒都
>    沒有任何輸出（`cmd.exe` 本身正常，檔案存在）。舊的 `launchfhubuntuForWsl2`
>    100% 靠 PowerShell 送封包，所以它從來沒有送出過任何東西。
> 2. **WSL2 的 NAT 會丟掉 broadcast** —— 從 WSL 送 `192.168.0.255` 與
>    `255.255.255.255`，目標端都收不到；但 **unicast 到 `192.168.0.136` 收得到**
>    （tcpdump 實測，102-byte magic packet 確實抵達網卡）。
>    此機為 Windows 10 19045，無法使用 WSL2 的 mirrored networking。
>
> 已實機驗證：關機 → unicast magic packet → 成功喚醒。
> Fh-l 端 `ethtool eno1` 為 `Wake-on: g`、`device/power/wakeup` 為 `enabled`，
> 且皆能撐過重開機。
>
> **前提條件：靜態 ARP 綁定。** unicast 需要送出端能把 IP 解析成 MAC。Fh-l 長時間
> 關機後 ARP 快取會過期，屆時 unicast 無法送達。因此必須在路由器或 Windows 主機上
> 為 `192.168.0.136 ↔ b4:2e:99:fb:63:5e` 建立靜態綁定。見 `RUNBOOK.md`。

> **用隧道當成功判定，而不是 ping。** 埠出現代表：機器開機了 ✓ 進了 Ubuntu ✓
> systemd service 起來了 ✓ 網路通了 ✓。一個判準涵蓋整條鏈。
> （已確認 Fh-l 的 GRUB entry 0 是 Ubuntu。）

### Shutdown Fh-l

1. Actions → Gateway → Fh-l
2. 停掉該機上的 worker container（拋棄式，不保存）
3. `sudo systemctl poweroff`
4. 確認 Gateway 上的 `:2222` 消失

> 兩台 provider 的 `sudo` 都需要密碼，因此要加一條**範圍極窄**的 sudoers 規則，
> 只放行 `systemctl poweroff`。不開整台 NOPASSWD。

### Create Worker

1. 解析 provider var → 組出跳板鏈
2. 在 Gateway 上 `flock` 序列化，掃 2300–2399 找空位，寫 `~/pool/workers.d/<port>.json` 佔位
3. 在 provider 上 `docker build workers/<image>`
4. `docker run`（**不帶任何金鑰**），執行時注入 `GATEWAY_*`／`ASSIGNED_PORT`／`GH_WORKER_TOKEN`（**不進 image**）；
   容器啟動時自己產隧道金鑰，create-worker 只用 `docker exec` 讀回公鑰寫進 `POOL_WORKERS`，
   再 refresh Gateway——私鑰從不離開容器
5. container entrypoint：起 sshd ＋ 起 pool-tunnel
6. 從 Gateway 驗證：埠在聽 ＋ 回得出 SSH banner
7. 輸出連線指令

另備 `delete-worker`：停 container、移除佔位檔。
**埠的真實狀態永遠以 Gateway 上實際在聽的埠為準**，佔位檔只用來記「這個埠是誰」。

## 6. RegisterProvider

一台新機器要加入叢集，只需要跑一次。之後不論 Gateway 換幾次都不用再碰。

```bash
# 新 provider 上，人工一次（整套系統中唯一的人工輸入機密）
export FILE_CRYPTO_KEY=...    # 信任根
export GH_POOL_TOKEN=...      # 取得私有 repo 的鑰匙
bash ops-scripts/register-provider.sh --name fh-l --gateway-port 2222
```

腳本做七件事：

1. 安裝 `rclone`／`git`／`gh`／`docker`／`openssh-server`
2. `gh auth login --with-token`
3. clone repo 到 `~/.mylinuxpool`
4. 產生（或沿用）本機 keypair，公鑰加進 sshproxy 的 `authorized_keys`，重新加密回 repo 並 commit
5. `gh variable set NODE_<NAME>` 寫入完整連線資訊
6. 安裝 `pool-tunnel.service` ＋ `loginctl enable-linger`
7. 啟動並從 Gateway 端驗證隧道確實通了

> **為什麼 rotate 後不用重新註冊。** Provider 需要從外界知道的資訊**只有一項**：
> `NODE_GATEWAY`。它每 30 秒自己去 GitHub 拿。rotate 改的就是那一個 var，
> 所以 provider 什麼都不用做——它會自己發現、自己重連。
>
> **為什麼必須有人工輸入這一步。** 一台全新的 provider 沒有任何 inbound 路徑，
> Actions 碰不到它；而 `GH_POOL_TOKEN` 本身加密在 repo 裡，要拿到它得先能
> clone repo——循環依賴。所以必須由人給一次種子。已壓縮到只有兩個環境變數、
> 一行指令、一台機器一輩子一次。

## 7. Repo 結構

**見 `docs/LAYOUT.md`**——那才是結構契約，這裡不重複維護一份會漂移的副本。
2026-09-15 的教訓正是這個：這裡曾經自己畫了一份目錄樹，重構了兩輪之後完全
對不上實際的 `pool/`、`static_normal_files/`、`workers/base/` 等路徑早就
不存在了。簡短摘要（詳細以 `LAYOUT.md` 為準）：根目錄只有四個程式目錄——
`profiles/`（角色設定）、`shared-configs/`（分發單位）、`scripts/`（業務
邏輯）、`ops-scripts/`（人手動跑的東西）——加上 `.github/`、`docs/`。

## 8. 實作階段

順序對應 REQ 步驟 5 → 6 → 7。**每個 phase 的驗收都必須是實機跑通，
不接受「程式碼看起來對」**——舊 workflow 的執行次數是 0，我們不是在修一個
壞掉的東西，是在建一個從未驗證過的東西。

| Phase | 內容 | 驗收 |
|---|---|---|
| **E** | `pool-ssh` composite action | 跳板鏈解析、`{"via":...}` 遞迴展開；被其他四條共用，先做先測 |
| **A** | `pool/bin/pool-tunnel` 與健康檢測 | 斷線、Gateway 換 IP、埠被佔、ControlMaster 殘留 四種情境實機測過 |
| **B** | `ops-scripts/register-provider.sh` ＋ systemd | 兩台 provider 各跑一次，重開機後隧道自己活過來（REQ 步驟 5） |
| **C** | Gateway rotate | 真的 rotate 一次，且 `dlpw`／`uppw` 在新機上可用（REQ 步驟 6） |
| **D** | Worker | 兩台 provider 上各開一個 worker 並 ssh 進去（REQ 步驟 7） |

## 9. 已知風險

- **`GH_POOL_TOKEN` 會過期。** 換 token 程序寫在 `RUNBOOK.md`，
  避免半年後整座叢集突然失去定址能力卻沒人知道為什麼。
- **Fh-proxy 的 Windows 側自動啟動**無法從 Linux 自動化。在那之前，
  Fh-proxy 的「重開機自動復活」只涵蓋 WSL 內部，不涵蓋 Windows 重開機。
- **Rotate 期間** provider 最多 30 秒感知延遲 + ssh 重建時間。
- **Nanode 1 GB** 對瘦身後的純 Gateway 綽綽有餘；Gateway 不再當 worker host。
