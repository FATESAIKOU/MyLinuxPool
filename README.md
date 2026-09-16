# MyLinuxPool

把散落的三台 Linux 機器收束成一座叢集：一個公開入口、所有節點由它跳板進入、
機器可以整台換掉而不需要重新設定任何東西。

- [系統架構](#系統架構)
- [使用方式](#使用方式)
- [維護方式](#維護方式)

---

# 系統架構

## 全景

```
                GitHub Actions（控制平面）
                repo vars = 定址的唯一真實來源
                          │ ssh
                          ▼
        ┌─────────────────────────────────────┐
        │ GATEWAY (Linode)      [:22 唯一公開埠] │
        │ 127.0.0.1                            │
        │   :2222  :2226  │  :2300 :2301 …     │
        │   provider 固定段 │  worker 動態段     │
        └────▲───────▲──────────────▲──────────┘
             │       │              │
- - - - - - -│- - - -│- - - - - - - │- - - - - - -
   家用 NAT 邊界 — 以下無公開 IP，一律由下往上撥出
             │       │              │
        ┌────┴───┐ ┌─┴────────┐ ┌───┴──────────┐
        │ Fh-l   │ │ Fh-proxy │ │ Worker 容器   │
        │ 裸機   │ │ WSL2     │ │ 拋棄式        │
        │ WoL 喚醒│ │ 常駐     │ │              │
        └────────┘ └──────────┘ └──────────────┘
```

| 角色 | 機器 | 說明 |
|---|---|---|
| Gateway | Linode `fws` | 唯一有公開 IP 的機器。它自己不跑運算，只當跳板與反向隧道的落點。可整台丟棄重建 |
| Provider | `fh-l`（裸機，平常關機）<br>`fh-proxy`（WSL2，常駐） | 真正跑東西的機器。在 NAT 後面，由自己撥出反向隧道到 Gateway |
| Worker | Docker 容器 | 跑在某個 provider 上的拋棄式環境，一樣有自己的 Gateway 埠 |

**進入任何節點的唯一路徑**：`ssh -J <gateway> -p <port> <user>@127.0.0.1`

隧道終結在 Gateway 的 **loopback**，不是 `0.0.0.0`。所以就算 Gateway 被打，
外面也看不到那些埠——必須先登入 Gateway 才碰得到。

## 定址：GitHub repo vars 是唯一真實來源

每台機器一個 var，內容是 JSON：

| var | 內容 |
|---|---|
| `NODE_GATEWAY` | Gateway 的公開 IP、使用者、金鑰名稱 |
| `NODE_FH_L` / `NODE_FH_PROXY` | 各 provider 的 `gateway_port`、`hops`、`capabilities`、`power` |
| `POOL_TRUSTED_IPS` | fail2ban 的白名單 |
| `NODE_WORKER_*` | 由 create-worker 動態產生 |

`hops` 陣列描述「怎麼走到這台機器」，第一跳寫 `{"via":"gateway"}` 而不是
重複抄一次 Gateway 的 IP。解析時遞迴展開。**所以換 Gateway 只要改一個 var，
沒有第二個地方需要同步。**

金鑰只寫**名稱**（`key_secret`），值放在 GitHub secrets。vars 是公開可讀的。

## 兩把 SSH 身分，不要搞混

| 身分 | 誰用 | 走哪 |
|---|---|---|
| `SSH_KEY_ACTIONS` | GitHub Actions、管理員 | 由上往下進入所有機器 |
| 隧道身分（各機自己的 `~/.ssh/id_tunnel`） | provider / worker | 由下往上掛反向隧道 |

**不變式**：每台機器用自己的 `id_tunnel`（KEY-DESIGN §3.2/§8，共用私鑰已刪除）；
公鑰存在該機的 `NODE_<NAME>.tunnel_public_key` 或 `POOL_WORKERS[].tunnel_public_key`，
Gateway 的 sshproxy 清單由 refresh/rotate 從這些 var 組裝。不再有任何靜態
`authorized_keys.crypted`。

## 隧道：`pool-tunnel`，不是 autossh

autossh 只證明「TCP 連線活著」，不證明「Gateway 那端的 listener 還在」。
實測過假的 listener 可以騙過 `nc -z`。

`pool-tunnel` 改成從 Gateway 端探測 loopback 埠並**讀 SSH banner**——
確認回來的是真的 sshd。每 2 秒一次，掛掉就重建。搭配
`ExitOnForwardFailure=yes` 與明確的 `-R 127.0.0.1:<port>:` 綁定
（不加會 IPv4/IPv6 只綁一半，反而讓失敗偵測失效）。

跑在 systemd **user** service + `loginctl enable-linger`，所以不需要 root。

## 分發單位：`shared-configs/<unit>/`

每個要裝到機器上的東西都是一個 unit：

```
shared-configs/rclone/
  unit.json        # 宣告 needs_key、目標路徑
  install.sh       # --key / --home / --user / --check
  files/*.crypted  # 對稱加密的機密（FILE_CRYPTO_KEY）
  tests/
```

`install.sh --check` 會回報「宣告的」與「實際在機器上的」之間的落差，
不做任何修改。比對的是**內容**（逐檔 `cmp`），不是「檔案在不在」——
`pool-sync` 的自癒完全建立在這一點上，所以它有自己的測試
（`shared-configs/pool-runtime/tests/test-install-check.sh`）。

## 角色設定：`profiles/<role>/<name>/profile.json`

```json
{
  "name": "default", "role": "provider",
  "shared_config": ["pool-runtime", "gh"],
  "systemd_user_services": ["pool-tunnel.service", "pool-sync.timer"],
  "linger": true,
  "sudoers_rules": ["ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff, /usr/sbin/ethtool"]
}
```

**每一個預載的資料夾、設定檔，都在 profile 裡明確列出來。**
沒列的東西不會被裝上去。

Worker 的 profile 多一個 `secrets` 欄位，映射「容器環境變數名 → GitHub secret 名」
——只有名稱，永遠不寫值。image 裡不含任何憑證，機密只在 `docker run` 時注入。

**Worker 怎麼知道 Gateway 在哪？** 不是問 GitHub（容器裡沒有憑證），而是讀
它所在 provider 發布的檔案。provider 的 `pool-tunnel` 本來就每 30 秒在追
`NODE_GATEWAY`，所以它就是同機容器的權威來源：它把結果寫成
`~/.mylinuxpool/gateway/gateway.json`，`create-worker` 把那個**目錄**唯讀掛進容器。
掛目錄而不是掛檔案，是因為發布用的是「寫暫存檔再改名」，掛檔案會鎖在舊 inode 上。

## provider 上不留 repo：`pool-sync`

provider 只放**衍生物**。宣告在 GitHub 有一份，機器上不留第二份——
`register-provider.sh` 把 repo clone 到暫存目錄，裝完就刪。

問題是衍生物會過期。rotate 只重建 Gateway；`pool-tunnel` 的 30 秒迴圈只重寫
三個跟 Gateway 位址有關的檔案。`~/.mylinuxpool/bin/` 那五支腳本一旦裝上去，
在此之前**沒有任何機制會更新它們**——實測時兩台 provider 都停在三個 commit
之前，而且不會有人發現。

`pool-sync.timer` 每 30 分鐘補上這一段：

1. `git clone --depth 1` 一份到暫存目錄（GitHub 取不到就 `exit 0` —— 
   GitHub 掛掉不可以變成 provider 故障）
2. 對 profile 宣告的每個 unit 跑 `install.sh --check`
3. 有落差才真的裝；**只有真的裝了才重啟 `pool-tunnel`**
   （重啟會斷掉該機所有 worker 的隧道，無變更就重啟等於白付代價）
4. 順手移除舊版留下的 `~/.mylinuxpool/repo`
5. 清掉暫存目錄

它**不記版本戳記**。判斷漂移靠的是 unit 自己的內容比對，不是 commit SHA，
所以連被手動改過的 `bin/` 也會被修回來——而且 provider 上一個新檔案都不會多。

需要 `FILE_CRYPTO_KEY` 的 unit（`rclone`、`standalonescripts`）與需要 root 的
（`gh`）一律跳過。**provider 的 profile 現在只宣告 `pool-runtime` 與 `gh`**，
所以實際上 `pool-sync` 收斂的就是 `pool-runtime`——而那正是唯一會漂移的部分。
provider 邊緣刻意不放解密金鑰；KEY-DESIGN §8 之後也不再有任何 provider unit
需要它。

盤查下來，provider 上**推導不出來的資訊只剩 59 bytes**——
`config` 裡的 `NODE_NAME` 和 `gh_token`。

## 目錄

| 路徑 | 內容 |
|---|---|
| `profiles/` | 角色宣告：`gateway/`、`provider/`、`worker/`（含 Dockerfile） |
| `shared-configs/` | 可分發安裝單位，見 `docs/LAYOUT.md` |
| `scripts/` | 業務邏輯，**不依賴 GitHub Actions**（沒有 `${{ }}`、`$GITHUB_OUTPUT`），含 `lib/{log,crypto,ssh,profile}.sh` |
| `ops-scripts/` | 人手動跑的：`mlp`、`register-provider.sh`、`verify-profile`、`preflight` |
| `.github/` | workflow 與 `pool-ssh` composite action。所有 GitHub 專屬的東西只出現在這裡 |
| `docs/` | 見文件表 |

---

# 使用方式

## 在 Mac 上：`mlp`

```bash
ops-scripts/mlp                # 互動式選單（fzf）
ops-scripts/mlp ls             # 列出所有節點與即時狀態
ops-scripts/mlp ssh [name]     # 登入節點或 worker，省略 name 就跳選單
ops-scripts/mlp wake           # 喚醒 fh-l（經 fh-proxy 送 unicast WoL）
ops-scripts/mlp down           # 關閉 fh-l（會先確認）
ops-scripts/mlp status         # 完整健康檢查
ops-scripts/mlp rotate         # Gateway dry run（不碰現役機器）
ops-scripts/mlp rotate --real  # 真的換掉 Gateway，要打現役 IP 確認
ops-scripts/mlp worker new     # 選 provider、選 image，開一個 worker
ops-scripts/mlp worker rm      # 從清單挑一個刪掉、釋放埠
ops-scripts/mlp ssh-config     # 匯出 ssh_config，讓 ssh/scp/rsync 直接可用
ops-scripts/mlp trust-gateway  # 通常不用跑了（每條指令都會自動釘選）
```

### 用原生 ssh 而不透過 mlp

```bash
ops-scripts/mlp ssh-config --write     # 寫到 ~/.mylinuxpool/ssh_config
# 依提示把 Include 加到 ~/.ssh/config 的第一行
ssh fh-l
ssh worker-2300                        # 或完整容器名
rsync -av ./x fh-proxy:~/
ssh -R 127.0.0.1:9000:localhost:9000 fh-l    # 反向隧道
```

Gateway 那一段用 `NODE_GATEWAY` 帶的 host key 釘選；`127.0.0.1:<port>` 那些
段落刻意不驗證——每個節點都在同一個 loopback 位址上應答，worker 重建就換一把
金鑰，釘了只會每次跳警告。驗證由 Gateway 那一段負責。

**rotate 之後要重新產生**（位址與 host key 都變了）。

`rotate` / `worker` 這三個不是在本機執行，而是**觸發對應的 workflow 並把
step 逐一串流回終端機**。分界線是：需要憑證或需要編排的走 workflow
（機密全留在 GitHub，你的 Mac 一把都不用放）；互動、講求延遲的
（`ssh` / `wake` / `down`）留在本機。

需要 `fzf` `jq` `gh`：`brew install fzf jq gh`。

**在外網（咖啡廳）可以用。** `mlp` 全程走公開路徑，不碰任何 LAN 位址——
`wake` 是把 `target_ip` 傳給 fh-proxy 由它在家裡送封包。實測從 mlp 進去的連線
`SSH_CONNECTION` 是 `127.0.0.1 → 127.0.0.1`（走隧道），不是 LAN IP。

唯一要注意的是 **fail2ban**：在陌生網路重複打錯會被 Gateway 封 IP。
退路是 Linode LISH 主控台（見「維護方式 §出事時」）。

## 四個核心操作（GitHub Actions）

| Workflow | 做什麼 | 重要參數 |
|---|---|---|
| `rotate-gateway` | 藍綠替換整台 Gateway | **`dry_run` 預設 `true`** |
| `repair-gateway` | 對**現役**機器重跑 provision，不換 IP、不碰 `NODE_GATEWAY` | `confirm` 要打現役 IP |
| `create-worker` | 在指定 provider 上開容器並接進 Gateway | `provider`、`image`、`name` |
| `delete-worker` | 停容器、釋放埠 | `port` 或 `name` 擇一 |

Launch / Shutdown fh-l 不走 Actions，走 `mlp wake` / `mlp down`。

### Rotate Gateway

1. 先跑 `dry_run: true`。它會真的開一台預覽機、佈署、驗證，然後刪掉。
   **全程不碰 `NODE_GATEWAY`，也不碰現役機器。**
2. dry run 綠燈之後才跑 `dry_run: false`。
3. 切換後在 Mac 上跑一次 `ops-scripts/mlp trust-gateway`（新機器的 host key）。
4. provider 每 30 秒輪詢 `NODE_GATEWAY`，自己跟過去。實測**重連耗時 1 秒**，
   不需要登入任何一台 provider。
5. **現役的 worker 會自己跟過去，不需要重建。** 實測 gen 5 → 6：provider
   2 秒、worker 1 秒，容器 ID 不變（`RUNBOOK.md` §8）。它們讀 provider 發布的
   `~/.mylinuxpool/gateway/gateway.json`（唯讀 bind mount），30 秒內偵測到
   位址變更並重建隧道；rotate 同時把埠帳本搬到新機器，所以 `mlp ls` 與
   `delete-worker` 也還找得到它們。

### Create Worker

指定 provider 與 image（`profiles/worker/<image>/`），workflow 會 build、
run、配一個動態埠、寫 `NODE_WORKER_*` var。完成後 `mlp ssh` 就看得到。

## 出事時第一件事

```bash
ops-scripts/mlp status
```

它會指出壞在哪一層。**TCP 被立即拒絕**時它會提示去查 fail2ban——那正是
2026-09-13 讓整座叢集失聯 45 分鐘的原因（`docs/RUNBOOK.md` §7）。

---

# 維護方式

## 我需要保管什麼

看 `SECRETS.md`（gitignore，不進版控）。裡面每一項都標了理由與用法。

**只有一項失去就救不回來**：

- `FILE_CRYPTO_KEY` — 解開 `.crypted` 檔的對稱金鑰（現在只剩
  `rclone`/`dotfiles`/`standalonescripts` 在用——KEY-DESIGN §8 之後不再是
  「掌握全叢集 ssh 存取」的金鑰）。GitHub secret 是唯寫的，讀不回來。
  失去它系統還活著，但你無法再註冊新機器或檢視那些機密。

`GH_POOL_TOKEN`、`LINODE_TOKEN` 都能重新產生，所以 `SECRETS.md` 只記重發
程序、不記值——現值仍活在 GitHub secret 與機器上的本機副本裡。多記一份值
只是在那個檔案外洩時擴大損害面。機器的 sudo 密碼是你自己的密碼，屬於你的
密碼管理器，不在這裡留第二份。

GitHub secret 只有四個：`FILE_CRYPTO_KEY`、`SSH_KEY_ACTIONS`、
`GH_POOL_TOKEN`、`LINODE_TOKEN`。隧道身分不在其中——每台機器用自己的
`~/.ssh/id_tunnel`（KEY-DESIGN §3.2，共用私鑰已刪除），沒有需要分發的
共用私鑰。

本機 repo 根目錄現在只剩 `crypto_key` 一個明文機密（`pw`、`fhproxy_pw`、
`gw_pw`、`gh_token` 都已抹除）。

> ⚠️ Gateway 的 root 密碼由 rotate 隨機產生後就丟棄，沒有留在任何地方，
> 所以**每一台 rotate 出來的機器都沒有 LISH 主控台救援退路**，只剩
> `repair-gateway`（憑 `SSH_KEY_ACTIONS` 進去）這一條。要把退路補回來，
> 就設 `GATEWAY_ROOT_PASSWORD` secret——rotate 會優先取它
> （`scripts/rotate-gateway.sh:48`）。這個 secret 目前**還沒設**。

## 加一台 provider

```bash
# 在那台機器上
git clone <repo> && cd MyLinuxPool
ops-scripts/register-provider.sh --name <node-name> --gateway-port <port>
# 沒有 sudo 密碼時（例如 WSL2）：
ops-scripts/register-provider.sh --name <node-name> --gateway-port <port> --no-sudo
```

它會裝 profile 宣告的所有 unit、設好 systemd user service 與 linger、
把 `NODE_<NAME>` var 寫上 GitHub。`--no-sudo` 全程不碰 root，代價是沒有
sudoers 規則（所以無法遠端 poweroff）。

## 加一種 worker image

1. 開 `profiles/worker/<image>/`，放 `Dockerfile`、`entrypoint.sh`、`profile.json`。
2. `profile.json` 的 `shared_config` 列出要裝的 unit，`secrets` 列出需要哪些
   GitHub secret（**只寫名稱**）。
3. 跑 `ops-scripts/preflight` 確認 `COPY` 來源都存在、宣告的 unit 都在。
4. `create-worker` 時把 `image` 填成資料夾名。

## 佈署改動到現役 Gateway

`scripts/provision-gateway.sh` 或 `shared-configs/` 的改動**只對下一台
rotate 出來的機器生效**。要套到現役機器：

```bash
gh workflow run repair-gateway.yml -f confirm=<現役 Gateway IP>
```

它也是**你進不去 Gateway 時的回家路**——Actions 手上有 `SSH_KEY_ACTIONS`，
就算你的身分被漂移掉了它還進得去。2026-09-14 就是這樣救回來的
（`RUNBOOK.md` §7.6）。

## 改了東西要跑的檢查

```bash
ops-scripts/preflight              # 靜態檢查：Dockerfile COPY 來源、
                                   # profile 宣告的 unit 是否存在、
                                   # needs_key 與 files/*.crypted 是否一致、
                                   # 有沒有殘留舊路徑
echo -n "$FILE_CRYPTO_KEY" | \
  ops-scripts/verify-profile <node> <role>/<profile>
                                   # 連上真機，跑每個 unit 的
                                   # install.sh --check，回報落差
                                   # （金鑰走 stdin，不進命令列）
```

`preflight` 檢查的正是語法檢查抓不到、但會在實機炸掉的那類問題——
它是被一次 `COPY shared_config/...` 沒跟著改名的事故逼出來的。

## 換 `FILE_CRYPTO_KEY`

1. 用舊金鑰把 `.crypted` 全部解開（現在只剩 `rclone`/`dotfiles`/
   `standalonescripts` 三支 unit 在用）。
2. 產新金鑰，全部重新加密。
3. `gh secret set FILE_CRYPTO_KEY`，更新 `SECRETS.md`。
4. 需要 `FILE_CRYPTO_KEY` 的機器（Gateway）重跑一次 provision/repair。

沒有「同步更新隧道公鑰」這一步了——隧道身分是各機自己的 `id_tunnel`
（KEY-DESIGN §8），與 `FILE_CRYPTO_KEY` 無關。

## 換 `GH_POOL_TOKEN`

GitHub 產新 PAT（classic，scope 只需要 `repo`）→ `gh secret set GH_POOL_TOKEN`
→ 兩台 provider 各重跑一次 `register-provider.sh`。

## 傳送機密的鐵則

**永遠不要讓機密和 script 走同一條 stdin。**

```bash
# ✗ 錯：金鑰會出現在遠端的 process listing / log
cat crypto_key | ssh host 'bash -s' <<'EOF' ...

# ✓ 對：script 先落地成檔案，再單獨把金鑰餵進去
scp installer.sh host:/tmp/ && cat crypto_key | ssh host 'bash /tmp/installer.sh'
```

這條規則是被兩次真實的 `FILE_CRYPTO_KEY` 外洩換來的（兩次都全量輪替了金鑰）。
細節見 `docs/RUNBOOK.md` §9。

## 出事時：診斷順序

1. `ops-scripts/mlp status` — 先看是哪一層。
2. **TCP connection refused** → 先懷疑 **fail2ban 封了你的 IP**，
   不是 sshd 死了。（Ubuntu 24.04 用 socket activation，
   `ssh.service` 顯示 inactive 是正常的，不代表壞掉。）
   查法：LISH 進去跑 `nft list table inet f2b-table`。
3. Gateway 完全進不去 → Linode LISH 主控台：
   ```bash
   ssh -t <linode帳號>@lish-ap-northeast.linode.com fws
   ```
   需要 `~/.ssh/id_rsa` 的公鑰在 **Linode profile 的 authorized_keys**
   （用 `linode-cli profile update --authorized_keys`，不是 SSH Keys 清單——
   LISH 不看那個），以及該台機器的 root 密碼。注意：除非你設了
   `GATEWAY_ROOT_PASSWORD` secret，rotate 產生的密碼是隨機且立刻丟棄的，
   這條路在現役機器上走不通——改用 `repair-gateway`。
4. provider 隧道斷 → `systemctl --user status pool-tunnel`，
   看 `journalctl --user -u pool-tunnel`。
5. 全部都不行 → Gateway 可以整台 rotate 掉重建，不會遺失狀態。

**一條反覆出現的教訓**（RUNBOOK 記錄了 5 次）：
*把觀察到的症狀當成原因*。TCP 被拒 → 「服務死了」；`visudo` 失敗 →
「規則寫錯了」；`nc -z` 通 → 「隧道健康」。
**規則：驗證你真正在乎的那件事，並且先確認你有能力做這個驗證，再下結論。**

## 文件

| 文件 | 讀它來知道 |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 為什麼這樣設計、GitHub vars 的 schema |
| [`docs/RUNBOOK.md`](docs/RUNBOOK.md) | 操作手冊、**事故紀錄與教訓** |
| [`docs/POOL_RUNTIME_SPEC.md`](docs/POOL_RUNTIME_SPEC.md) | 實作契約與實機驗收紀錄 |
| [`docs/LAYOUT.md`](docs/LAYOUT.md) | 目錄結構契約、unit 與 profile 的格式 |
| [`docs/REQ.md`](docs/REQ.md) | 原始需求 |
