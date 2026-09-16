# 金鑰配置重新設計（提案 — 尚未實作）

> 狀態：**提案，等待 review**。本文不描述現況，描述的是打算變成的樣子。
> 現況見 `README.md` 與 `docs/ARCHITECTURE.md`。

## 1. 現況與問題

系統裡有三把金鑰：

| | 身分 | 私鑰在哪 | 公鑰在哪 |
|---|---|---|---|
| A | Actions | GitHub secret `SSH_KEY_ACTIONS` | `ssh-admin/files/authorized_keys.crypted` |
| B | 隧道（`sshproxy`） | **`ssh-tunnel-client/files/id_rsa.crypted`（repo 裡，全叢集共用一把）** | `ssh-tunnel-server/files/authorized_keys.crypted` |
| C | 操作者本人 | 他自己的機器 | `ssh-admin/files/authorized_keys.crypted` |

兩個問題：

**B 是全叢集共用的一把私鑰。** 任何一個 worker 容器被打穿，拿到的是**每一台**
provider 與 worker 都在用的那把。輪替它要同時動到所有機器，所以實務上永遠不會輪替。

**授權清單是靜態加密檔。** 加一個使用者要：解密 → 加一行 → 重新加密 → commit →
逐台套用。需要 `FILE_CRYPTO_KEY`，而且 provider 上只有重跑註冊才會套用
（`pool-sync` 跳過需要金鑰的 unit）。repo 裡**沒有任何文件化的「加人」程序**。

## 2. 目標

1. **repo 裡不存在任何私鑰。** 私鑰只存在於產生它的那台機器上。
2. **一台機器被打穿，只波及那一台。** 不再有「一把鑰匙開全部」。
3. **加／移除一個使用者是一個動作**，而且會自己傳播到三種機器。
4. 不增加邊緣的憑證。worker 容器裡仍然**沒有** GitHub token。

## 3. 核心設計

### 3.1 兩類存取，分開處理

| 類別 | 誰連誰 | 落在哪個帳號 |
|---|---|---|
| **登入** | 人／Actions → Gateway、provider、worker | Gateway 的 `fatesaikou`、provider 的 `fatesaikou`、worker 的 `worker` |
| **隧道** | provider／worker → Gateway | Gateway 的 `sshproxy` |

兩類都改成同一個形狀：**私鑰在誰手上，誰自己產；公鑰進 GitHub var；
authorized_keys 由消費端從 var 組出來。**

### 3.2 公鑰住在哪 — 不要新開 var 家族

這是對原始構想的第一個修正。公鑰塞進**已經存在**的 var：

| 公鑰 | 存放位置 | 誰寫 | 怎麼撤銷 |
|---|---|---|---|
| provider 的隧道公鑰 | `NODE_<NAME>.tunnel_public_key` | `register-provider.sh` | 節點下線就刪 var |
| worker 的隧道公鑰 | `POOL_WORKERS[].tunnel_public_key` | `create-worker` | **`delete-worker` 刪掉條目即自動撤銷** |
| 使用者的登入公鑰 | `CLIENT_<NAME>`（新 var 家族） | `register-client` | `register-client --remove` |
| Actions 的登入公鑰 | `CLIENT_ACTIONS` | 人工設一次 | — |

理由：worker 的建立／刪除很頻繁，若每個 worker 一個獨立 var 會製造大量
var churn；塞進 `POOL_WORKERS` 則**刪除條目就是撤銷**，不必記得多做一步。
provider 同理塞進 `NODE_*`——`register-provider.sh` 本來就在寫那個 var。

只有「使用者」需要新家族，因為它跟任何既有實體都不對應。沿用 `NODE_*` 的
命名慣例與列舉方式（`gh api .../actions/variables --paginate` 後依前綴過濾）。

### 3.3 什麼時候產金鑰 — 註冊時，不是每次啟動

這是第二個修正。原始構想寫「每次啟動／註冊都自己產」，**每次啟動不行**：

機器重開機 → 產生新金鑰 → 但 Gateway 上的授權清單還是舊的 → 連不上
→ 而更新 Gateway 的授權需要有人跑 Actions → **機器重開機就要人介入**。

所以：**provider 在 `register-provider.sh` 時產生一次，之後重開機沿用。**
金鑰存在 `~/.ssh/id_pool`（位置不變），重開機時已經在那裡。
worker 則是每次 `create-worker` 產一把新的——worker 本來就是每次重建，
容器刪掉金鑰就跟著消失，這正好。

輪替一台 provider 的隧道金鑰＝重跑一次註冊。**單機輪替，不必動其他機器**
——這正是要買的東西。

### 3.4 誰負責組裝 authorized_keys

| 目標 | 由誰組裝 | 何時 | 需要 `FILE_CRYPTO_KEY`？ |
|---|---|---|---|
| Gateway `sshproxy` | Actions（provision／rotate） | rotate、新 provider 註冊後、worker 建立時 | 否 |
| Gateway `fatesaikou` | Actions（provision／rotate） | 同上 | 否 |
| provider `fatesaikou` | **provider 自己（`pool-sync`）** | 每 30 分鐘 | **否** |
| worker `worker` | provider 發布 → worker 讀檔 | 每 30 秒 | 否 |

**第三個修正：provider 的 authorized_keys 不再需要 `repair-provider`。**
公鑰在 var 裡，而 var 用 `gh_token` 就讀得到——provider 本來就有 token。
`pool-sync` 今天跳過 `ssh-admin` 是因為它 `needs_key: true`；改成從 var 組裝
之後就不需要金鑰，於是**登入清單變成自癒的**。這比 `repair-provider` 更好：
不是「有人記得跑一次」，而是每 30 分鐘自動收斂。

**第四個修正：沒有 `repair-worker`。** worker 容器裡沒有 token，不能自己讀 var。
但它所在的 provider 有。provider 已經在發布
`~/.mylinuxpool/gateway/gateway.json` 到一個唯讀 bind mount 給容器；
同一個目錄再多發布一個 `authorized_keys` 即可，worker 的 `pool-tunnel`
每 30 秒讀一次。加一個使用者**不必重建 worker**，容器裡也仍然沒有 token。

## 4. 各流程的變化

### `register-client`（新）

```
register-client [--name <名字>] [--remove]
```

1. 本機沒有金鑰就產一對 ed25519（**私鑰不離開本機**）
2. 公鑰寫進 `CLIENT_<NAME>` var（需要 gh token 參數）
3. 觸發一次 Gateway 授權刷新（見 §5）
4. 寫好本機的 `~/.mylinuxpool/ssh_config`、釘 Gateway host key

provider 與 worker 會在下一輪自癒時自己拿到，不需要這支腳本去推。

> **它只上傳公鑰。** 任何情況下都不把私鑰送上 GitHub 或送進機器。

### `register-provider.sh`（改）

- 新增：產生隧道金鑰對（若 `~/.ssh/id_pool` 不存在），公鑰寫進 `NODE_<NAME>`
- 移除：安裝 `ssh-tunnel-client` 的共用私鑰（該 unit 整個消失）
- 新增：註冊完要觸發 Gateway 授權刷新，否則新機器連不上（見 §5）

### `create-worker` / `delete-worker`（改）

- create：容器啟動時**自己**產一對金鑰（2026-09-16 起；原本由 Actions 產、
  經 `docker run -e WORKER_KEY=` 注入，私鑰因此出現在 provider 的 `ps`、
  `docker inspect` 與網路上）。私鑰不離開容器，
  公鑰寫進 `POOL_WORKERS` 條目；**先刷新 Gateway 授權，再啟動容器**
- delete：刪掉 `POOL_WORKERS` 條目即撤銷，再刷新 Gateway 授權

### `rotate` / `provision-gateway.sh`（改）

- cloud-init 的 `${FATESAIKOU_PUBKEY}` / `${SSHPROXY_PUBKEY}` 佔位符
  **機制不變**，但值改成「從 var 組出來的多行清單」而不是單一把
- provision 時把兩份 authorized_keys 寫成組裝結果

### `pool-sync`（改）

- 新增：從 var 組裝並收斂本機的 `~/.ssh/authorized_keys`
- 新增：組裝 worker 用的 authorized_keys，發布到 bind mount 目錄

## 5. 引導問題：新機器的公鑰還不在 Gateway 上

原始構想沒有涵蓋這一點，但它是這個設計唯一的真死結：

```
新 provider 註冊 → 公鑰寫進 var → 想撥隧道進 Gateway
                                   ↑ 但 Gateway 的授權清單是上次 provision 時組的
```

需要一個**窄的刷新動作**：只重組 Gateway 的兩份 authorized_keys，不做完整
provision。用途有三處：`register-client` 之後、`register-provider` 之後、
`create-worker` 建立容器之前。

它必須是 Actions（只有 Actions 同時有進 Gateway 的身分與讀 var 的權限）。
`register-provider.sh` 在 provider 上跑，所以它只能**派發** workflow 然後等
——它有 gh token，做得到。

## 6. 鎖死風險與退路

組裝授權清單的動作本身，有可能把執行它的人鎖在門外。

| 風險 | 防線 |
|---|---|
| 組出來的清單漏掉 Actions 自己的公鑰 | 寫入前硬性檢查 `CLIENT_ACTIONS` 在清單裡，否則中止不寫 |
| 組出來是空的（var 讀取失敗） | 空清單一律視為錯誤，不寫入 |
| 清單寫壞導致 Actions 進不去 Gateway | `rotate` 建的是**全新機器**，authorized_keys 由 cloud-init 從 var 重新渲染，不依賴舊機器 → rotate 是退路 |
| provider 自癒寫壞自己的 authorized_keys | 同 `ssh-admin` 現行做法：預設**聯集**安裝，不刪既有；要刪必須明示 |

> 注意這比現況**更**安全：今天若 `authorized_keys.crypted` 寫壞，rotate 出來的
> 新機器一樣是壞的（它讀同一個檔）。改成 var 之後，壞掉的是資料不是程式，
> 改 var 立刻生效。

## 7. 這個設計會讓什麼消失

- `shared-configs/ssh-tunnel-client/`（整個 unit——它只存在於分發那把共用私鑰）
- `shared-configs/ssh-tunnel-server/files/authorized_keys.crypted` ✅ 已刪（2026-09-16，task U）
- `shared-configs/ssh-admin/files/authorized_keys.crypted` ✅ 已刪（task U）
- `shared-configs/ssh-admin/files/id_rsa.crypted` ✅ 已刪（task U）
- `ssh-tunnel-server/install.sh` 裡那條「私鑰推導的公鑰必須在清單裡」的不變式 ✅ 已刪
- `shared-configs/ssh-admin/`（整個 unit，靜態清單的載體）✅ 已刪（task U）

**`FILE_CRYPTO_KEY` 的守備範圍已縮小（task U 落地）**：只剩 `rclone`、
`dotfiles`、`standalonescripts` 三個 unit 在用。它不再是「掌握全叢集 ssh
存取」的金鑰——登入清單由 `CLIENT_*` 組裝、隧道身分是各機自己的
`id_tunnel`，兩者都不需要它。

## 8. 取捨與未解

- **var 數量**：每個使用者一個 var。GitHub 每 repo 上限 1000 個，不成問題。
- **worker 授權有 30 秒延遲**：加一個使用者之後，既有 worker 要等下一輪發布。
  可接受——worker 是 cattle。
- **撤銷不是即時的**：刪掉 var 之後，Gateway 要等下一次刷新。
  `register-client --remove` 會主動觸發刷新，但已建立的 ssh session 不會被踢。
  若需要即時撤銷，得額外殺 session——**本次不做**，先記在這裡。
- **`CLIENT_ACTIONS` 是特例**：它的私鑰在 secret 而非某台機器上。本質相同
  （私鑰在使用者手上，Actions 就是那個使用者），但它是唯一一個私鑰存在
  GitHub 的身分——因為 Actions 沒有「自己的機器」。

## 9. 實作切分（建議）

| # | 任務 | 相依 |
|---|---|---|
| 1 | `CLIENT_*` var 格式 + 組裝函式（純函式，可單測） | — |
| 2 | 窄刷新 workflow：重組 Gateway 兩份 authorized_keys | 1 |
| 3 | `register-client` | 1, 2 |
| 4 | `pool-sync` 從 var 收斂 provider 的 authorized_keys | 1 |
| 5 | provider 隧道金鑰自產（`register-provider.sh`） | 1, 2 |
| 6 | worker 隧道金鑰每次新產（`create-worker` / `delete-worker`） | 1, 2 |
| 7 | rotate／provision 改用組裝結果 | 1 |
| 8 | 刪掉 §7 列的東西 | 全部 |

1–4 做完就能「加一個使用者、三種機器自己收斂」，而且**不動隧道**——
風險低、可以先落地驗證。5–7 才是拆掉共用私鑰，動到連線本身，要單獨驗收。
