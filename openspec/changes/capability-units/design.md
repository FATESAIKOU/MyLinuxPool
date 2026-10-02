## Context

調查報告：`team/OUT-recon-capability.md`（程式碼）、`team/OUT-impl-recon-myaientry-caps.md`（MyAiEntry）、`team/OUT-test-recon-capability-tests.md`（測試）。審查報告：`team/OUT-review-capability-proposal.md`。重點：

- 已經有的：形狀契約（`key: object`，空能力寫 `{}`，`null` 永遠不合法）、兩個驗證器（`worker-host`、`github`）、遷移器。三台的 live var 也已經是新形狀（`docs/CAPABILITY-DESIGN.md`）。
- 能力鍵寫死在五處：`mlp` 兩處、`register-provider.sh` 兩處、`scripts/lib/profile.sh` 一處。驗證的分派點是 `mlp` 的 `cap_verify_node` 和 `register-provider.sh` 的 `step7_5_capabilities`，兩個都是寫死的 `case`。
- `unit.json` 的 `provides` 寫的是**指令名稱**，沒有任何程式讀它。
- pool-sync 的收斂迴圈會跳過需要金鑰或 root 的單位，`--check` 沒過就重裝，重裝失敗就 `exit 1`（`pool-sync:148-196`）。pool-sync 已經會用 provider 自己的 `gh_token` 寫 `NODE_*`（`tunnel_key_ensure_published`）。
- `pool-runtime` 的 `--check` 是逐位元組比對檔案（`cmp -s`），沒有任何清理邏輯。`pool-wol` 是它的比對項之一，裝在每台 provider，也裝在 Gateway。
- `register-provider.sh:528` 在 `capabilities` 缺值時補 `worker-host`，之後永遠不覆寫。
- `POOL_WORKERS` 的三筆都沒有 `capabilities`。
- MyAiEntry：未知的能力鍵原樣保留；能力名稱直接顯示在承載機說明裡（`poolSnapshot.ts:243-244`）；挑 `github` 機器時不看在不在線（`team/OUT-impl-recon-selecthost-online.md`）。
- CI 只跑 `scripts/tests/`，`shared-configs/*/tests/` 沒被 CI 跑過（issue #13）。
- 實測（2026-10-02，唯讀）：fh-proxy 與 fh-proxy-asus 上，systemd user manager 的 groups 已經含 docker 的 gid，所以 pool-sync 跑 `docker info` 看得到 docker 群組。

## Goals / Non-Goals

**Goals：**
- 新增一個能力，只要新增一個單位，再在 profile 列出它
- provider 的宣告跟驗證結果一致；暫時驗不到時不抖動
- worker 的宣告就是它的 profile

**Non-Goals：**
- 拿掉 `power.launch.via`
- 回頭補寫現有 worker 的 `capabilities`
- `github` 的 `write`、`trigger-actions` 權限
- 改 `mlp migrate-capabilities`：它是一次性的遷移工具，pool-sync 接手宣告之後就不需要再跑，維持原樣

## Decisions

**D1. 新欄位 `capability`，不重用 `provides`。**
`unit.json` 加上 `"capability": "<鍵>"`，`provides` 不變。preflight 要擋三件事：
- 兩個單位實作同一個鍵
- profile 的 `capabilities` 裡有沒有單位實作的鍵
- 值不是 object

**D2. `--check` 分三態，參數從 `MLP_CAPABILITY_PARAMS` 傳入。**
有 `capability` 的單位，`install.sh --check` 從 `MLP_CAPABILITY_PARAMS` 讀 JSON 參數，回傳值的意思是：
- `0`：能力成立
- `1`：確定不成立
- `2`：這次無法確認，例如網路逾時、群組變更還沒在這個 session 生效

沒有 `capability` 的單位，`--check` 的語意不變（檔案是否最新）。

**D3. 共用 runner：`scripts/lib/capability.sh`。**
- `capability_plan <profile.json>`：列出 profile 裡的每個能力，以及它的單位和參數。profile `capabilities` 的值**就是**參數本身，單位每次都從 `shared-configs/*/unit.json` 現場查，不建快取。
- `capability_check <鍵> <參數>`：跑單位的 `--check`，回傳 0、1 或 2。
- `capability_declaration <profile.json> <現有宣告>`：組出新的宣告。
  - 0 的能力：放進宣告，值是 profile 的參數。
  - 1 的能力：不放。
  - 2 的能力：保留現有宣告裡的值；現有宣告裡沒有的話就不加。

pool-sync、register-provider、`mlp verify-capabilities` 只呼叫這三個函式。create-worker 不碰 runner，因為 worker 的能力不驗證，跑 runner 就會執行 `--check`；它用 `profile_capabilities` 原樣讀 profile。目前 `capability_plan` 還沒有任何生產端在用，只有測試會呼叫它；留著是給之後要列出「鍵→單位→參數」的消費端用的。`mlp` 是從使用者電腦對遠端機器驗證，所以要在那台機器上跑**同一份**單位的 `--check`。具體怎麼送過去由 impl 決定，只有一條要求：不能另外寫一份驗證邏輯。

**D4. pool-sync 的宣告是一條獨立的路徑，永遠不安裝。**
收斂迴圈完全不動。收斂結束後另外跑一段：
1. 對 profile 的每個能力呼叫 `capability_check`，不管單位要不要金鑰或 root、有沒有列在 `shared_config` 裡。
2. 用 `capability_declaration` 組出宣告。
3. 把它跟 `NODE_<NAME>.capabilities` 用 `jq -S` 正規化之後比對，不同才 merge 這一個欄位（照 `tunnel-key.sh` 的寫法）。

宣告這一段發生任何失敗都只記 WARN，不讓 tick 失敗，也不影響收斂、authorized_keys、隧道金鑰。結果是 1 的能力記 WARN，是 2 的能力記 INFO。

**D5. 單位與 `--check` 的判準。**

| 單位 | 能力 | 誰安裝 | 參數 | `--check` |
|---|---|---|---|---|
| `worker-host`（新） | `worker-host` | register-provider | `{"runtime":"docker"}` | 以宣告的使用者身分跑 `docker info`，成功回 0。失敗的話：如果 `/etc/group` 的 docker 群組有這個使用者，但目前這個 process 的群組沒有 docker 的 gid，回 2；其他情況回 1。`runtime` 不是 `docker` 回 1 |
| `gh` | `github` | register-provider | `{"repos":{"FATESAIKOU/MyBrain":["read"]}}` | **改寫**：`github` 的意思是「這台機器用 pool 的憑證（`~/.mylinuxpool/gh_token`）讀得到這些 repo」。沒有 token 回 1。對每個 repo 打一次 API：拒絕存取（404、無權的 403）回 1；rate limit、網路錯誤、5xx 回 2。多個 repo 時 1 優先，不會被後面的 2 蓋掉 |
| `wol`（新） | `wol` | pool-sync | `{"methods":["unicast"]}` | `~/.mylinuxpool/bin/pool-wol` 存在、可執行、跟單位的 `files/pool-wol` 逐位元組相同（代表裝的是這一版，跟收斂迴圈的語意一致），而且這一版支援參數列的每個 method，否則回 1。**不送封包**，因為 `pool-wol` 回 0 只代表封包送出去了 |

provider 的 `default` 與 `no-sudo` 兩個 profile 都列這三個能力。Gateway 不是 provider，它的 profile 不列 `capabilities`，`shared_config` 也不列 `wol` 單位。

**D6. `mlp wake`：`via` 決定順序，`wol` 決定資格。**
照 `via` 的順序走，沒宣告 `wol` 的那台直接略過，並印出原因，例如「via 裡有它，但它沒有宣告 wol」。略過的那台**照樣佔一個 `(n/m)` 的序號**。四態與時間預算都不動。如果 `via` 裡沒有任何一台宣告 `wol`，就明確報錯，不能靜靜結束。另外，`mlp verify-capabilities` 遇到 `via` 指向沒宣告 `wol` 的機器時，平常就要報出來。

**D7. `pool-wol` 移出 `pool-runtime`，同一個 PR 做完。**
- 用 `git mv` 移到 `shared-configs/wol/files/pool-wol`，內容一個位元組都不改。
- 同時從 `pool-runtime/install.sh` 的 `BINARIES` 和 `cp`／`chmod` 清單拿掉它。
- provider 的 `default` 與 `no-sudo` 兩個 profile 的 `shared_config` 加上 `wol`，讓 pool-sync 的收斂迴圈接手安裝，`mlp wake` 才不會有空窗。Gateway 的 profile 不加。Gateway 上已經裝好的 `pool-wol` 會留著不動，因為沒有清理邏輯，而且也沒有人會從 Gateway 送 wol。

舊版 pool-runtime 的 `--check` 是 `cmp -s`。只要兩份檔案不一樣，舊版就會把新單位裝的檔案蓋回去，而且每 30 分鐘一次。所以測試要斷言兩份檔案逐位元組相同。

**D8. register-provider 照 runner 的結果寫宣告。**
拿掉 `:528` 那個「缺值才補 `worker-host`」的預設。註冊時對每個能力跑 `capability_check`：
- 任何一個不是 0，註冊就失敗，並指出是哪個能力，以及它是不成立還是無法確認。
- 全部是 0，就把 `capability_declaration` 的結果寫進 `NODE_<NAME>.capabilities`。

這樣 register-provider 和 pool-sync 寫的是同一個函式算出來的值，不會互相打架。

register-provider 是先 `usermod -aG docker` 再驗證，而它當下這個 session 的群組還是舊的，所以 `capability_check` 要包在 `sudo -n -u <user>` 裡，在一個群組已經重新解析過的 process 裡跑，跟今天的 `docker info` 一樣（`register-provider.sh:774`）。不這樣做的話，`worker-host` 會回 2，每一台新註冊的機器都會失敗。

**D10. 安裝時用換檔取代原地覆寫。**
`pool-runtime` 和 `wol` 的 `install.sh` 改成：先複製到同一個目錄下的暫存檔，`chmod` 完再 `mv` 過去，不再用 `cp -f` 直接覆寫目標檔。

原因：bash 是邊執行邊讀腳本的。pool-sync 收斂到新版時，`cp -f` 會改寫**正在執行**的那個檔案（同一個 inode），還在跑的舊版 process 就會讀到新內容，然後出錯（2026-10-02 fh-l 碰過：`line 410: syntax error`，那一輪失敗）。`mv` 換的是目錄項，舊版 process 手上的還是原來那個檔案，所以不受影響（使用者 2026-10-02 裁定併進 PR-B）。

**D9. 程式註解要少。** 理由寫在這份文件和 commit 裡。

## Risks / Trade-offs

- **[宣告抖動]**：驗證暫時失敗時（例如 GitHub API 5xx），宣告的值不能跟著變。→ 用三態處理，「無法確認」就保留原值（使用者 2026-10-02 裁定）。代價是宣告停在舊值的時間可能比較久，這跟 fh-l 關機時宣告停在舊值是同一種取捨。
- **[宣告一變，app 跟著變]**：能力真的壞掉時（例如 docker 停了），`worker-host` 會從宣告消失，app 的承載機選單就會少一台。這是設計上要的結果，但要先讓 MyAiEntry 知道。
- **[fh-l 關機時，宣告停在上一次開機的值]**：使用者接受。app 挑機器時沒有看在不在線，而 fh-l 照字典序排第一。不過今天的 fallback 就是 fh-l，所以最後拿到的機器跟今天一樣，差別只在錯誤訊息。修法與落地順序已寫在 MyAiEntry#4。
- **[剛註冊完，群組是舊的]**：
  - pool-sync（user manager 比 usermod 早啟動）：`worker-host` 回 2，宣告維持 register-provider 寫的值。實測：兩台現有 provider 的 user manager 已經有 docker 群組。
  - register-provider：照 D8，在 `sudo -n -u` 的新 process 裡驗證。
- **[`pool-wol` 改版會重啟 tunnel]**：pool-sync 的 `changed` 是全域旗標，任何單位重裝都會重啟 pool-tunnel。`wol` 單位獨立出來之後，`pool-wol` 一改版，所有 provider 的下一個 tick 都會重啟一次 tunnel，進行中的 `mlp ssh`／`fwd` 會斷一次，之後自己恢復。這是既有的行為，這次不改。
- **[pool-sync 多了一個寫入者]**：只 merge `capabilities` 這一個欄位。register-provider 和 pool-sync 用同一個函式算值（D8），兩邊同時寫的機率很低，就算同時寫，寫的也是同一個值。
- **[`wol` 會直接顯示在 app 和 AI 看得到的文字裡]**（`承載機，提供能力：worker-host、github、wol。`）：要不要給它一個顯示名稱，由 app 那邊決定。已在 MyAiEntry#4 提醒。

## Migration Plan

分三個 PR，每個都能單獨上線、單獨回退（使用者 2026-10-02 裁定）。

- **PR-A：單位與 runner**
  - 內容：D1、D2、D3、D5 的三個單位與 `gh --check` 改寫、D7、preflight。
  - 沒有任何 profile 列 `capabilities`，所以沒有任何宣告會變。
  - 唯一的線上行為變化：provider 上的 `pool-wol` 改由 `wol` 單位安裝，檔案內容一樣。
- **PR-B：自動宣告**
  - 內容：provider profile 加 `capabilities`、D4、D8、`mlp verify-capabilities` 改用 runner、create-worker 改用 runner。
  - merge 之後的第一個 tick 就會改到三台的 live var。
  - 回退方式：revert，或停掉 pool-sync timer。宣告會停在最後一次寫入的值。
  - merge 後真機驗收：三台收斂成 `worker-host`＋`github`＋`wol`；停掉一台的 docker 再恢復，宣告會跟著消失、出現。
- **PR-C：wake 與文件**
  - 內容：D6，改寫 `docs/CAPABILITY-DESIGN.md`，清掉 `docs/ARCHITECTURE.md:138-145` 的 `wol_sender` 和舊的陣列形狀。
  - merge 後：刪掉 `NODE_FH_PROXY.wol_sender`（執行前再跟使用者確認），`mlp wake fh-l` 照常能用，archive 這個 change。
