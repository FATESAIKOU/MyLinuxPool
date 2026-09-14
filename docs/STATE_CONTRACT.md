# 狀態契約

`state.json` 與 `POOL_WORKERS` 的格式。這是 Wave A 各任務之間唯一的介面——
實作與測試都以此為準，不以彼此的程式碼為準。

見 `REDESIGN.md` 的設計脈絡。

---

## 1. `POOL_WORKERS`（GitHub repo variable）

埠帳本的**主本**。JSON 陣列，依 `port` 遞增排序。

```json
[
  {
    "port": 2300,
    "provider": "fh-l",
    "image": "default",
    "container": "mlp-fh-l-default-34822789603",
    "created_at": "2026-09-14T08:26:00Z"
  }
]
```

| 欄位 | 型別 | 必填 | 說明 |
|---|---|---|---|
| `port` | integer | ✅ | Gateway loopback 上的轉發埠 |
| `provider` | string | ✅ | 承載此 worker 的 provider 節點名 |
| `image` | string | ✅ | `profiles/worker/<image>` |
| `container` | string | ✅ | provider 上的容器名 |
| `created_at` | string | ✅ | RFC3339 UTC |

規則：

- **唯一鍵是 `port`。** 同一個 port 不得出現兩筆。
- 空帳本是 `[]`，不是空字串、不是缺變數。
- 寫入者只有 `create-worker` 與 `delete-worker` 兩個 workflow。
- Gateway 上的 `~/.mylinuxpool/workers.d/<port>.json` 是這份的**快取**，
  內容為單筆物件（不是陣列）。

> **實際配發仍以 Gateway 為準。** 帳本記錄「誰宣稱佔用了哪個埠」，
> 但埠是否真的可用要看 `ss`——死掉的 session 會占著埠約一分鐘
> （`RUNBOOK.md` §7.9）。配發時兩者都要看。

---

## 2. `state.json`（Gateway 上的快取）

路徑 **`/var/lib/mylinuxpool/state.json`**，權限 **644**，擁有者 root。

> 不放家目錄：provider 是以 `sshproxy` 身分連進來的，讀不到
> `fatesaikou` 的家目錄（已實測確認）。

```json
{
  "schema": 1,
  "serial": 12,
  "written_at": "2026-09-14T09:02:19Z",
  "source": "rotate-gateway#34836287173",
  "nodes": {
    "gateway": {
      "name": "gateway", "role": "gateway",
      "ip": "172.104.114.31", "user": "fatesaikou",
      "tunnel_user": "sshproxy", "key_secret": "SSH_KEY_ACTIONS",
      "host_key": "ssh-ed25519 AAAA...",
      "generation": 8,
      "...": "NODE_GATEWAY 的完整內容，原樣"
    },
    "fh-l": { "...": "NODE_FH_L 的完整內容，原樣" },
    "fh-proxy": { "...": "NODE_FH_PROXY 的完整內容，原樣" }
  },
  "workers": [ "...POOL_WORKERS 的完整內容，原樣..." ]
}
```

| 欄位 | 型別 | 說明 |
|---|---|---|
| `schema` | integer | 目前為 `1`。讀取端遇到不認得的值必須**拒絕使用此快取並改問 GitHub**，不可嘗試解讀 |
| `serial` | integer | 單調遞增，每次推送 +1。與 Gateway 的 `generation` 無關 |
| `written_at` | string | RFC3339 UTC，僅供人閱讀，**不可用於邏輯判斷** |
| `source` | string | `<workflow>#<run_id>`，僅供追查 |
| `nodes` | object | 鍵為節點名（連字號版，如 `fh-proxy`），值為對應 `NODE_*` var 的**完整原樣內容** |
| `workers` | array | `POOL_WORKERS` 的完整原樣內容 |

### 不變式

1. **不得含任何金鑰或 secret 值。** 只有 `key_secret` 這種**名稱**。
   測試必須包含一個掃描：`state.json` 內不得出現 `BEGIN OPENSSH PRIVATE KEY`、
   `ghp_`、`ghu_` 等樣式。
2. `nodes` 的鍵一律用**連字號**（`fh-proxy`），不是 `fh_proxy`。
   var 名到節點名的轉換只在讀 GitHub 的那一層做。
3. `serial` 只增不減。若讀到的檔案 `serial` 比自己上次看到的小，
   視為**異常**並記錄，然後仍然採用（因為主本可能被還原過）。

---

## 3. 讀取順序（`pool-resolve`）

```
1. Gateway 的 state.json      無憑證，走既有隧道
2. GitHub var                  需要 token；Gateway 不可用或 schema 不認得時
3. 本機 30 秒快取              兩者皆不可用時的最後一層
```

- **快取是無條件信任的**——不驗證新舊。正確性由寫入端保證。
- **Gateway 自己的位址是唯一例外**，必須來自順位 2 或 3，否則是循環依賴。

---

## 4. 寫入時機

| workflow | 何時推送 |
|---|---|
| `rotate-gateway` | 新機器 provision 完成後、切換 `NODE_GATEWAY` 之前 |
| `create-worker` | 更新 `POOL_WORKERS` 之後 |
| `delete-worker` | 更新 `POOL_WORKERS` 之後 |
| `repair-gateway` | provision 之後 |

**推送失敗 = workflow 失敗。** 讀取端無條件信任快取，所以一份沒推成功的
快取就是錯誤狀態，不能降級成警告。

---

## 5. 給實作者：這份契約中最容易寫錯的地方

1. `nodes` 的鍵用連字號，不是底線。目前 `pool-resolve` 的本機快取
   同時存在 `fh_proxy.json` 與 `fh-proxy.json` 兩份，就是這個轉換沒統一造成的。
2. `state.json` 要放 `/var/lib/`，不是 `$HOME`。放家目錄 provider 讀不到，
   而且**測試若在同一台機器上以 `fatesaikou` 身分驗證，會看起來是通的**——
   必須以 `sshproxy` 身分驗。
3. 空帳本是 `[]`。`jq` 對缺變數與空字串的行為不同，兩種都要有測試。
4. 任何新加的檢查都必須附一個**證明它會失敗**的案例
   （`REDESIGN.md` §3.3，這是硬性要求）。
