# MyLinuxPool

把散落的 Linux 機器收束成一座叢集：一個公開入口、所有節點由它跳板進入、
機器可以整台換掉而不需要重新設定任何東西。

## 這座叢集長什麼樣

```
                GitHub Actions（控制平面）
                vars = 唯一真實來源
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

**進入任何節點的唯一路徑**：`ssh -J <gateway> -p <port> <user>@127.0.0.1`

## 日常操作

在 Mac 上用 `ops-scripts/mlp`：

```bash
ops-scripts/mlp                # 互動式選單
ops-scripts/mlp ls             # 列出所有節點與即時狀態
ops-scripts/mlp ssh            # 選一個節點登入
ops-scripts/mlp wake           # 喚醒 fh-l
ops-scripts/mlp down           # 關閉 fh-l
ops-scripts/mlp status         # 完整健康檢查
ops-scripts/mlp trust-gateway  # Gateway rotate 後第一次連線要跑這個
```

需要 `fzf` / `jq` / `gh`（`brew install fzf jq gh`）。

## 四個核心操作（GitHub Actions）

| Workflow | 做什麼 |
|---|---|
| `rotate-gateway` | 藍綠替換整台 Gateway。**`dry_run` 預設 `true`** |
| `create-worker` | 在指定 provider 上開一個容器並接進 Gateway |
| `delete-worker` | 停止容器並釋放埠 |

## 目錄

| 路徑 | 內容 |
|---|---|
| `profiles/gateway/<name>/` | Gateway 角色的 cloud-config + 宣告要裝哪些 unit |
| `profiles/provider/<name>/` | Provider 角色宣告（`default`／`no-sudo`） |
| `profiles/worker/<image>/` | Worker image 的 Dockerfile 與其 `profile.json` |
| `shared-configs/<unit>/` | 可分發安裝單位（`unit.json` + `install.sh` + `files/` + `tests/`），見 `docs/LAYOUT.md` |
| `scripts/` | 業務邏輯（不依賴 GitHub Actions），含 `lib/{log,crypto,ssh,profile}.sh` |
| `ops-scripts/` | 人手動跑的東西：`register-provider.sh`、`mlp`、`verify-profile` |
| `docs/` | 見下 |

## 文件

| 文件 | 讀它來知道 |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 為什麼這樣設計、GitHub vars 的 schema |
| [`docs/RUNBOOK.md`](docs/RUNBOOK.md) | 怎麼操作、出事怎麼查、**事故紀錄與教訓** |
| [`docs/POOL_RUNTIME_SPEC.md`](docs/POOL_RUNTIME_SPEC.md) | 實作契約與實機驗收紀錄 |
| [`docs/REQ.md`](docs/REQ.md) | 原始需求 |

## 幾個關鍵設計

- **GitHub vars 是定址的唯一真實來源。** rotate 只改一個 var，
  provider 每 30 秒輪詢、自己跟過去。實測：Gateway 換 IP 後 **1 秒**重連。
- **`{"via":"gateway"}` 遞迴跳板鏈。** provider 的 var 不重複寫 Gateway IP，
  所以 rotate 不會有漏改的地方。
- **不用 autossh。** 它只證明「連線活著」，不證明「Gateway 那端的 listener
  還在」。自製的監督程式從 Gateway 端探測 loopback 埠並讀 SSH banner。
- **機密只在執行時注入。** Worker image 內不含任何憑證；每個 image 用
  `profile.json` 宣告它需要哪些 secret（只寫名稱、不寫值）。

## 出事時

先跑 `ops-scripts/mlp status`。它會指出哪一層壞了，並在 TCP 被立即拒絕時提示去查
fail2ban —— 那正是 2026-09-13 導致整座叢集失聯 45 分鐘的原因
（見 `RUNBOOK.md` §7）。
