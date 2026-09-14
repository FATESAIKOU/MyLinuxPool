# 專案結構契約

```
Root
├── shared_config/<unit>/      服務／工具的分發單位
├── profiles/<role>/<name>/    角色設定，明確列出要載入哪些 unit
├── scripts/                   業務邏輯，不依賴 GitHub Actions
├── ops-script/                人手動跑的東西（註冊、mlp）
├── .github/workflows/         只做 GitHub 專屬的事，其餘呼叫 scripts/
├── docs/  tests/
```

## 1. `shared_config/<unit>/` —— 分發單位

一個 unit 是「在一台機器上把某個服務／工具裝到可用狀態」所需的全部東西。

```
shared_config/<unit>/
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

### 目前的 unit

| unit | 內容 | needs_root |
|---|---|---|
| `pool-runtime` | `pool-resolve` `pool-tunnel` `pool-wol` `pool-status` `pool-port-alloc` + systemd unit | false |
| `rclone` | rclone 本體 + `rclone.conf.crypted` | true |
| `gh` | gh 本體 + token 檔 + git credential helper | true |
| `dotfiles` | `.bashrc` `.vimrc` `.tmux.conf` | false |
| `ssh-admin` | `fatesaikou` 的 ssh 身分（Gateway） | false |
| `ssh-tunnel` | `sshproxy` 的隧道身分（provider／worker） | false |
| `standalonescripts` | `dlpw` `uppw`（依賴 rclone） | false |

## 2. `profiles/<role>/<name>/`

**環境預載的每一項都要在這裡明確列出**，不再有「把整棵樹倒到 `/`」這種隱含行為。

### `profiles/gateway/<name>/`

```
profile.json      宣告
cloud-config.yaml cloud-init
```

```json
{
  "name": "default",
  "role": "gateway",
  "shared_config": ["pool-runtime", "ssh-admin", "ssh-tunnel", "rclone",
                    "standalonescripts", "dotfiles", "gh"],
  "packages": ["curl", "ca-certificates", "git", "jq", "netcat-openbsd",
               "util-linux", "iproute2", "fail2ban", "docker.io"],
  "sshd": { "password_auth": false, "permit_root_login": false },
  "fail2ban": { "ignoreip_from_var": "POOL_TRUSTED_IPS" }
}
```

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
├── provision-gateway.sh
├── rotate-gateway.sh
├── create-worker.sh
└── delete-worker.sh
```

`lib/ssh.sh` 內含跳板鏈的組裝與執行，**可在 Mac 上直接使用** ——
`ops-script/mlp` 與 workflow 都用它，不再各寫一份。

## 4. `.github/workflows/`

只做 GitHub 專屬的事：

- 讀 var（`gh api .../variables`）、寫 var（`gh variable set`）
- 從 secrets 取值並注入環境
- 呼叫 `scripts/` 裡的對應腳本
- 把結果寫回 var、發 `::error::`／`::notice::`

**流程判斷、重試、回滾的邏輯都在 `scripts/` 裡**，workflow 不重複實作。

## 5. `ops-script/`

人手動執行的東西。

- `register-provider.sh`（原 `provider/register.sh`）
- `mlp`（原 `bin/mlp`）

## 為什麼要這樣改

原本的 `static_normal_files/` + `static_secret_files/` 是**整個檔案系統的
覆蓋層**——把一棵樹倒到 `/` 上。它的問題：

1. 看不出「這台機器裝了什麼、為什麼」——只看得到一堆路徑
2. 無法組合：想讓 worker 也有 rclone，得複製路徑結構
3. 隱含耦合：`dlpw` 依賴 rclone，但沒有任何地方寫著這件事
4. 安裝邏輯散落在 `provision.sh` 與 workflow 裡，與檔案本身分離

改成以服務為分發單位後，每個 unit 自帶安裝邏輯與宣告，profile 明確列出
要什麼。「這台機器上有什麼」變成讀一個 JSON 就知道的事。

## 6. `--check` 的用途：找出宣告與實際的落差

每個 unit 的 `install.sh --check` 除了驗證「該裝的有沒有裝好」，還讓上層能
回答一個目前完全無法回答的問題：**這台機器上有沒有不該存在的東西？**

2026-09-14 的實例：Gateway 上有 `~/testSH/grc.sh`，但 repo 裡已經刪掉它了
——那台機器是在刪除之前 rotate 出來的。它是一個「repo 裡不存在、機器上卻
有」的孤兒。在舊結構下沒有任何機制看得見這件事，因為沒有地方寫著
「這台機器應該有什麼」。

profile 明確列出 unit 之後，`pool-status` 可以逐一跑 `--check` 並比對，
把落差報出來。這是舊的檔案系統覆蓋層做不到的。
