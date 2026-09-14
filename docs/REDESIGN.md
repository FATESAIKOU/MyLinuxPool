# 全體架構重審（2026-09-14）

起因：狀態散落在多處，而其中一處是**設計上就會被丟棄**的機器。
今天的實機測試連續暴露同一類問題，所以重新審視整體，而不是逐點補丁。

- [1. 需求](#1-需求)
- [2. 基本設計](#2-基本設計)
- [3. 任務與測試規劃](#3-任務與測試規劃)

---

# 1. 需求

## 1.1 功能需求（沿用 `REQ.md`，全部仍然有效）

| | 需求 | 現況 |
|---|---|---|
| R1 | Rotate Gateway | ✅ 實機驗證多次（gen 3→8） |
| R2 | Launch / Shutdown Fh-l | ✅ `mlp wake` / `mlp down` |
| R3 | Create / Delete Worker | ✅ 含動態埠配發 |
| R4 | RegisterProvider：rotate 後不用重註冊、重開機會復活 | ✅ |
| R5 | 連線資訊在 GitHub var（一台一個），金鑰在 secret、var 只指名稱 | ✅ |
| R6 | 加密的預載資料（rclone；browser profile 之後） | ✅ rclone |
| R7 | Worker dockerfile 資料夾 | ✅ `profiles/worker/` |
| R8 | `dlpw` / `uppw` 可用 | ✅ `standalonescripts` |

**功能面沒有缺口。** 這次重審的對象是下面的非功能需求。

## 1.2 非功能需求（今天的實測逼出來的）

這些以前是隱含假設，現在寫成明文，因為每一條都已經被違反過至少一次。

**N1 Gateway 必須維持可丟棄。**
它今天被重建了 5 次。任何存在上面的東西都必須能從別處重建，否則 rotate
就變成資料遷移。已經發生過：埠帳本只存在 Gateway，rotate 後全部 worker
變成工具看不見的孤兒（`RUNBOOK.md` §8）。

**N2 邊緣不持有超出所需的憑證。**
Gateway 是唯一有公開 IP 的機器；worker 是拋棄式的。兩者都不應持有
`FILE_CRYPTO_KEY`（能解開全部加密檔）或 `SSH_KEY_ACTIONS`（所有機器的管理權）。
> 現況違反：Gateway 上有 `/home/fatesaikou/.ssh/id_rsa`，且無任何自動化使用它。

**N3 單一元件中斷必須自癒，不需人工介入。**
已驗證的情境：Gateway rotate、provider 重開機、實體斷網、容器重啟。
未驗證：GitHub 不可用。

**N4 每個檢查都必須「有能力失敗」，每個錯誤都必須說實話。**
今天出現 **9 次**同一形狀的缺陷：檢查了一個比在乎的東西更容易滿足的條件，
或替失敗編造一個從未驗證過的原因。代價包含一次真實的鎖門事故與一次無法診斷
的 rotate 失敗。
> 具體規則：(a) 新增檢查時必須實測它在該失敗時真的失敗；
> (b) 不得宣稱未經驗證的失敗原因；(c) 「無法驗證」與「驗證失敗」是兩件事。

**N5 宣告即真相，且可驗證。**
unit 的 `--check` 必須比對**內容**，不是檔案存在。
> 曾因此讓 `verify-profile` 對一台 `authorized_keys` 完全錯誤的機器回報 `matches`。

**N6 不得假設所有 provider 都在線。**
`fh-l` 是桌機，平常關機——這是常態不是例外。
> 曾因此讓 rotate 在 fh-l 睡著時必定失敗。

## 1.3 本次新增需求

**N7 狀態集中：一個主本、一個快取。**

- **主本在 GitHub repo**（持久、有版本、只有 token 能寫）
- **Gateway 是快取**：活著時所有節點先問它
- Gateway 連不上 → 回頭問 GitHub 要最新 Gateway 位址 → 重連
- **金鑰不進快取**（依 N2）——快取只放叢集狀態

動機：
1. provider 目前每 30 秒打一次 GitHub API，只為了發現 rotate
2. 沒有任何一個地方能看到「叢集現在長怎樣」
3. 埠帳本沒有主本（違反 N1）

**N8 每台機器上的持久狀態趨近於零。**
除了**身分**與**憑證**，任何機器上的 `~/.mylinuxpool/` 內容都必須是
可重建的衍生物——整個刪掉之後系統要能自己長回來。

盤點（節點 = 主本的副本，副本越多、越不一致的機會越大）：

| 機器 | 內容 | 性質 |
|---|---|---|
| Mac | `known_hosts`、`cache/`、`ssh_config` | 全部可重建 |
| provider | `config`（節點名） | **身分**——不可衍生 |
| provider | `gh_token` | **憑證**——不可衍生 |
| provider | `repo/`、`bin/`、`gateway/`、`gateway_known_hosts`、`cache/` | 全部可重建 |
| Gateway | `repo/`、`bin/`、`workers.d/` | 全部可重建（帳本改為 `POOL_WORKERS` 的快取後） |
| worker | 無（掛載 + 環境變數） | 已經是 0 |

> 驗收判準：在 provider 上刪掉除 `config` 與 `gh_token` 以外的一切，
> 系統必須自行恢復，不需人工介入。

---

# 2. 基本設計

## 2.1 三層

```
┌─ 主本 ─────────────────────────────────────────────┐
│ GitHub repo                                        │
│   vars    NODE_*  POOL_TRUSTED_IPS  POOL_WORKERS★  │
│   secrets FILE_CRYPTO_KEY SSH_KEY_ACTIONS          │
│           GH_POOL_TOKEN   LINODE_TOKEN             │
│   repo    *.crypted（加密的預載資料）、程式碼        │
└──────────────────┬─────────────────────────────────┘
                   │ Actions 在任何狀態變更後推送
                   ▼
┌─ 快取 ─────────────────────────────────────────────┐
│ Gateway  /var/lib/mylinuxpool/state.json           │
│   叢集狀態（含 serial），**不含金鑰**                │
│   644，sshproxy 讀得到                              │
└──────────────────┬─────────────────────────────────┘
                   │ 走既有隧道讀取
                   ▼
┌─ 邊緣 ─────────────────────────────────────────────┐
│ provider   pool-resolve：快取 → GitHub → 本機       │
│ worker     讀所在 provider 發布的 gateway.json      │
└────────────────────────────────────────────────────┘
```

★ = 新增

## 2.2 為什麼主本不是 Gateway

Gateway 每天被丟棄數次。把主本放上去，rotate 就必須遷移狀態，而遷移失敗時
「哪一份是對的」沒有好答案。GitHub var 反過來：持久、有稽核、只有 token 能寫，
而且 rotate **本來就在寫它**。

Gateway 當快取則沒有這個問題：推送失敗只是退回問 GitHub，不會遺失任何東西。
連帶好處是**今天加的「搬移埠帳本」步驟可以移除**——新機器直接從主本取得狀態。

## 2.3 `state.json` 格式（契約）

```json
{
  "serial": 8,
  "written_at": "2026-09-14T09:02:19Z",
  "source": "rotate-gateway#34836287173",
  "nodes": {
    "gateway":  { "...": "NODE_GATEWAY 的完整內容" },
    "fh-l":     { "...": "NODE_FH_L" },
    "fh-proxy": { "...": "NODE_FH_PROXY" }
  },
  "workers": [
    { "port": 2300, "provider": "fh-l", "image": "default",
      "container": "mlp-fh-l-default-34822789603",
      "created_at": "2026-09-14T08:26:00Z" }
  ]
}
```

- `serial` 單調遞增，讀取端據此判斷新舊；與 Gateway 的 `generation` **無關**
  （狀態可以在不換機器的情況下改變，例如新增 worker）
- **不含任何金鑰或 secret 值**
- 路徑 `/var/lib/mylinuxpool/state.json`，不是家目錄——provider 是以
  `sshproxy` 身分連進來的，讀不到 `fatesaikou` 的家目錄（已實測確認）

## 2.4 讀取路徑

`pool-resolve <node>` 依序嘗試：

| 順位 | 來源 | 何時用得上 | 需要憑證 |
|---|---|---|---|
| 1 | Gateway 的 `state.json`（走既有隧道） | 穩態 | 否 |
| 2 | GitHub var | Gateway 換人或掛掉 | 是 |
| 3 | 本機 30 秒快取 | GitHub 也不可用 | 否 |

**快取是無條件信任的**（2026-09-14 決議）。讀取端不去驗證它新不新——
要驗證就得問 GitHub，那省 API 的目的就落空了，是循環論證。
正確性改由**寫入端**保證：任何改變狀態的 workflow，**推完快取才算完成**，
推送失敗就是 workflow 失敗。

**Gateway 自己的位址是唯一例外**：它必須來自 GitHub 或本機快取，
否則就是先有雞還是先有蛋。這也正是 N7 描述的 failback。

穩態下 provider 不再打 GitHub API。`GH_POOL_TOKEN` 降級為**只在
Gateway 換人時使用**。

## 2.5 埠帳本

配發仍在 Gateway（`ss` 才是真相，佔用中的埠不能重複配），
但結果由 workflow 寫回 `POOL_WORKERS` var：

```
create-worker:  Gateway 配發 → workflow 寫 POOL_WORKERS → 推 state.json
delete-worker:  Gateway 釋放 → workflow 寫 POOL_WORKERS → 推 state.json
rotate:         新機器從主本還原 workers.d（取代現有的「搬移」步驟）
```

Gateway 依然零 GitHub 憑證：它只被寫入，不主動寫 GitHub。

## 2.6 失敗模式

| 情境 | 行為 |
|---|---|
| Gateway 掛了 | 節點退回問 GitHub；`mlp` 亦同 |
| GitHub 掛了 | 節點用 Gateway 快取；已連線者不受影響 |
| 兩者都掛 | 節點用本機 30 秒快取重建隧道（現有行為，保留） |
| state.json 比 var 舊 | **不會發生**——見下方「無條件信任」 |
| 推送 state.json 失敗 | **workflow 失敗**。既然讀取端無條件信任快取，一份沒推成功的快取就是錯誤狀態，不能當成小事 |

## 2.7 一併收尾的既有缺陷

| | 缺陷 | 併入 |
|---|---|---|
| D1 | 埠帳本在 `~/pool/`，其餘在 `~/.mylinuxpool/` | 帳本任務 |
| D2 | `pool-resolve` 快取鍵重複（`fh_proxy` / `fh-proxy` 兩份，`--refresh` 只刷一份） | 讀取路徑任務 |
| D3 | Gateway 上有無人使用的 `id_rsa`（違反 N2） | 獨立小任務 |

## 2.8 N8 帶來的設計含意

**provider 的 `gh_token` 是唯一擋在「零狀態」前面的東西。**
有一條路可以再往下砍：rotate 在**切換之前**，透過還活著的舊 Gateway
把新位址推給每一台掛著的 provider。這樣計畫性的 rotate 完全不需要 GitHub，
token 退化成「Gateway 非計畫性死亡」時的破窗工具。

本次**不做**，但設計上不要擋死：`state.json` 的推送機制天生就能拿來做這件事。

其餘衍生物的處理原則：**能重建就不要保護它**。
`bin/`、`repo/`、`cache/`、`gateway_known_hosts` 都不需要備份、不需要遷移、
不需要在 rotate 時搬運——刪掉就重建。

---

# 3. 任務與測試規劃

## 3.1 先決條件（PM 自己做，不派工）

**T0 契約定案**：`state.json` 與 `POOL_WORKERS` 的 schema 寫成
`docs/STATE_CONTRACT.md`，含 JSON Schema 與範例。
所有後續任務以此為介面，才能真正平行。

## 3.2 任務

每個任務配一組 **impl + test**，兩人各自獨立，test 不看 impl 的實作細節。

### Wave A（T0 完成後可同時開始，彼此無依賴）

| 任務 | 內容 | 主要檔案 |
|---|---|---|
| **A1 帳本主本** | `POOL_WORKERS` var 讀寫；`pool-port-alloc` 改用 `~/.mylinuxpool/workers.d`，保留舊路徑相容讀取（D1） | `pool-port-alloc`、`scripts/create-worker.sh`、`scripts/delete-worker.sh` |
| **A2 狀態產生器** | 從 GitHub 組出 `state.json` 並推到 Gateway 的函式；serial 遞增規則 | `scripts/lib/state.sh`（新） |
| **A3 讀取路徑** | `pool-resolve` 三層順序；快取鍵正規化（D2） | `pool-resolve` |
| **A4 清理** | 移除 Gateway 上未使用的 `id_rsa`（D3） | `shared-configs/ssh-admin/install.sh` |

### Wave B（依賴 Wave A）

| 任務 | 依賴 | 內容 |
|---|---|---|
| **B1 生產端：workflow 推送** | A1 A2 | 四個 workflow 在狀態變更後把 `state.json` 推到 Gateway；rotate 移除「搬移帳本」步驟，改為從主本還原 |
| **B2 消費端：節點抓取** | A2 A3 | `pool-tunnel` 透過既有的控制通道把 Gateway 的 `state.json` 取回本機 `~/.mylinuxpool/state.json` |
| **B3 mlp 整併** | A3 B2 | `mlp` 走同一條讀取路徑；新增 `mlp state` 顯示主本與快取的差異 |

> **B2 是原始規劃漏掉的一環。** A3 只做了「本機有 `state.json` 就優先用它」，
> 但沒有任何元件負責把檔案放到本機。少了 B2，第一層讀取永遠不會命中，
> 整條快取路徑等於沒接上——而且**不會有任何錯誤**，只會安靜地退回問 GitHub。
> 這正是 N4 所說「檢查不出來的失敗」的一種：功能沒接上，但每個測試都是綠的。
>
> 驗收方式必須是行為性的：在 provider 上確認一次 `pool-resolve` **沒有**
> 產生 GitHub API 呼叫（V1），而不是只確認函式存在。

## 3.3 測試方式

**每個任務的 test 必須包含三層**：

1. **純函式測試**（無網路，`scripts/tests/`）
   格式解析、serial 比較、快取鍵正規化、帳本合併

2. **失敗注入 —— 這是強制項（N4）**
   每個新檢查都必須附一個**證明它會失敗**的案例。
   > 今天有兩個檢查印了 FAIL 卻 `exit 0`，還有一個「檔案存在就算通過」
   > 讓錯誤的機器連續數小時回報正常。**沒有失敗案例的測試不算完成。**

3. **實機驗收**（我執行，不派工）

### 實機驗收清單

| # | 情境 | 判準 |
|---|---|---|
| V1 | 穩態 | provider 不再打 GitHub API（用 token 的存取記錄確認） |
| V2 | Rotate | 新 Gateway 一佈署好就有正確的 `state.json`；不需搬帳本 |
| V3 | Rotate 時 fh-l 關機 | 成功；醒來後自己接上新 Gateway |
| V4 | Gateway 不可用 | 節點退回 GitHub 並重連 |
| V5 | **GitHub 不可用**（新，從未測過） | 已連線節點不受影響；Gateway 快取仍可服務 |
| V6 | 實體斷網 | 60 秒回收殭屍埠、恢復（維持現有表現） |
| V7 | Worker 跟隨 rotate | 容器 ID 不變 |
| V8 | `verify-profile` | 三台皆 `matches`，且比對內容 |
| V9 | **零狀態（新）** | provider 上刪掉除 `config`、`gh_token` 外的一切，系統自行恢復 |

V5 的模擬方式：在 provider 上把 `api.github.com` 指到黑洞，或撤掉 token
（後者較貼近真實：token 過期是實際會發生的事）。

## 3.4 派工方式

- 全部經 **herdr** 開啟，`opencode ollama-cloud/deepseek-v4.1-flash`
- 一個任務兩個 pane：`impl-<任務>`、`test-<任務>`
- Wave A 四個任務可完全平行 → 最多 8 個 pane，視資源分批
- PM（我）：契約、review、實機驗收、不寫實作程式碼

## 3.5 不在本次範圍

- browser profile 預載（`REQ.md` 註明「現在先不需要」）
- 把金鑰快取到 Gateway（違反 N2，已決議不做）
- 用 Gateway 當主本（違反 N1，已決議不做）
