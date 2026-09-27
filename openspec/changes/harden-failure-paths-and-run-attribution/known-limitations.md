# 已知限制總表（本輪加固）

> 2026-09-27 03:35 整理，09:45 補上 D2b。這裡列的都是**刻意不修**或**沒驗到**的項目，每條都寫了它會怎麼表現、為什麼接受。
> 「使用者裁示」＝本人決定不做；「範圍凍結」＝本輪只修真 bug，這條屬於 enhance 或低嚴重度。

## 失敗路徑

| 項目 | 發生時的表現 | 為什麼接受 |
|---|---|---|
| delete-worker 釋放埠**之後**失敗（刪帳本、refresh、推 state cache） | job 紅，說明步驟印出手動收拾步驟；**重跑不能全癒**（會死在尋找 worker） | 使用者裁示只修釋放埠那一個；歷史 0 次 |
| delete-worker 失敗說明本身從沒在真實失敗上跑過 | — | S6 歷史 0 次失敗；靠靜態覆蓋測試＋順序斷言保證它會跑 |
| 手動收拾配方的 `${GH_REPO}` | 操作者 shell 沒 export 時，`set -u` 下報 unbound，沒開 `-u` 會變 `repos//…` | RUNBOOK 的流程有 export；配方未端到端跑過 |
| 失敗說明的測試分不出關鍵字是哪一步印的 | 刻意造一個含關鍵字的假步驟可以騙過 | 需要刻意構造；已記在測試檔頭 |
| rotate 回滾時自己寫變數失敗 | 大聲失敗，要手動修 | 使用者裁示不修；歷史 0 次 |
| 失敗補救（重推 state cache、重刷 key）的真機驗證 | 只在模型與 CI 驗過 | 使用者裁示不做（A3） |

## 歸屬（dispatch 後認自己的 run）

| 項目 | 表現 | 為什麼接受 |
|---|---|---|
| refresh 等待只看最近 50 筆 run | 外部 burst 超過 50 筆 → 認不出，回非 0（安全，但那次操作會報失敗） | 外部約 10 分鐘一次，300 秒窗約 30 筆，有餘量；分頁沒做 |
| 無 `/dev/urandom` 的平台 | nonce 退回低熵格式 | 本機與 runner 都有 urandom |
| 「認不出」那一側的線上行為 | 真機只驗了認得出的一側 | 離線測試覆蓋；要刻意破壞才能在真機造出來 |
| `test-key-transport`、`test-register-client` 對歸屬退化不敏感 | 它們綠不代表歸屬有守；歸屬的護欄是 `test-refresh-attribution.sh` | 它們本來就不是歸屬測試 |
| 不帶 nonce 的 run 標題尾端多一個空格 | `refresh-authorized-keys ` | 純外觀 |
| `mlp worker new`／`rm` 的完整流程沒在真機跑過 | 它只能在真終端機用 fzf 挑選（刻意設計、被測試釘住），驗證時 create／delete 改用 `gh workflow run` 直接 dispatch | `wf_dispatch` 三支共用，rotate 已經由 `mlp` 在真機驗過 |
| `mlp` 的退路（stdout 沒有 run URL 時比對 nonce 標題）沒在真機觸發過 | 本機與 runner 的 gh 都是 2.101，一直走主路徑 | 離線測試覆蓋（`test-wf-dispatch-own-run.sh`、`test-wf-dispatch-attribution.sh`） |
| nonce 長度下限（≥12）只有注入的 needle 守著，沒有行為測試 | 有人改寫護欄時測試會紅，但紅的訊息是 harness 問題而不是行為判準 | 護欄本身正確；範圍凍結，未補 12d |
| rc 1 同時代表「dispatch 被拒」與「run 失敗」 | 兩者的輸出可以分辨（前者明說 refused、零次 dispatch），操作者的下一步相同 | — |
| repo 裡有兩套歸屬機制 | refresh 用 nonce，`mlp` 以 run id 為主、nonce 為退路 | 刻意的，理由寫在 `mlp` 檔頭 |

## CI 與測試

| 項目 | 表現 | 為什麼接受 |
|---|---|---|
| CI 失敗時只印每支測試最後 30 行 | 失效的斷言若在更前面就看不到（這次注入 27 就是） | 範圍凍結；R3（失敗上傳 log）使用者裁示不做 |
| 整個 job 撞 15 分鐘上限時結論是 cancelled 還是 failure | 本機驗不了 | — |
| amd64 QEMU 下 python3 偶發 segfault（注入 11 報 harness 問題） | 只在 Apple Silicon 上的模擬環境見過，runner 未見 | 疑模擬環境假象，未深挖 |
| `pool-status` 走寫死埠段時 WARN 不標來源；`mlp state` 讀不到 POOL_WORKERS 與「零 worker」輸出相同 | — | C5 驗收時列為已知限制 |
| `per_page` 翻頁、`wf_follow` 無上限迴圈 | — | 使用者裁示不修（C4） |

## 稽核（auditd）

| 項目 | 表現 | 為什麼接受 |
|---|---|---|
| fh-proxy（WSL2）沒有稽核 | 核心拒絕 audit netlink（`Operation not permitted`） | 裝不起來；套件與設定留著，WSL 放行後可重試（`docs/AUDIT.md`） |
| `docs/AUDIT.md` 的覆蓋表靠人維護 | 新增 provider 沒改表，文件就過期 | 沒有自動檢查 |

## 叢集觀察（非缺陷）

- `mlp state` 的 `local` 那一方在這台 Mac 上是空的，所以「三方一致」實際只比了兩方
