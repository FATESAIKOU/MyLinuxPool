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
| `SSH_KEY_SSHPROXY` | provider / worker | 由下往上掛反向隧道 |

**不變式**：`shared-configs/ssh-tunnel-client/files/id_rsa.pub.crypted` 的內容
必須出現在 `shared-configs/ssh-tunnel-server/files/authorized_keys.crypted` 裡。
兩者脫鉤時，所有 provider 會一起 `Permission denied (publickey)`。

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
不做任何修改。

## 角色設定：`profiles/<role>/<name>/profile.json`

```json
{
  "name": "default", "role": "provider",
  "shared_config": ["pool-runtime", "ssh-tunnel-client", "gh"],
  "systemd_user_services": ["pool-tunnel.service"],
  "linger": true,
  "sudoers_rules": ["ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff, /usr/sbin/ethtool"]
}
```

**每一個預載的資料夾、設定檔，都在 profile 裡明確列出來。**
沒列的東西不會被裝上去。

Worker 的 profile 多一個 `secrets` 欄位，映射「容器環境變數名 → GitHub secret 名」
——只有名稱，永遠不寫值。image 裡不含任何憑證，機密只在 `docker run` 時注入。

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
ops-scripts/mlp trust-gateway  # rotate 之後第一次連線要先跑這個
```

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

**兩個失去就救不回來的**：

- `FILE_CRYPTO_KEY` — 解開 9 個 `.crypted` 檔的對稱金鑰。GitHub secret 是
  唯寫的，讀不回來。失去它系統還活著，但你再也無法註冊新機器或檢視機密。
- `GATEWAY_ROOT_PASSWORD` — 只存在你手上。SSH 完全進不去時經 LISH 救援的唯一辦法。

`GH_POOL_TOKEN`、`LINODE_TOKEN` 可以重新產生。
`FH_L_SUDO_PASSWORD` / `FH_PROXY_SUDO_PASSWORD` 零程式碼引用，隨時可改。

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

1. 用舊金鑰把 9 個 `.crypted` 全部解開。
2. 產新金鑰，全部重新加密。
3. `gh secret set FILE_CRYPTO_KEY`，更新 `SECRETS.md`。
4. **兩台 provider 各重跑一次 `register-provider.sh`**（它們本機存了副本）。

`ssh-tunnel-client` 的公鑰與 `ssh-tunnel-server` 的 `authorized_keys`
必須同步更新，否則所有隧道一起斷。

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
   LISH 不看那個），以及 `SECRETS.md` 裡的 root 密碼。
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
