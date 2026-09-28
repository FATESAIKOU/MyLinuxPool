# 專案結構契約

```
Root
├── profiles/<role>/<name>/     角色設定，明確列出要載入哪些 unit
├── shared-configs/<unit>/      服務／工具的分發單位（自帶 install.sh 與 tests/）
├── scripts/                    業務邏輯，不依賴 GitHub Actions
├── ops-scripts/                人手動跑的東西（register-provider、register-repair-host、mlp、verify-profile、register-client、preflight、pool-residue）
│
├── .github/workflows/          薄殼：只做 GitHub 專屬的事，其餘呼叫 scripts/
├── docs/                       文件
└── README.md  .gitignore
```

**根目錄只有四個程式目錄。** `.github/`、`docs/`、`README.md` 是基礎設施與
文件，不是程式，屬於另一個層次。

不存在 `gateway/`、`provider/`、`bin/`、`tests/` —— 它們的職責分別落在：

| 原本 | 現在 | 為什麼 |
|---|---|---|
| `gateway/provision.sh` | `scripts/provision-gateway.sh` | 是業務邏輯，被 rotate 呼叫 |
| `provider/register.sh` | `ops-scripts/register-provider.sh` | 人手動跑的 |
| `bin/mlp` | `ops-scripts/mlp` | 人手動跑的 |
| `tests/` | `shared-configs/<unit>/tests/` | **測試跟著被測物走**——測 `pool-resolve` 的測試屬於 `pool-runtime` 這個 unit |

最後一條值得說明：unit 自帶 `tests/` 之後，一個 unit 就完整了——
`unit.json` 宣告它是什麼、`install.sh` 裝它、`--check` 驗部署狀態、
`tests/` 驗程式行為。不需要去別的地方找它的任何一部分。

## 1. `shared-configs/<unit>/` —— 分發單位

一個 unit 是「在一台機器上把某個服務／工具裝到可用狀態」所需的全部東西。

```
shared-configs/<unit>/
├── unit.json      宣告
├── install.sh     安裝
└── files/         要佈署的檔案（*.crypted 由 install.sh 解密）
```

### `unit.json`

```json
{
  "name": "rclone",
  "description": "rclone 與其設定檔",
  "needs_key": true,
  "needs_root": true,
  "provides": ["rclone"]
}
```

- `needs_key`：`files/` 內有 `.crypted` 時為 `true`，install.sh 必須收 `--key`
- `needs_root`：是否需要 root（例如 apt 安裝）。`false` 的 unit 必須能在
  `--no-sudo` 的機器與容器內完整安裝
- `provides`：安裝後應該存在的指令，供驗收檢查

### `install.sh` 的介面（**所有 unit 一致**）

```
install.sh [--key <FILE_CRYPTO_KEY>] [--home <dir>] [--user <name>] [--check]
```

- `--home` 預設 `$HOME`、`--user` 預設當前使用者 —— 讓同一個 unit 能裝到
  Gateway 的 `fatesaikou`、provider 的 `fatesaikou`、或容器裡的 `worker`
- `--check`：只檢查是否已安裝且正確，不做任何修改，退出碼表示結果
- **冪等**。重跑必須安全
- 金鑰只經 `--key` 或 stdin 傳入，**不得**寫進任何檔案或日誌
- 日誌沿用 `[YYYY-MM-DDTHH:MM:SSZ] LEVEL ` 格式

### 跨目錄依賴：`scripts/lib/crypto.sh`

`needs_key: true` 的 unit 都靠 `../../scripts/lib/crypto.sh`（相對於自己
的 `SCRIPT_DIR`，呼叫 `crypto.sh decrypt <key>`）解密 `files/*.crypted`——
這是**刻意的**跨目錄依賴，用意是避免每個 unit 各自複製一份解密邏輯。代價
是：**單獨佈署 `shared-configs/` 而不帶 `scripts/` 會讓每個 needs_key unit
的 install.sh 找不到解密工具**。（`crypto.sh` 原本是兩支各自獨立的
`encryptStdin.sh`／`decryptStdin.sh`，2026-09-15 這輪重構合併成一支、提供
`encrypt`／`decrypt` 兩個子指令，介面不變。）

2026-09-15 實機踩到：只打包 `shared-configs/` 送上 Gateway（當時 crypto
腳本還叫 `decryptStdin.sh`），`ssh-tunnel-server` 因為它不存在而無法解密，
但當時的程式碼把「沒有能力檢查」誤報成「檢查不通過」（印出「不變式被違
反」），讓人差點去改根本沒問題的資料。現在每個 unit 的 install.sh 在使用
`crypto.sh` 之前都會先確認它存在且可執行，不存在就以明確訊息中止（說明這
個 unit 依賴 `scripts/lib/crypto.sh`，需要跟 `shared-configs/` 一起佈
署），而不是讓解密指令默默失敗後繼續用空/錯的內容跑下去。

**佈署 `shared-configs/` 到任何機器時，務必連同 `scripts/` 一起帶上。**

### 目前的 unit

| unit | 內容 | needs_root |
|---|---|---|
| `pool-runtime` | `pool-resolve` `pool-tunnel` `pool-wol` `pool-status` `pool-port-alloc` `pool-sync` + 3 個 systemd unit（`pool-tunnel.service`、`pool-sync.service`、`pool-sync.timer`） | false |
| `rclone` | rclone 本體 + `rclone.conf.crypted` | true |
| `gh` | gh 本體 + token 檔 + git credential helper | true |
| `dotfiles` | `.bashrc` `.vimrc` `.tmux.conf` | false |
| `standalonescripts` | `dlpw` `uppw`（依賴 rclone） | false |

> **2026-09-16（KEY-DESIGN §8）刪除了三個 unit**：`ssh-admin`、
> `ssh-tunnel-client`、`ssh-tunnel-server`。它們的工作分別被取代了——
> 登入清單由 `CLIENT_*` var 組出來（`pool-sync` 在 provider 上收斂、
> rotate／refresh 寫 Gateway），隧道身分改成每台機器自產、只上傳公鑰。
> repo 裡因此不再有任何私鑰。下面那段講的是它們被刪之前的歷史。

> **2026-09-15 修正**：`ssh-tunnel-client`／`ssh-tunnel-server` 原本是同一個
> `ssh-tunnel` unit，裝的是 sshproxy 的私鑰——這在 provider/worker（撥出的
> 一方）上是對的，但同一份 profile 套到 Gateway（被撥入的一方）上語意就錯
> 了：Gateway 需要的是 authorized_keys，不是私鑰。同一個名字底下裝著兩種
> 不同的東西，只是恰好都叫「sshproxy 的隧道身分」，所以拆成兩個 unit。

## 2. `profiles/<role>/<name>/`

**環境預載的每一項都要在這裡明確列出**，不再有「把整棵樹倒到 `/`」這種隱含行為。

> **命名提醒（容易混淆，故意分開講）**：下面每份 `profile.json` 裡的
> `"shared_config"` 是**JSON 欄位名**，用底線；目錄本身叫
> **`shared-configs/`**，用連字號。兩者拼法不同是刻意的——前者是資料
> （profile 宣告要哪些 unit），後者是路徑（那些 unit 實際住在哪個目錄）。
> 讀 `profile.json` 時看到 `shared_config` 不要以為打錯字、也不要以為要去
> 找一個叫 `shared_config/` 的目錄——它就是在講 `shared-configs/` 裡的
> unit，只是欄位名沒有跟著目錄改名。2026-09-15 的 create-worker 建置失敗
> （Dockerfile 裡 `COPY shared_config/...` 是純字串，語法檢查與
> `verify-profile` 都測不到）就是這兩種寫法混淆之下，路徑那一份沒改乾淨
> 才漏掉的。

### `profiles/gateway/<name>/`

```
profile.json      宣告
cloud-config.yaml cloud-init
```

```json
{
  "name": "default",
  "role": "gateway",
  "shared_config": ["pool-runtime", "ssh-admin", "ssh-tunnel-server", "rclone",
                    "standalonescripts", "dotfiles", "gh"],
  "packages": ["curl", "ca-certificates", "git", "jq", "netcat-openbsd",
               "util-linux", "iproute2", "fail2ban", "docker.io"],
  "sshd": { "password_auth": false, "permit_root_login": false },
  "fail2ban": { "ignoreip_from_var": "POOL_TRUSTED_IPS" }
}
```

### `profiles/provider/<name>/`

```
profile.json      宣告
```

```json
{
  "name": "default",
  "role": "provider",
  "shared_config": ["pool-runtime", "ssh-tunnel-client", "gh"],
  "systemd_user_services": ["pool-tunnel.service"],
  "linger": true,
  "sudoers_rules": [
    "ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff, /usr/sbin/ethtool"
  ]
}
```

- `systemd_user_services`：安裝完 `shared-configs` 之後要 `enable --now` 的
  `systemctl --user` 服務名稱（檔案本身由宣告的 unit 負責放好，例如
  `pool-runtime` 放 `pool-tunnel.service`；這裡只負責啟用）
- `linger`：是否需要 `loginctl enable-linger`（讓 `--user` 服務在登出後繼續活著）
- `sudoers_rules`：要寫進 `/etc/sudoers.d/mylinuxpool` 的規則（不含使用者名稱，
  由呼叫端組出 `<user> <rule>`）；空陣列代表這個 profile 刻意不要任何 sudoers 規則

`systemd_user_services` / `linger` / `sudoers_rules` 是**非 unit** 的宣告——
沒有對應的 `shared-configs/<unit>/`，因為它們描述的是「這台機器除了裝檔案
之外還需要什麼系統層級的設定」，不是「裝什麼檔案」。任何角色的 profile
都可以用這三個欄位，不是 provider 專屬。

**同一個角色、兩種最終狀態**：`ops-scripts/register-provider.sh` 支援 `--no-sudo`
（沒有 sudo 密碼的機器，例如 fh-proxy），這台機器就是裝不了 sudoers
規則——這不是缺陷，是這台機器**真實的最終狀態**。用兩個 profile 表達，
而不是一個 profile 加執行期旗標：

```
profiles/provider/default/profile.json    # 有 sudo：fh-l
profiles/provider/no-sudo/profile.json    # 沒有 sudo：fh-proxy，sudoers_rules 是空陣列
```

兩者的 `shared-configs` 完全一樣——差異只在 `sudoers_rules`。`register.sh`
依 `--no-sudo` 旗標選對應的 profile；`ops-scripts/verify-profile` 只驗
`shared-configs` 裡的 unit（見 §6 的範圍說明），從不檢查 `sudoers_rules`
有沒有落地，所以 `--no-sudo` 機器缺 sudoers 規則不會被誤判成落差——它本來
就沒被宣告要有。

**第三種：`profiles/provider/repair/`（家人維修承載機，issue #6）**——這台不在自己身上跑
`register-provider.sh`，也不跑 `pool-sync`，所以 `shared_config` 是空陣列；它的一切由
`ops-scripts/register-repair-host` 在 Mac 上渲染成 cloud-init 開機資料。多出的兩個欄位
`login_user`（VM 裡唯一的登入使用者，也是 `NODE_<NAME>.hops` 指向的使用者）與
`user_data_template`（同目錄的 cloud-config 模板，佔位符是 `@@NAME@@` 形狀）只給那支指令讀。

### `profiles/worker/<name>/`

```
profile.json  Dockerfile  entrypoint.sh
```

```json
{
  "name": "default",
  "role": "worker",
  "shared_config": ["pool-runtime"],
  "secrets": {},
  "env": {}
}
```

`secrets` 是「容器內環境變數名 → GitHub secret 名」的對應，只寫名稱不寫值
（原 §10.2b 的規則不變）。

## 3. `scripts/` —— 業務邏輯

**不得出現任何 GitHub Actions 專屬的東西**：`$GITHUB_OUTPUT`、`::error::`、
`${{ }}`、`gh variable set`、`gh api .../variables` 都不行。

- 需要節點資訊 → 由呼叫端以參數或環境變數傳入
- 需要回報結果 → 印到 stdout／stderr，用退出碼表示成敗
- 需要記錄狀態 → 回傳給呼叫端，由呼叫端決定寫到哪

```
scripts/
├── lib/{log.sh,crypto.sh,ssh.sh,profile.sh}
├── tests/                     純函式測試，不碰網路
├── provision-gateway.sh
├── rotate-gateway.sh
├── create-worker.sh
└── delete-worker.sh
```

`tests/` 沿用「測試跟著被測物走」那條原則（§2）：`scripts/` 的檔案是
function library，可以 `source` 進來直接測，不需要真機。
需要真機的驗證屬於 `ops-scripts/verify-profile`，不在這裡。

`lib/ssh.sh` 內含跳板鏈的組裝與執行，**可在 Mac 上直接使用** ——
`ops-scripts/mlp` 與 workflow 都用它，不再各寫一份。

## 4. `.github/workflows/`

只做 GitHub 專屬的事：

- 讀 var（`gh api .../variables`）、寫 var（`gh variable set`）
- 從 secrets 取值並注入環境
- 呼叫 `scripts/` 裡的對應腳本
- 把結果寫回 var、發 `::error::`／`::notice::`

**流程判斷、重試、回滾的邏輯都在 `scripts/` 裡**，workflow 不重複實作。

## 5. `ops-scripts/`

人手動執行的東西。

- `register-provider.sh`（原 `provider/register.sh`）
- `mlp`（原 `bin/mlp`）
- `register-client`：把「這台機器」註冊成 client，`mlp register client` 轉呼叫它
- `register-repair-host`：在 Mac 上替一台家人維修承載機登錄（寫 `NODE_<NAME>`、觸發 refresh、產出 cloud-init NoCloud 開機資料）；模板在 `profiles/provider/repair/`
- `verify-profile`：把某台機器的實際狀態與它的 profile 宣告對照，見 §6
- `preflight`：推 master 前在本機跑一次的靜態檢查（引用的檔案真的存在嗎）
- `pool-residue.sh`：池側殘骸的唯讀快照，列容器／`POOL_WORKERS`／Gateway 的
  placeholder、`ss`、`state.json` 五個視角，給「create-worker 失敗回滾到底收不
  乾淨」用；不注入故障、不下結論

> 這份清單與 `README.md` §目錄表是**同一件事的兩份副本**。2026-09-26 發現
> `register-client` 與 `preflight` 早已在 `ops-scripts/` 卻不在這裡——兩份都
> 是手寫的，漏了不會有任何人發現。`scripts/tests/test-script-self-location.sh`
> 改成從 repo 列舉檔名（同一個形狀的第三份複本，見該檔檔頭）。

## 為什麼要這樣改

原本的 `static_normal_files/` + `static_secret_files/` 是**整個檔案系統的
覆蓋層**——把一棵樹倒到 `/` 上。它的問題：

1. 看不出「這台機器裝了什麼、為什麼」——只看得到一堆路徑
2. 無法組合：想讓 worker 也有 rclone，得複製路徑結構
3. 隱含耦合：`dlpw` 依賴 rclone，但沒有任何地方寫著這件事
4. 安裝邏輯散落在 `provision.sh` 與 workflow 裡，與檔案本身分離

改成以服務為分發單位後，每個 unit 自帶安裝邏輯與宣告，profile 明確列出
要什麼。「這台機器上有什麼」變成讀一個 JSON 就知道的事。

## 6. `--check` 的用途與現在的範圍

每個 unit 的 `install.sh --check` 驗證的是**單一方向**：「profile 宣告的
這個 unit，在這台機器上有沒有裝好」。profile 明確列出 unit 之後，
`pool-status` 可以逐一跑每個宣告 unit 的 `--check` 並比對，把「宣告了但
沒裝好」的落差報出來——這是舊的檔案系統覆蓋層做不到的，因為舊結構下沒有
任何地方寫著「這台機器應該有什麼」。

> **目前不做的事：反過來抓孤兒**。`--check` 不會掃機器上的檔案、反查有
> 沒有任何 profile 宣告過它——也就是說，它回答不了「這台機器上有沒有不
> 該存在的東西」。2026-09-15 把 `shared-configs/` 送上現行 Gateway 逐一跑
> `--check` 時，翻出了 `~/testSH/grc.sh`（repo 裡已刪除的舊檔，2026-09-14
> 就發現過一次）與 `~/testSH/pws`（來源不明）——這兩個都是人工比對「機器
> 上有什麼」與「profile 宣告了什麼」才找到的，`--check` 本身認不出它們。
> 孤兒偵測（列出機器上的檔案、與所有已裝 unit 的 `files/` 清單反向比對、
> 報出多餘項目）是明確未做的能力，需要另外設計——不要以為現在的
> `--check` 已經涵蓋這件事。
