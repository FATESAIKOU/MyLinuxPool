# `capabilities`：從標籤換成帶契約的能力旗標

主本裡每台機器的 `capabilities` 目前是扁平字串陣列。消費端（手機 app）已經在
依它挑機器，但標籤沒有參數，表達不了「能叫醒誰」「能存取哪個 repo」。

換成 `key: value`。key 不重複（JSON object 天然保證），value 是自由 JSON
**但每個 key 的契約固定**——自由指的是形狀因 key 而異，不是每台機器各寫各的。

---

## 0. 動手前查到的三件事

**一、我這側沒有任何東西讀 `capabilities`。** 全 repo 只有 `register-provider.sh:509`
在註冊時預設寫入，以及幾支測試確認「發布是 merge、這個欄位要留著」。唯一真的
消費者是手機 app。所以這是**替一個只有外部消費者的欄位定義契約**。

**二、它已經在漂移。** `fh-proxy-asus` 沒有 `wol-sender`，但它是 `fh-l` 的第一順位
代送者，2026-09-25 實測叫醒過四次；而 `fh-proxy` 有那個旗標。一個沒人讀、也沒人
驗證的宣告，會安靜地變成假的——這正是本設計要解決的事，也是它的現成證據。

**三、worker 沒有任何 GitHub 憑證，而 Dockerfile 的註解說它有。**
`Dockerfile:14` 寫「GH_TOKEN / GH_WORKER_TOKEN arrive via `docker run -e`」，
實際 `docker run` 只帶 `POOL_GATEWAY_{FILE,PORT,HOST,USER}` 與 `POOL_NODE_NAME`。
註解過期，而且方向危險——它讓人以為有一個不存在的東西可以依賴。

---

## 1. 形狀

```json
"capabilities": {
  "worker-host": { "runtime": "docker" },
  "github":      { "repos": { "FATESAIKOU/MyBrain": ["read"] } }
}
```

規則：

- key 是能力的名字，**value 永遠是 object**（不是字串、不是陣列）。
  空能力寫 `{}`，不寫 `null`——`{}` 是「有這個能力、沒有參數」，`null` 是「不知道」。
- 不認得的 key **保留不動**。消費端各自忽略自己不懂的，不得刪除。
- **不並存。** 舊的字串陣列一次換掉，不留相容讀取。

## 2. 每個 key 的契約

每個 key 定義三件事：value 的形狀、**怎麼驗證這個宣告是真的**、誰負責驗。
第二件是重點——一個不驗證的旗標，會讓消費端挑到一台做不到那件事的機器，
而失敗發生在使用者看不到的地方。

### `worker-host`

```json
"worker-host": { "runtime": "docker" }
```

能承載 worker 容器。`runtime` 目前只有 `docker` 一種值。
**舊的 `docker` 標籤併進來**——它從來不是一個獨立能力，是 `worker-host` 的實作方式。

**驗證**：以宣告中的使用者身分跑 `docker info`。不是檢查 `id -nG` 有沒有 docker 群組
——群組在、socket 權限不對時，`id -nG` 會給出跟正常時一樣的答案。
（這個判準是 2026-09-25 修 `register-provider` 時定下的，沿用。）

### `github`

```json
"github": { "repos": { "FATESAIKOU/MyBrain": ["read"] } }
```

`repos` 的 key 是 `owner/repo`，value 是權限陣列（`read` / `write` / `trigger-actions`）。
不列出的 repo 就是沒有能力，不需要寫成空陣列。

**驗證**：對每個宣告的 repo 實際打一次 API，而不是檢查有沒有 token 檔。
`read` 用 `gh api repos/<owner>/<repo>`；`write` 與 `trigger-actions` 的驗證各自定義，
**沒有定義驗證方式的權限值不得使用**。

**provider 與 worker 的來源不同**：
- provider 的憑證是 `~/.mylinuxpool/gh_token`，註冊時寫入，所以宣告與現實一致
- worker **不持有持久化的憑證**（使用者裁定）。要讓 worker 帶這個能力，
  憑證在 `docker run -e` 時注入，容器刪掉就沒了。
  `profiles/worker/<image>/profile.json` 已經有 `secrets: {}` 這個槽位但一直是空的
  ——接的就是它。

> ⚠️ 這條與「worker 不持有持久化的 Key」有張力，處理方式是**把「持久化」講清楚**：
> 注入的 token 只活在容器的 process environment 裡，不落磁碟、不進 image、
> 容器重建就要重新注入。它仍然是「worker 拿得到 GitHub 權限」，
> 所以那把 token 必須是**窄權限的**（只有宣告中列出的 repo 與權限），
> 不能直接用 `GH_POOL_TOKEN`。
>
> **worker 帶權限的完整設計另案處理**（使用者已言明）。本設計只定義旗標的契約，
> 以及「注入而非持久化」這個方向；在那個設計完成之前，
> **不要在任何 worker 的 profile 裡宣告 `github`**。

### `wol-sender`

⚠️ **建議這一輪不做，理由如下。**

提出這個 key 的需求是「app 想回答：fh-l 睡著了，誰叫得醒它？」
但那個問題現有欄位**一次讀取就答得出來**：

```
NODE_FH_L.power.launch.via = ["fh-proxy-asus", "fh-proxy"]
```

被叫醒者持有自己的代送者清單，這是正方向不是反查。`wol-sender` 旗標答的是
**相反的問題**（「這台能叫醒誰」），而目前沒有任何消費端提出那個需求。

使用者已裁定「真相留在被叫醒者，旗標的 value 由它推導」。推導而且要存，就會有
「什麼時候重新推導」這個問題，而漏推導是靜默的。**沒有消費端的推導欄位，
是一份保證會過期的資料。** 等真的有人需要「這台能叫醒誰」時再加。

## 3. 範圍：provider 與 worker

`capabilities` 目前只在 `NODE_*`。`POOL_WORKERS` 的每一筆沒有這個欄位。

worker 的能力**來自它的 image profile**，不是每個容器各自宣告——同一個 image
起出來的容器能力相同。所以：

- 能力寫在 `profiles/worker/<image>/profile.json`
- `create-worker` 建立容器時把它複製進 `POOL_WORKERS` 的那一筆
- 消費端讀 `POOL_WORKERS` 就看得到，不必再去翻 profile

## 4. 驗證什麼時候跑

- **註冊時**（`register-provider.sh`）：宣告什麼就驗什麼，驗不過就讓註冊失敗。
  這是既有做法的延伸——`docker` 那條 2026-09-25 已經這樣做了。
- **隨時**：新增 `mlp verify-capabilities [<node>]`，把宣告逐條跑一次驗證並回報。
  這條存在的理由是第 0 節的第二點：宣告會漂移，而漂移沒有徵兆。

**不做**定期自動驗證。理由是它需要一個常駐的地方跑、要處理失敗通知，
而目前沒有那個基礎設施；先讓人問得出來，再談要不要自動問。

## 5. 遷移

一次換掉，不並存。

| 現值 | 新值 |
|---|---|
| `["docker","worker-host"]` | `{"worker-host":{"runtime":"docker"}}` |
| `["docker","worker-host","wol-sender","wsl2"]` | `{"worker-host":{"runtime":"docker"}}` |

`wsl2` 丟掉——那是平台事實不是能力，而且沒有任何消費端讀它。
真的需要「這台是什麼平台」時，那是另一個欄位，不是能力。

`wol-sender` 丟掉，理由見 §2。

> ⚠️ **手機 app 的「新增 worker」在遷移落地後會壞掉**，直到它改讀新格式。
> 它現在做的是 `capabilities.includes('worker-host')`，對 object 會回 false。
> 使用者已知情並指定「我方做完 archive 之後 app 那邊才動」。
> 落地當下要立刻通知對面。

## 6. 不做

- 相容讀取（兩種格式都吃）
- 定期自動驗證
- `wol-sender`（§2）
- worker 的憑證注入實作（只定義契約與方向，實作另案）
- 把 `capabilities` 暴露給 AI 看（那是 app 側的決定，而且旗標的措辭一旦進 AI 視野
  就等於對 AI 的指令，命名不精確會讓它做錯事）

## 7. 任務拆分

### impl
1. `register-provider.sh` step 5 的預設值改成新形狀
2. 驗證：`worker-host` 的 `docker info`（已存在，接進契約）
3. `mlp verify-capabilities [<node>]`
4. `create-worker` 把 image profile 的 capabilities 複製進 `POOL_WORKERS`

### test
每條都要先證明沒修正時會紅：

| 注入 | 應該轉紅 |
|---|---|
| 宣告 `worker-host` 但 docker 不通 | 註冊仍然成功 |
| 驗證改成檢查 `id -nG` | 群組在、socket 不通時通過 |
| value 寫成字串而不是 object | 格式檢查沒擋住 |
| 不認得的 key 被刪掉 | 保留規則失效 |
| `create-worker` 沒複製 capabilities | worker 的能力消失 |

### qa
1. 獨立確認 repo 內沒有第二個讀 `capabilities` 的地方
2. 遷移後三台 provider 的 var 形狀正確、其餘欄位未被動到
3. `mlp ls` / `wake` / `down` / `ssh-config` 無回歸
4. 全套測試與 preflight 全綠
