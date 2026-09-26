# Provider 宿主機稽核（auditd）：覆蓋範圍與盲區

為什麼有這份文件：裝 auditd 的理由是「部分覆蓋比沒有覆蓋危險——它讓人以為查得到」。
2026-09-26 的實況**正是部分覆蓋**，而三台的設定都是手動裝的。這個盲區不能靠人記得，
所以寫在這裡。讀這份文件時先接受它的結論：**查 fh-proxy 上發生過什麼，auditd 幫不上忙。**

## 1. 覆蓋表（2026-09-26）

| 節點 | 稽核 | auditd 版本 | 設定落地 |
|---|---|---|---|
| fh-proxy-asus | 有 | 1:4.1.2（Ubuntu 26.04） | 手動安裝；規則與 conf 在 2026-09-25 18:03 調成現在的形狀 |
| fh-l | 有 | 1:3.1.2（Ubuntu 24.04） | 2026-09-26 按 §2 照 asus 下發 |
| fh-proxy（WSL2） | **沒有** | 套件 1:3.1.2 已裝，子系統拒絕 | `auditctl -s` 回 `Error sending status request (Operation not permitted)`（§5） |

證據：asus／fh-l 的 `auditctl -l` 均為 §2 的兩條規則、`auditctl -s` 為 `enabled 1`；
fh-proxy 的 EPERM 原文見 §5。fh-l 驗到 log 在增長（`/var/log/audit/audit.log`）。

## 2. 設定原文（asus 版為準，fh-l 同文下發）

`/etc/audit/rules.d/10-mlp-exec.rules`：

```text
# spec: 稽核 worker 上的指令執行。b32 與 b64 都要——只守 b64 的話
# 32 位元執行檔會整個繞過稽核，而那種缺口不會有徵兆。
-a always,exit -F arch=b64 -S execve -k mlp_exec
-a always,exit -F arch=b32 -S execve -k mlp_exec
```

`auditd.conf` 的關鍵設定如下。只有前兩個與 3.1.2 套件預設不同，其餘是預設值，
列出來是因為磁碟上限與滿載行為取決於它們（3.1.2 預設與 asus 版只差三處：
`max_log_file` 8→**200**、`num_logs` 5→**20**、多一行 `report_interval = 0`；
其餘含 `log_format = ENRICHED`、`end_of_event_timeout` 兩版一致，3.1.2 全吃得下）：

```text
max_log_file = 200
num_logs = 20
max_log_file_action = ROTATE
space_left = 75
space_left_action = SYSLOG
admin_space_left = 50
admin_space_left_action = SUSPEND
disk_full_action = SUSPEND
disk_error_action = SUSPEND
```

`rules.d/audit.rules`（套件預設）不動。3.1.2 機器的原 conf 備份在
`/etc/audit/auditd.conf.pkg-default`。

磁碟上限算法：20 個輪替檔 × 200 MB ＋現行檔最多 200 MB ≈ **4.2 GB 天花板**，
之後原地打轉。剩餘 75 MB 只發 syslog 警告；剩餘 50 MB 或磁碟全滿／寫入錯誤時
**SUSPEND（暫停寫入）**——機器不停，代價是暫停期間的 execve 沒記下來。
asus 實測：116 GB 盤剩 97 GB，上限僅佔約 4%。

## 3. 會記到什麼

宿主機上**所有** execve：key=`mlp_exec`，不過濾使用者——
**你在宿主機上打的每個指令都會被記下來**（這是已知的，不是副作用）。
worker 容器裡的 execve 也會落進來（共用宿主機核心，記錄帶容器的
AppArmor profile 如 `subj=docker-default`），而且**容器裡的人關不掉**
（開關在宿主機核心側）。

## 4. 怎麼驗證它真的在記（2026-09-26 在 fh-l 跑過的步驟，可照做）

sudo 一律用 `sudo -S -p "" … < ~/passwd`（密碼只在遠端餵，不進命令列）。

防假綠是重點：`grep` 和宿主機上的 `docker exec` 自己也會被記下來，
參數裡若直接帶著要找的字串，沒記到也搜得到。所以字串分兩半，
只在**容器裡的 shell**拼起來；搜尋時先用 shell 內建 `printf` 把完整字串寫進檔案，
再 `grep -F -f 檔案`（`grep` 的參數裡沒有字串）。

1. 在 worker 容器裡執行 `/bin/echo <隨機字串>`（字串在容器內拼好，
   宿主機側只出現 `${Y}xxxx` 這種半截）。
2. 宿主機 `ausearch -k mlp_exec --start recent -i`，用檔案比對找該字串，
   應看到 `type=EXECVE … argc=2 a0=/bin/echo a1=<隨機字串>`，
   對應 SYSCALL 帶容器 profile（如 `subj=docker-default`）。
3. 負對照：一個從沒執行過的隨機字串 → 0 筆（證明工具有鑑別力，不是逢搜必中）。

2026-09-26 在 fh-l 的容器 `mlp-fh-l-default-36197689685` 上按此法驗過：命中且負對照為 0。

## 5. fh-proxy（WSL2）的現況與重試方式

現況：套件與 §2 同文設定都在位置上，原 conf 備份也在，但服務已
`systemctl disable --now auditd`（故意的，不要手癢 enable——enable 了也起不來，
見下）。未 purge，就是為了可以回復。

裝不起來的證據（2026-09-26，逐字）：

```text
$ sudo auditctl -s
Error sending status request (Operation not permitted)
$ sudo auditctl -l
Error sending rule list data request (Operation not permitted)
$ sudo systemctl enable --now auditd
Job for auditd.service failed because the control process exited with error code.
```

`auditctl` 直連核心 netlink，不經 daemon——EPERM 即 WSL2 核心拒絕，
起 daemon 救不了。核心編譯選項倒是有（`CONFIG_AUDIT=y`），但
sysctl 無 `kernel.audit*` 節點、dmesg 無 audit 行。WSL 側放行 audit 之後
（那是 Windows 側 `.wslconfig`／核心參數的事，超出本池 ssh 範圍），
重試即 `systemctl enable --now auditd` 再驗 `auditctl -s` 回到 `enabled 1`、
`auditctl -l` 為 §2 的兩條。

## 6. 新增 provider 時：把 auditd 裝進上線流程

不然盲區只會變多，而 §1 的表格不會自己更新。新增一台 provider 時，
按 §2 下發設定、按 §4 驗一遍，然後**把 §1 的表格加上一行**
（有／沒有、版本、日期、證據）。哪天 fh-proxy 能用了，同一張表改狀態——
不要另起文字說「現在全覆蓋了」，表格是唯一的真相來源。
