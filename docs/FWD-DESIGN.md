# `mlp fwd` 基本設計

把「臨時下 `ssh -L` 去戳 worker/provider 上的某個埠」變成可管理的操作，
並且能把節點當成跳進它所在網路的入口。

範圍是**這台電腦的客戶端功能**：池裡零狀態，Gateway 不知道，別人連不到。

---

## 1. 使用者介面

```
mlp fwd add <node> [entryip:]entryport[:targethost:targetport]
mlp fwd ls
mlp fwd rm [entryport|bind:entryport]
```

參數是 `ssh -L` 的形狀，省略的部分有預設：

| 寫法 | 意義 |
|---|---|
| `8080` | `127.0.0.1:8080` → 節點自己的 `8080` |
| `9090:8080` | `127.0.0.1:9090` → 節點自己的 `8080` |
| `0.0.0.0:9090:8080` | 所有介面的 `9090` → 節點自己的 `8080` |
| `8080:192.168.0.50:80` | `127.0.0.1:8080` → **節點看得出去的** `192.168.0.50:80` |

最後一列是重點：`ssh -L` 的 target 本來就在**遠端**解析，所以「節點自己」
與「節點看得到的第三方主機」是同一條程式碼路徑，不需要為後者多做任何事。

一條轉發的身分是 `bind:entryport`，碰撞看的是**重疊**，兩者是多對多——
「entryport 天然唯一」是設計錯誤。`add` 對同埠的現有每一筆逐一比 bind：
bind 相同即完全重複，擋；任一方是萬用位址（`0.0.0.0`／`::`／空）即重疊，擋；
兩個**不同的具體位址**（如 `127.0.0.1` 與 `192.168.0.224`）同埠則放行，
各自獨立、無歧義。

為什麼萬用位址參與就要擋，實測（本機 darwin，python socket）：
無 `SO_REUSEADDR` 時，`0.0.0.0:P` 之後再綁 `127.0.0.1:P` 得 `EADDRINUSE`；
有 `SO_REUSEADDR`（`ssh` 會設）時兩條都成功，連 `127.0.0.1:P` 的流量被
「較具體」的那條靜默接走。所以 UAT 以 lsof 看到兩條共存，不是「沒事」的
證據，而是「核心不會幫我們擋」的證據——兩條都 up、卻通往不同節點，
正是這個 repo 反覆踩到的「看起來健康、實際說謊」，只能自己擋。

`rm` 接受 `entryport` 或 `bind:entryport` 兩種寫法（`add` 吃 bind，
`rm` 不吃的不對稱已消掉；`::` 這類含冒號的 bind 以最後一個冒號切分）。
省略時用 fzf 挑（挑中的列直接帶完整 `bind:entryport` 刪，不再只取埠），
與 `mlp ssh`、`mlp worker rm` 一致。萬一同埠出現多筆（舊殘留），
`rm` 不准靜默挑一條：拒絕並列出候選，由使用者指定完整 `bind:port`。

---

## 2. 真實來源：作業系統

**沒有設定檔。** 「現在有哪些轉發」這個問題的答案，只能來自實際在跑的東西：

- `~/.mylinuxpool/fwd/fwd-<bind>-<entryport>` 是每條轉發的 ControlPath
- 完整參數（node、target、埠）從**進程表**讀回來（`ps` 看得到 `-L` 的完整內容）

為什麼不寫設定檔：設定檔會與現實不同步，於是產生「檔案說有、實際沒有」
這一類狀態。這個 repo 這幾天反覆被同一類問題咬到——看起來健康、實際不通。
少一份可能說謊的來源，就少一種騙人的方式。

代價是重開電腦之後什麼都不記得。這是刻意接受的：不做開機恢復。

路徑長度：基底 `/Users/<user>/.mylinuxpool/fwd/` 約 35 字，ControlPath 全長
上限 104 bytes，餘裕約 69 字。（今天才踩過這個限制，所以先量。）

---

## 3. 分層（MVVM）

規則只有三條，違反就是設計沒落實：

- **Model**：回傳資料，**一個字都不印**
- **ViewModel**：決策與動作，**不印字、不叫 fzf**
- **View**：`printf`、顏色、fzf。**不碰 ssh、不碰 gh**

### Model

| 函式 | 輸入 | 輸出 | 網路 |
|---|---|---|---|
| `fwd_records` | — | 每行 `bind⇥entryport⇥node⇥targethost⇥targetport⇥pid⇥ctl` | 否 |
| `fwd_probe <ctl> <targethost> <targetport>` | — | `tunnel_state⇥target_state⇥rtt_ms` | 是 |
| `target_resolve <name>` | 節點名 | `type⇥user⇥loopback_port` | 是 |

`target_resolve` 是從現有 `do_connect` 抽出來的——它目前同時做「解析」與
「連線」兩件事。抽出來之後 `do_connect` 與 `fwd_add` 共用同一份解析，
不會各自長出一份。**這是這次唯一要動到的現有邏輯。**

### ViewModel

| 函式 | 職責 |
|---|---|
| `fwd_add <node> <spec>` | 解析 spec、`target_resolve`、起 master、驗證、回傳狀態碼（碰撞看 bind:port 重疊：同 bind 或任一方萬用即擋，異具體位址放行） |
| `fwd_remove <entryport\|bind:entryport>` | `-O exit`、清掉 socket、回傳狀態碼（同埠多筆時拒絕並列出候選） |
| `fwd_status` | `fwd_records` 逐筆配上 `fwd_probe`，回傳加料後的記錄 |

### View

`cmd_fwd`：解析子指令與參數、fzf 挑選、排版、上色、把 `0.0.0.0` 標成醒目。
互動選單（`main_menu` 的 `fwd-add/fwd-ls/fwd-rm`）：fzf 挑節點、提示輸入 spec、`ls` 直接顯示、`rm` 用 fzf 挑——流程屬 View 層，分層規則照舊。

---

## 4. 健康檢測

兩段，而且**都要有真實封包**。

### 隧道

判準是「透過既有 master 跑一個遠端命令並拿到結果」：

```
ssh -S <ctl> <host> true
```

**不是** `ssh -O check`。`-O check` 只問本機那個 master 進程「你還在嗎」，
封包從來沒出網路——線路早就斷掉它照樣回報 OK。那正是這個 repo 這幾天
反覆踩到的失敗模式：**防線問了一個「壞掉時不會給出不同答案」的問題。**

### 目標

從**節點上**對 `targethost:targetport` 發一次 TCP，用結束碼**加遠端 stderr** 分四態：

```
timeout 3 bash -c 'exec 3<>/dev/tcp/<host>/<port>'
  0                                     → open          有服務
  124                                   → inconclusive  分不出沒路由還是被擋  ← 誠實說分不出
  stderr 含 "Connection refused"         → refused       主機在、沒服務        ← 仍算健康
  其餘非 0                               → unreachable   沒路由／主機不可達
```

只看結束碼時「主機不存在」會被誤報成 `refused`（真線實測，fh-proxy 上跑）：
`192.168.0.136:9999` 回 rc=1、7ms、`Connection refused`——封包到了，是 `refused`；
`192.168.0.253:80` 同樣回 rc=1、卻花了 3004ms、訊息是 `No route to host`——
封包哪裡都沒到，卻也被說成到達了。結束碼在這兩者之間**給不出不同答案**，
沿用三態等於重蹈隧道那段 `-O check` 的覆轍，所以 stderr 必須參與分類。

`refused` 算健康，因為它**證明封包到達了目標主機**——主機回了 RST。
這正是「不管目標有沒有服務都能測」的答案：沒有服務不會被誤報成不通。

`inconclusive` 與 `unreachable` 都不算健康，但兩者意義不同，不要合併：
`inconclusive` 是「我不知道」（可能是沒路由、可能是防火牆丟包，工具分不出來，
就說分不出來）；`unreachable` 是「我知道到不了」（對端明確說沒路由／不可達）。

命名的規矩（MyAiEntry 那側的 PM 在對照我們做法時整理出來，這裡採用）：
**名字要跟後果綁在一起，不要跟症狀綁。** 第三態以前叫 `timeout`——概念是對的、
判準是對的、上面的解釋也把意思說清楚了，但名字本身只說了症狀（逾時了），
沒說後果；它是靠旁邊的註解活著的，註解一拿掉，`timeout` 看起來就像
「發生了一次逾時」而不是「我們沒有結論」。`inconclusive` 把後果寫進名字：
看到它的人知道該去查，而不是以為只是慢。他們的反例是把逾時標成 validation——
後果完全不同（一個要改參數，一個要去確認遠端狀態），名字卻長得像沒事。
同理，這裡不用 wake 那邊的 `unknown`：那是「送出了但無法驗證喚醒結果」
（後果：機器可能已醒，去 `mlp ls` 確認），這裡是「探測得不到答案」
（後果：查路由／防火牆）——後果不同，不共用名字。

---

## 5. 要改的現有程式碼

只有兩處，都是加法：

1. **`scripts/lib/ssh.sh` 的 `ssh_via_gateway`**
   目前 `shift 7` 之後 `$@` 全當遠端命令，無法插入 `-L`。
   加一個選用的 `SSH_EXTRA_OPTS` 陣列，拼在 `-p` 之前，預設空。
   不帶就與現在逐位元組等價。
   > 待 QA 獨立確認：`pool-ssh`（Actions 用的）走的是 `ssh_jump_chain`，
   > 沒有呼叫 `ssh_via_gateway`。這句話目前只有單一來源，不接受。

2. **`ops-scripts/mlp` 的 `do_connect`**
   把其中的解析抽成 `target_resolve`，`do_connect` 改為呼叫它。
   行為不變，只是讓 `fwd_add` 能共用。

其餘 15 個「輸出與動作混在一起」的函式**這一輪不動**。
收尾時用實際成本判斷要不要往外擴。

---

## 6. 不做

- 開機自動恢復（launchd）
- 斷線自動重試
- 把埠暴露到 Gateway 或網路上（這是客戶端本機的轉發）
- 設定檔

---

## 7. 已知風險

- **`0.0.0.0` 是真的對整個 LAN 開放。** `ls` 會標示，但那是提醒不是防護。
- **`inconclusive` 那一態會很常見而且沒有資訊量。** 如果經常看到它，要修的是
  節點到目標的路由或防火牆，不是這個工具。
- **`fwd_records` 依賴 `ps` 的輸出格式。** 這是外部契約，測試要用假的 `ps`
  蓋掉，不能依賴真實進程。
- **上色時欄寬必須扣掉跳脫序列。** `printf` 把 ANSI escape 當可見字元計寬，
  先上色再墊空白會在 TTY 下跑版、管線下正常。這個 bug 就是這樣漏掉的：
  驗證只走了管線（無色、對齊），使用者走 TTY（有色、跑版）。修法是先墊空白
  再包顏色，驗證必須用 `script -q /dev/null` 包起來在真 TTY 下看。

---

## 8. 任務拆分

### impl

1. `ssh_via_gateway` 加 `SSH_EXTRA_OPTS`（加法、預設空）
2. 從 `do_connect` 抽出 `target_resolve`，`do_connect` 改呼叫它，行為不變
3. Model：`fwd_records`、`fwd_probe`
4. ViewModel：`fwd_add`、`fwd_remove`、`fwd_status`
5. View：`cmd_fwd`，接進 `main` 的子指令分派與 `usage`

分層規則是硬要求：Model/ViewModel 裡出現 `printf`／`echo`／`fzf` 就是沒做到。

### test

單元測試，假造 `ssh` 與 `ps`（沿用 `test-client-identity.sh:48-55` 的 stub 法）。
必須包含這些**注入**案例，每一條都要先證明「沒修正時會紅」：

| 注入 | 應該轉紅的斷言 |
|---|---|
| 健康檢測換成 `ssh -O check` | 隧道死掉時仍回報 up |
| 目標 `refused` 當成不健康 | 沒服務被誤報成壞掉 |
| spec 解析把 `8080:host:80` 當成 `8080` | 第三方主機轉發失靜默退回節點自己 |
| Model 裡加一個 `printf` | 分層檢查 |
| `ssh_via_gateway` 不帶 `SSH_EXTRA_OPTS` | `-L` 沒有被送出去 |

### qa

1. **獨立確認** Actions 沒有經過 `ssh_via_gateway`（不要引用 impl 的話）
2. 現有 `mlp` 指令沒有回歸：`ls`／`ssh`／`ssh-config`／`state` 至少各跑一次
3. 分層邊界真的成立：Model/ViewModel 內不得有輸出
4. 全套測試與 `preflight` 全綠
