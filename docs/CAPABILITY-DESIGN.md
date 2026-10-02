# `capabilities`：能力就是一個單位

一個能力 = 一個單位目錄（`shared-configs/<unit>/`）。`unit.json` 的 `capability`
欄位宣告這個單位實作哪個能力鍵；`install.sh --check` 是那個能力的**唯一**判準。

寫這份文件的理由只有一句：**一個沒人驗的旗標會安靜地變成假的。**

## 1. 形狀

```json
"capabilities": {
  "worker-host": { "runtime": "docker" },
  "github":      { "repos": { "FATESAIKOU/MyBrain": ["read"] } },
  "wol":         { "methods": ["unicast"] }
}
```

| 規則 | |
|---|---|
| value 永遠是 **object** | 不是字串、不是陣列。空能力寫 `{}`，不寫 `null`（`null` 是「不知道」，`{}` 是「沒有參數」） |
| 不認得的 key **保留不動** | 消費端忽略自己不懂的，不得刪除 |
| 舊的陣列形狀**不並存** | 一次換掉，沒有相容讀取 |

## 2. 單位與三態

`install.sh --check` 的回傳碼就是「這個能力成不成立」：

| rc | 意義 | 誰會看到 |
|---|---|---|
| `0` | 成立 | 宣告保留 |
| `1` | **確定不成立** | 宣告移除這個鍵 |
| `2` | **無法確認** | 宣告**保留原值** |

`2` 必須和 `1` 分開，否則 GitHub API 一次 5xx 就會讓三台機器的宣告同時消失。
宣告抖動的代價是停在舊值比較久，這是使用者接受的取捨。

沒有任何單位實作某個鍵 → `2`，**不是 `1`**。

現在的單位：

| 單位 | `capability` | 判準（`--check`） |
|---|---|---|
| `worker-host` | `worker-host` | 以宣告的使用者跑 `docker info`。**不是** `id -nG`——群組在、socket 權限不對時它給出跟正常時一樣的答案 |
| `gh` | `github` | 形狀先驗（`repos` 必須是 object、權限必須是陣列），畸形 → `1` 且**不打 API**；非 `read` 的權限 → `2`（沒有定義驗證方式）；其餘對每個 repo 打一次 `gh api repos/<owner>/<repo>` |
| `wol` | `wol` | 已安裝的 `pool-wol` 存在、可執行、與本單位 `files/pool-wol` 逐位元組相同，且支援參數列的每個 `methods`。**不送封包**——送得出去不代表這台有資格送 |
| 其餘（`pool-runtime`、`rclone`、`dotfiles`、`standalonescripts`） | `<none>` | 不是能力，不進 `capabilities` |

新增一個能力 = 新增一個單位 + 在 profile 列它。**消費端不寫死任何能力鍵**——
唯一的例外是 `mlp wake` 自己需要的 `wol`（它要判斷「這台能不能當代送方」），
而那個字面只出現在 `mlp` 的 `node_wol_state` 一處。

## 3. 誰寫宣告

| 位置 | 來源 | 驗證 |
|---|---|---|
| `profiles/provider/<p>/profile.json` 的 `capabilities` | **設定**（人手寫的意圖） | — |
| `NODE_*.capabilities`（provider） | `pool-sync` 每個 tick 與 `register-provider` 註冊時，用 `capability_declaration` 算出來 | **有**，依 `2` 的三態 |
| `POOL_WORKERS[].capabilities`（worker） | `create-worker` 照 image profile 原樣複製 | **沒有，也不該有** |

兩件事要分清楚：

- **profile 是設定，var 是觀察結果。** profile 說「我希望有這些」；
  var 說「這些我現在真的驗過了」。`register-provider` 會先 `usermod -aG docker`
  再驗證，所以驗證跑在一個**群組已重新解析**的新 process 裡。
- **worker 不驗證。** `create-worker` 跑在 Actions runner 上，驗 `github`
  會在每次建 worker 時真的打一次 GitHub API。worker 的能力是**宣告**，
  由它自己的 image profile 決定。

宣告寫入的三條規則：只動 `capabilities` 這一個欄位、**零 dispatch**、
**宣告與現況相同時零寫入**（不重排整份 var 的鍵序）。

## 4. `mlp verify-capabilities <node>`

在**目標機器上**跑該單位自己的 `--check`——`docker`、`gh`、`pool-wol` 都在那裡，
而 provider 上沒有持久的 repo clone（`pool-sync` 用完就刪），所以整個單位
`tar`＋base64 送過去，在目標機器的 `mktemp -d` 裡解開、跑完、刪掉。

判定靠遠端印回來的 sentinel `MLP_CAP_RC=<rc>`，**不是** `ssh` 的回傳碼：
hop 鏈失敗時 `ssh` 也回 `1`，與單位的 `rc=1` 光看回傳碼分不出來。
**沒有 sentinel → `unverifiable`**，不會被說成「確定不成立」。

## 5. `wol` 與 `via`：兩件不同的事

| | 誰的 | 回答什麼 | 形狀 |
|---|---|---|---|
| `power.launch.via` | **被叫醒者** | 要叫醒我，**依序**先問誰 | 有順序的陣列（`mlp wake` 依序嘗試，順序就是優先順序） |
| `wol` 能力 | **發送者** | 我**有資格**發 magic packet 嗎 | `{"methods":["unicast"]}` |

`via` 是鏈路事實（依序嘗試），`wol` 是資格事實（這台的 `pool-wol` 到底能不能用）。
兩者不能互相取代：一個在 `via` 裡排第一的機器，可能根本沒裝 `pool-wol`。

> **更正本文件先前的裁定。** 舊版把這個能力命名為 `wol-sender`，並裁定
> **不做**——理由是「真相留在被叫醒者（`via`），旗標的 value 由它推導，
> 漏推導是靜默的」。已實作的決定不同，而且那個理由不成立：
> `wol` **不是** `via` 推導出來的欄位，它是**獨立的資格**，
> 由發送者自己的單位判定，不存在「漏推導」。名稱也從 `wol-sender` 改成 `wol`，
> 免得與 `via` 的角色名稱撞名。`wol-sender` 這個鍵不存在。
>
> `NODE_FH_PROXY.wol_sender`（9/13 的舊 schema 欄位）**已經從主本刪除**
> （使用者同意後刪的）。repo 內沒有任何程式讀它（`grep wol_sender` 零命中），
> MyAiEntry 也沒有。取代它的是該機器的 `wol` 能力，由 `wol` 單位自己的
> `--check` 判定資格。

## 6. 遷移

`mlp migrate-capabilities` 一次換掉，不並存。**它只做形狀轉換，不新增能力**：

| 現值 | `cap_migrate_value` 的輸出 |
|---|---|
| `["docker","worker-host"]` | `{"worker-host":{"runtime":"docker"}}` |
| `["docker","worker-host","wol-sender","wsl2"]` | `{"worker-host":{"runtime":"docker"}}` |
| 陣列但沒有 `worker-host` | `{}` |
| 已經是 object（含不認得的 key） | 原樣輸出 |

**`wol` 不在這一列。** 舊標籤裡的 `wol-sender` 與 `wsl2` 在遷移時**直接丟掉、不給替代**——
`wol` 是後來由 `pool-sync` 驗證之後才寫進 `NODE_*.capabilities` 的（§2、§3），
不是遷移產生的。`wsl2` 是平台事實不是能力。

> 歷史紀錄：遷移曾經有過「落地後 app 會壞掉」的風險（app 當時做
> `capabilities.includes('worker-host')`，對 object 回 false）。**已經解除**：
> MyAiEntry 的 `parseCapabilities()`（`src/port/pool/capabilities.ts`）讀 object 形狀，
> 不認得的 key 原樣保留。

## 7. 不做

- 相容讀取（兩種形狀都吃）
- worker 的 GitHub 憑證注入實作（只定義契約與方向，實作另案）

> **能力名稱已經會顯示給人看了。** app 的承載機說明裡會列出能力名稱
> （`「承載機，提供能力：github、worker-host、wol。」`）。
> **顯示名稱怎麼對應是 app 側的決定**——池側只提供鍵，不指定顯示文字。
> 正因為這句話會進到人的判斷裡，鍵的名稱才要準確。
