#!/usr/bin/env bash
# test-repair-host-vm.sh — VM 端的家人維修承載機（issue #6 tasks 5.1；design
# D5 後半／D7／D8，spec「維修承載機不持有 GitHub 權杖」「失敗時家人看得懂該
# 做什麼」）。
#
# 在防什麼（真線會咬人的那一種）：
#   task 4 已經有「Mac 端登錄指令產出開機資料」的紅測試
#   （test-register-repair-host.sh）。開機資料裡「task 5 加東西」的那個洞
#   （profiles/provider/repair/user-data.tmpl 檔頭寫的「---- task 5 adds its
#   pieces here ----」）目前完全是空的：VM 上沒有東西會擋 GitHub 權杖
#   （D5 後半）、沒有東西會去問 Gateway IP（D2）、也沒有東西會把重試節奏放慢
#   到 fail2ban 的觀察窗以下（D7）。這支測試就是在定義那個洞裡要放什麼，並
#   且證明「現在完全沒有」。
#
# ==============================================================================
# 這支測試定義的介面（impl 落地時照這個；要改介面就同步改本檔）
# ==============================================================================
#
# 安裝位置（VM 上，全部屬於開機資料的 @@LOGIN_USER@@，即 profile.json 的
# login_user="repair"；與既有慣例對齊：pool-tunnel 自己認的狀態目錄就是
# ${HOME}/.mylinuxpool，install.sh 把既有工具裝進 ${HOME}/.mylinuxpool/bin/，
# 這裡沿用同一個目錄，不另開一個 /opt）：
#
#   /home/@@LOGIN_USER@@/.mylinuxpool/bin/pool-tunnel           既有檔案，task 5 原樣複製過去
#   /home/@@LOGIN_USER@@/.mylinuxpool/bin/tunnel-identity.sh    既有檔案，task 5 原樣複製過去
#   /home/@@LOGIN_USER@@/.mylinuxpool/bin/repair-token-guard    NEW — D5 後半
#   /home/@@LOGIN_USER@@/.mylinuxpool/bin/repair-gateway-fetch  NEW — D2 取值半
#   /home/@@LOGIN_USER@@/.mylinuxpool/bin/repair-gateway-report NEW — D2 回報半
#   /home/@@LOGIN_USER@@/.mylinuxpool/bin/repair-tunnel-launch  NEW — D5 守門 + D7 重試節奏
#
# sudo（2026-09-29 使用者決定，tasks 8b.4）：`repair` 帳號要免密碼 sudo。
# 做法：user-data.tmpl 的 write_files 加一個 /etc/sudoers.d/ 底下的檔案
# （路徑名由 impl 決定；本測試只認前綴 /etc/sudoers.d/），內容是一條
# NOPASSWD 規則，principal **只給登入使用者**（@@LOGIN_USER@@，渲染後是
# profile.json 的 login_user="repair"）——不是 ALL、不是群組、不是別的帳號。
# 背景（OUT-live-repair.md 意外 6）：live 驗收時 repair 沒有 root，
# sudo 要密碼而密碼是鎖住的，維修時改網路設定／抓封包都做不到。
# 這一節驗的就是模板（對現碼紅：模板還沒有任何 sudo 設定）。
#
# systemd（**system unit 加 User=**，不是 repo 給一般 provider 用的 user unit
# 加 linger——這是 spike 定案的做法，OUT-spike-repair.md §2「unit 是 system
# unit 加 User=repair，比 user unit 加 linger 在 cloud-init 裡簡單」）：
#
#   /etc/systemd/system/mlp-d2-fetch.service
#       Type=oneshot; User=@@LOGIN_USER@@
#       ExecStart=.../repair-gateway-fetch
#       Before=mlp-tunnel-repair.service（隧道啟動前先試著把 Gateway IP 拿到）
#   /etc/systemd/system/mlp-tunnel-repair.service
#       User=@@LOGIN_USER@@
#       EnvironmentFile=/etc/mlp/tunnel.env         （現有的靜態模式輸入，含
#                                                      placeholder；D3/D4 已交）
#       EnvironmentFile=-/run/mlp/gateway.env        （D2 取到值時覆蓋——同一
#                                                      個變數名在後面的檔案贏，
#                                                      這是 systemd 的既有語意，
#                                                      不需要額外程式碼）
#       ExecStart=.../repair-tunnel-launch
#       After=mlp-d2-fetch.service
#
#   runcmd 在既有的 `systemctl daemon-reload && systemctl restart ssh.socket`
#   之後，再加一行 enable 這兩個 system unit。
#
# ---- repair-token-guard（D5 後半：VM 上出現權杖就拒絕啟動隧道）------------
#   呼叫：repair-token-guard（無參數）
#   檢查：
#     * 檔案 ${HOME}/.mylinuxpool/gh_token 存在（不管內容）
#     * 環境變數 GH_TOKEN / GH_POOL_TOKEN / GITHUB_TOKEN 任一非空
#   命中任一項 → exit 非 0，stderr 印一行說明原因（**必須**提到 "token"
#   這個詞；檔案命中時額外提到檔名，環境變數命中時額外提到變數名——因為 spec
#   要求「記錄原因」，本測試只驗訊息的字面內容，不驗訊息格式）。
#   都沒中 → exit 0，不需要輸出任何東西。
#
# ---- repair-gateway-fetch（D2 取值半）--------------------------------------
#   呼叫：repair-gateway-fetch（無參數）
#   環境：MLP_D2_HOST（預設 10.0.2.2，NAT 下主機的位址——spike D2(c)）、
#         MLP_D2_PORT（預設 18080，spike 用的埠）、
#         MLP_D2_TIMEOUT（預設 3，秒）、
#         MLP_GATEWAY_ENV_FILE（預設 /run/mlp/gateway.env——D3/D4 已交的
#         /etc/mlp/tunnel.env 之外「疊加」的那個檔）
#   行為：GET http://${MLP_D2_HOST}:${MLP_D2_PORT}/gw
#     * 成功且回應非空 → 原子寫入（temp + mv，仿 pool-tunnel 自己的
#       publish_gateway）一行 `POOL_GATEWAY_HOST=<ip>` 到 MLP_GATEWAY_ENV_FILE，
#       exit 0
#     * 失敗（連不上／逾時／空回應）→ **不動** MLP_GATEWAY_ENV_FILE（不寫、
#       不清空既有內容），stderr 說明原因，exit 1。**這不是 fatal**：
#       mlp-d2-fetch.service 只用 Before=，不是 Requires=，隧道 unit 照樣會
#       啟動，讀到的是 /etc/mlp/tunnel.env 裡的 placeholder
#       （gateway-ip-set-at-launch.invalid，D4 已交），對那個位址撥號會在
#       DNS 這一步就明確失敗——這就是 design 對齊的「明確失敗」，不是猜一個
#       能連的預設值。
#
# ---- repair-gateway-report（D2 回報半）-------------------------------------
#   呼叫：repair-gateway-report <up|down>
#   環境：同 MLP_D2_HOST/MLP_D2_PORT/MLP_D2_TIMEOUT
#   行為：POST http://${MLP_D2_HOST}:${MLP_D2_PORT}/state，body `tunnel=<arg>`。
#   任何網路結果（沒有啟動器、逾時、HTTP 錯誤）都 exit 0（純粹是給啟動器顯示
#   狀態用的診斷通道，失敗不能拖累隧道）；唯一的例外是呼叫方自己傳錯參數
#   （不是 up/down）——那是呼叫方的 bug，不是網路狀況，exit 2。
#
# ---- repair-tunnel-launch（D5 守門 + D7 重試節奏；unit 的 ExecStart）-----
#   呼叫：repair-tunnel-launch（無參數；讀環境裡的 POOL_NODE_NAME /
#         POOL_GATEWAY_HOST / POOL_GATEWAY_USER / POOL_GATEWAY_PORT /
#         POOL_GATEWAY_SSH_PORT，跟 pool-tunnel 靜態模式一樣）
#   行為：
#     1. 先呼叫同目錄的 repair-token-guard；guard 拒絕 → **完全不呼叫
#        pool-tunnel**，exit 非 0（D5：權杖存在時隧道不啟動）
#     2. guard 放行 → 迴圈呼叫 `pool-tunnel --once`（同目錄或 PATH 上那份）：
#        * 成功（rc 0）→ 呼叫 repair-gateway-report up，接手 pool-tunnel 自己
#          的 control_alive/health_check 持續監看（不 exit 0）；連線掉了才
#          report down、回到上面的迴圈再撥一次。**不會**在成功當下就退出讓
#          systemd 的 Restart 接手——若 ExecStart 在成功後 exit 0，
#          `Type=simple` 的 unit 會被視為完成而停止，KillMode=control-group
#          會把留在同一個 cgroup 裡的 ssh master 一併殺掉，隧道等於「一連上
#          就被收掉」。只有收到 SIGTERM/SIGINT（unit 被停止）才會 exit 0。
#        * 失敗，且輸出像是 Gateway 拒絕了這把金鑰（ssh 真正被拒時印的標準
#          訊息 `Permission denied`——這是 sshd／fail2ban 場景下 ssh 會印的
#          字面，不是本測試發明的格式）→ 這是 D7 講的「連續被拒」：重試間隔
#          必須拉長到「任何 10 分鐘的滑動視窗內嘗試次數 < 5」（fail2ban 預設
#          10 分鐘內 5 次失敗封 10 分鐘）。**確切的退避數字/演算法由實作決定
#          並寫進 repair-tunnel-launch 自己的註解**（design D7 原文）——本測試
#          只驗這個「視窗內 < 5 次」的結果，不綁實作用了哪個數列
#        * 失敗，且輸出不像是被拒（例如網路不通）→ 不在本測試範圍（design 沒
#          有要求非認證失敗也要放慢，那樣反而拖慢真正的網路恢復）
#
# ---- 本輪新增（工單 test-ephemeral-vm；PM 定案，EPHEMERAL-INTERFACE.md #3/#4/
#      #6 為準；review 擔任 test 角色）--------------------------------------
#
# 這輪把「臨時跳板」的三件事接進 VM 端：D2 通道多帶一個名字（介面 #4）、
# port 改成一個段而不是單一值（介面 #2/#6）、Gateway 上的名牌（介面 #5）。
# 下面每一條都是**這支測試定義的新介面**，現碼幾乎全部還沒有——這是預期的紅。
#
# ---- repair-gateway-fetch：兩行 /gw（介面 #4，取代舊的「只有一行 IP」）-----
#   body 改成兩行：第一行 IPv4，第二行 `name=<名字>`（名字格式跟啟動器同一份
#   pattern，介面 #3：`^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$`）。
#   兩行都合法、沒有多餘的第三行 → 原子寫入 MLP_GATEWAY_ENV_FILE **兩行**：
#     POOL_GATEWAY_HOST=<ip>
#     REPAIR_NAME=<name>
#   任一不合法（IP 格式錯、第二行不是 `name=`、名字格式錯、缺第二行、多一行
#   垃圾）→ **完全不寫**（既有檔案內容原封不動，跟現在「空回應不寫」的規則
#   是同一種 fail-closed），stderr 說明原因，exit 1。
#
# ---- 名字唯一來源：gateway.env 的 REPAIR_NAME（PM 裁定，no env 後門）------
#   repair-tunnel-launch 要幫 VM 設 hostname 時，**只**能從
#   ${MLP_GATEWAY_ENV_FILE} 的 REPAIR_NAME 讀名字。POOL_NODE_NAME（tunnel.env
#   既有變數，pool-tunnel 自己拿去當它内部的 NAME/記錄用）**不是**名字的來源
#   ——即使它被設成一個合法名字，也絕不能被拿去設 hostname。這是一個先前
#   worker 卡住的爭點，PM 已裁定：唯一可信來源是 D2 → repair-gateway-fetch →
#   gateway.env 這條路徑，其餘一律不採信。
#
#   設 hostname 的動作：`${MLP_REPAIR_HOSTNAME_BIN:-hostnamectl} set-hostname
#   <name>`（測試覆寫用 MLP_REPAIR_HOSTNAME_BIN，同 MLP_REPAIR_POOL_TUNNEL_BIN
#   的慣例）。同一個名字不必重複呼叫（用一個記憶中的「上次設過的名字」擋，不
#   落地成檔案——重開機/重啟服務會重設一次，冪等，無害）。名字格式再驗一次
#   （防禦性；正常情況下 fetch 已經驗過）。
#
# ---- 沒有合法答案 → 不撥號（PM 裁定，取代舊的「§3c2：沒答案就撥打
#      placeholder」）------------------------------------------------------
#   舊斷言：D2 沒有答案時，repair-tunnel-launch 讓 pool-tunnel 撥打開機資料裡
#   的 .invalid placeholder，靠 DNS 在撥號當下失敗，屬於「明確失敗」。
#   **這條被取代**：現在的規則是——每一輪，refresh_gateway_host 之後，
#   gateway.env 裡若**沒有同時**拿到合法的 POOL_GATEWAY_HOST（IPv4）與合法的
#   REPAIR_NAME，這一輪**完全不呼叫 pool-tunnel**（一次 ssh 撥號都不打），呼叫
#   repair-gateway-report down，然後用 D7 的「快退」節奏（10/20/40/60…，
#   NOT_COUNTED 那條，因為根本沒碰到 sshd）重試。
#   為什麼換：(a) 撥 placeholder 靠的是 ssh 對 DNS 失敗訊息剛好落在
#   NOT_COUNTED_RE 裡，是巧合式的耦合，不是設計；(b) 已知會失敗還是要真的
#   起一個 ssh 子行程，白花一次系統呼叫；(c) 兩種「down」的理由（根本沒有
#   Gateway 資訊 vs 真的網路失敗）現在混成同一句話，家人看不出差別。改成
#   「不知道就不撥」讓這個狀態顯式化，也不再依賴 ssh 的錯誤字面。
#   placeholder 字串可以留在模板/tunnel.env 裡（給沒有這層邏輯的舊版看），但
#   repair-tunnel-launch **絕不能**把它交給 pool-tunnel/ssh。
#
# ---- Port 段（介面 #2/#6）--------------------------------------------------
#   開機資料帶一個段（新 placeholder `@@PROVIDER_PORT_RANGE@@`，渲染成
#   `POOL_GATEWAY_PORT_RANGE=<min>,<max>`，取代舊的單一值
#   `@@PROVIDER_PORT@@`/`POOL_GATEWAY_PORT=`）。repair-tunnel-launch：
#     * 開機讀不到這個段（不存在、格式不對、min>=max）→ 大聲拒絕（同
#       repair-token-guard 的 fail-closed 慣例），不寫死 fallback，report down，
#       exit 非 0。
#     * 每次「重新開始找 Gateway」（也就是這一輪拿到合法的 host+name 之後開始
#       撥號）都從段首（min）開始試。
#     * 失敗分類擴成三種（見下）：`remote port forwarding failed`
#       （NOT_COUNTED 的一種）→ 換下一個 port（到段尾繞回段首），快退；
#       `Permission denied` 等（COUNTED）→ **絕不換 port**，照舊 310 秒／
#       10 分鐘 <5 次的節奏（D7，不能退化）；其他 NOT_COUNTED（DNS、
#       connection refused 等）→ 不算次數也**不換 port**（網路不通不代表這個
#       port 被佔），原 port 快退重試。
#     * 挑 port 的狀態是執行期的區域變數，不寫回任何檔案（OUT-recon-ephemeral
#       §4.2 第 4 點）。
#
# ---- Gateway 上的名牌（介面 #5）--------------------------------------------
#   接上（撥號成功）之後，用同一條 ControlMaster（`ssh -S "$CTL" ...`，跟
#   pool-tunnel 自己的 health_check 同一種呼叫方式，不建新連線）在 Gateway 上
#   把 `/home/sshproxy/repair/<實際連上的 port>` 覆寫成只有名字一行。
#   重新接上（不管是不是換了 port）：先刪舊 port 的名牌，新連上後才寫新的。
#   正常停止（收到 SIGTERM/INT，on_stop 路徑）：刪掉目前這個 port 的名牌，
#   再收隧道。
#
# ---- 可測試性慣例（本測試對 repair-tunnel-launch 提出的要求，不是
#      EPHEMERAL-INTERFACE.md 的一部分，是這支測試能不 hang 地驗證內部函式
#      所需要的最小結構；impl 可以不同意，但要在報告裡講）-------------------
#   repair-tunnel-launch 把主迴圈包進一個「只有直接執行時才跑」的守衛，跟
#   pool-tunnel 自己 `main "$@"` 前面的 BASH_SOURCE 守衛同一種寫法。這樣測試
#   可以 `source` 這支腳本去單獨呼叫下面幾個函式，不會被無窮迴圈卡住：
#     * classify_dial_failure <ssh-stderr-text>   → 印 counted／forward／other
#     * next_port <cur> <min> <max>               → 印下一個 port（到 max 繞回 min）
#     * has_valid_gateway                          → 讀 $GATEWAY_ENV_FILE，兩個值都
#                                                     合法才 return 0
#     * apply_repair_name <name>                   → 呼叫 hostnamectl（見上）
#     * nametag_write <port> <name>                → 見上
#     * nametag_remove <port>                      → 見上
#   這些函式名字是本測試的建議介面，不是鐵律；impl 若用別的名字，只要功能
#   對得上、且腳本本身仍然「被 source 不會跑主迴圈」，測試改函式名即可
#   （介面在檔頭寫清楚，改動要同步改本檔——TEAM-RULES 的慣例）。
#
# ---- 可測試性覆寫（只給這支測試用，不是給正式部署用）----------------------
#   MLP_REPAIR_VM_DIR — 覆寫上面四支新腳本所在的目錄（預設
#   profiles/provider/repair）。impl 開發中想先在別的地方驗證這支測試會不會
#   轉綠，不用真的把檔案放進 profiles/provider/repair/，可以：
#     MLP_REPAIR_VM_DIR=/path/to/wip bash scripts/tests/test-repair-host-vm.sh
#
# ==============================================================================
# 要驗的（1-5 對應 task 5 舊工單；6-9 對應本輪 test-ephemeral-vm 工單 1-5）
# ==============================================================================
#   1. user-data 的性質：沒有 packages:；sshd 只聽 loopback、
#      PasswordAuthentication no；runcmd 重啟 ssh.socket；屬於新使用者的檔案
#      有 defer: true；隧道 unit 是 system unit 加 User=；不含 GitHub 權杖字面；
#      不啟用 pool-sync／pool-resolve；新增的四支腳本路徑真的被模板引用到
#      （1a-1d/1f 對現碼綠——這些是 task 4 已經交的性質；1e/1g 對現碼紅——
#      task 5 還沒加）
#   2. 權杖守衛：token 檔或 GH_*/GH_POOL_TOKEN 環境 → 守衛非 0、隧道不啟動、
#      記錄原因；沒有 → 放行（對現碼紅：repair-token-guard 不存在）
#   3. D2 取值／回報：假服務回 IP → 隧道撥號用那個 IP；服務不在 → 不覆寫，
#      隧道撥號用開機資料裡的 placeholder（明確失敗，DNS 解不出來）；隧道起來
#      後 POST 狀態（對現碼紅：repair-gateway-fetch/report 不存在）
#   4. D7 重試節奏：模擬連續被拒（假 ssh 每次都回 `Permission denied`）→
#      用模擬時間（絕不真的 sleep）跑出至少 10 分鐘份的重試，驗證任何 600 秒
#      滑動視窗內的嘗試次數 < 5（對現碼紅：repair-tunnel-launch 不存在）
#   5. 回歸：非維修模式的 pool-tunnel 直接跑（不經過上面任何新東西）時，它
#      自己的退避數列（2,4,8,16,30,30,...）完全不變（對現碼綠——這是既有
#      pool-tunnel 的行為，task 5 不該去動它，D7 只加在維修模式專用的
#      repair-tunnel-launch 裡）
#   6. /gw 兩行解析＋「沒有合法答案就不撥號」：兩行都合法 → 寫兩個值；任一
#      不合法（含只有 IP 沒有名字、名字格式錯、IP 格式錯、多一行垃圾）→
#      gateway.env 不變；repair-tunnel-launch 這一輪完全不呼叫 ssh、report
#      down、走快退（取代舊 §3c2；對現碼紅：fetch 還是單行解析，launch 沒有
#      這層守門）
#   7. hostname：名字只能來自 gateway.env 的 REPAIR_NAME；只有 POOL_NODE_NAME
#      （沒有 REPAIR_NAME）**不能**觸發設 hostname（對現碼紅：整個機制不存在）
#   8. Port 段：讀不到段就拒絕啟動；從段首開始；`remote port forwarding
#      failed` 換下一個 port（繞回段首）；`Permission denied` 絕不換 port、
#      D7 節奏不變（對現碼紅：機制不存在）
#   9. Gateway 名牌：接上寫、換 port 先刪舊再寫新、正常停止刪除（對現碼紅：
#      機制不存在）
#
# ---- 正對照（量到 0 不算證據）-----------------------------------------------
#   * §3/§4/§5：假 ssh／假 curl 真的被呼叫過（log 非空）才信後面的斷言
#   * §2：guard 拒絕的兩種案例分別用「檔案存在」與「環境變數非空」單獨驗證，
#     並且在呼叫 guard 之前，測試自己先用 [[ -f ]] 確認 fixture 真的落在
#     guard 文件宣稱的路徑上（不是測試自己放錯地方、guard 其實從沒看見它）
#   * §4c：視窗計數器（count_max_window）先拿一組已知會違規的序列（pool-tunnel
#     自己原生的快速退避數列，套進同一個計數器）自我驗證，確認它真的抓得到
#     違規，不是一個永遠回答「沒問題」的空殼
#   * §6：先確認 curl／ssh 假指令真的被呼叫過（沿用既有 log），再看 ssh 的
#     撥號行（-M -S）次數是 0
#   * §7/§8/§9：source 之後先用 `declare -F` 確認函式真的存在（不是測到一個
#     從未定義、永遠不執行的名字），再呼叫並看假 hostnamectl／假 ssh 的 log
#
# ---- 注入（有真的原始碼可以動刀的地方才做；沒有的地方用 inj_skip 說明）----
#   * §1：對 user-data.tmpl 的複本動刀（拿掉 defer: true、把 ListenAddress
#     改成 0.0.0.0、加一行 pool-sync 啟用）→ 對應的 1c/1b/1f 必須在複本上翻紅
#   * §5：對 pool-tunnel 的複本動刀（把 next_backoff 的封頂拿掉，改成一路
#     倍增）→ 5b 的數列比對必須在複本上翻紅
#   * §1e/1g、§2-4：subject 還不存在，沒有原始碼可以動刀——現碼本身的紅就是
#     這些檢查「有在量」的證據，注入欄位記 inj_skip 並說明理由（跟
#     test-register-repair-host.sh 對 §7 的處理方式一致）
#   * §6-9：subject（新行為）現碼不存在，同上以 inj_skip 記；丟棄式綠版
#     （scratchpad 複本）另外做注入，記在 OUT-test-ephemeral-vm.md 而不是本檔
#     （本檔跑的是對現碼的紅／未來對落地版本的綠，不夾帶丟棄式實作）
#
# ==============================================================================
# 這支測試看不到什麼（誠實記在這裡）
# ==============================================================================
#   * 不驗 systemd 的 EnvironmentFile 疊加語意本身（那是 systemd 的既有行為，
#     不是這輪要測的程式）：§3b 用「shell 依序 source 兩個檔案，後面的贏」
#     模擬同樣的疊加順序，不是真的起一個 systemd unit。
#   * 不驗「被拒」的判斷方式一定要是字串比對 `Permission denied`——那是
#     design 留給實作自己決定並寫註解的事。本測試的假 ssh 印的是 ssh 真的
#     被 Gateway 拒絕時會印的標準訊息，只是提供一個「像真的」的輸入；只要
#     repair-tunnel-launch 對這個輸入的最終行為滿足「10 分鐘視窗 < 5 次」，
#     用什麼判斷方式本測試不管。
#   * D7 只驗「連續被拒」這一種失敗模式的節奏；網路不通、DNS 失敗等其他失敗
#     模式的重試節奏不在本輪範圍（design 沒有要求）。
#   * §4 的「10 分鐘」是模擬時間（用假 sleep 推進一個虛擬時鐘），不是真的
#     驗證 repair-tunnel-launch 在真實掛鐘時間下的行為；一個讀虛擬時鐘以外
#     來源計時的實作（例如真的呼叫 date +%s）會被這裡的假時鐘騙過去，但那
#     樣的實作在真機上仍然是用真掛鐘算，行為應該一致——這是模擬測試的通性
#     限制，不是這支測試獨有的洞。
#   * 不連網、不開 VM、不驗 cloud-init 對 user-data.tmpl 的真正解析（那是
#     spike 與真機驗收的事，OUT-spike-repair.md 已經做過一次）。
#   * §1 的「不啟用 pool-sync／pool-resolve」只驗模板裡沒有相關字串；如果
#     task 5 用別的名字包裝同一件事（例如自己重寫一個會打 GitHub 的腳本卻
#     取名 foo），這個字串比對看不到。
#   * repair-gateway-fetch「服務不在時不覆寫檔案」只驗到「這次呼叫不寫」，
#     不驗併發呼叫、半寫入等 race（跟這個 repo 其他測試的一貫限制一致）。
#   * token 掃描（guard）只認檔案存在與否、環境變數是否非空；不掃「權杖被
#     編碼或藏在其他檔案」——這跟 register-repair-host 自己那半的已知限制
#     （t4 報告 §5）是同一種洞，寫在這裡是因為 VM 這半也一樣。
#   * sudo 那一節（1h/1h2）只驗模板裡「有沒有一條 principal 為
#     @@LOGIN_USER@@ 的 NOPASSWD 規則」；不驗 visudo 的語法（那是部署時
#     cloud-init／sudo 自己的事）、不驗檔案的權限位（0440 等）與 owner、
#     也不驗規則的指令範圍（ALL=(ALL) vs 收窄的 Cmnd 清單）——使用者的
#     決定原文是「給免密碼 sudo」，範圍留給 impl。
#   * §6：只驗「沒有合法答案的那一輪不撥號」，不驗「拿到合法答案之後馬上
#     開始撥號的延遲」（也就是不驗這個轉換發生得多快）。
#   * §7 的 hostname：只驗「呼叫了 hostnamectl 這個外部指令且參數對」，不驗
#     真正的 Linux hostname 有沒有被改（那要真機或至少真的
#     hostnamectl／systemd-hostnamed，不在這支離線測試範圍——跟 spike／真機
#     驗收的既有分工一致）。也不驗「開機時就已經有名字」與「開機後才拿到
#     名字」兩種時序哪個先——interface 沒有要求開機當下就要有 hostname。
#   * §8 的 port 段：只驗「換 port」與「不換 port」兩種分類的邏輯本身
#     （classify_dial_failure／next_port 這兩個純函式），**不**用真的多輪
#     ssh 撥號迴圈去驗「主迴圈真的把這兩個函式接起來用」——那需要一個會
#     依序回傳不同失敗訊息、成功後還能維持 ControlMaster 存活的假 ssh，
#     這支測試沒有做（見下方「本測試看不到」的第一條）。impl 落地後，若
#     只是把這兩個函式定義好卻沒有在主迴圈實際呼叫，本測試量不到。
#   * §9 的名牌：只驗 nametag_write／nametag_remove 這兩個函式被單獨呼叫時
#     組出的 ssh 遠端指令對不對（路徑、內容、用同一個 -S 控制端），**不**驗
#     主迴圈在「接上」「換 port 重接」「收到 SIGTERM」這三個時間點真的有呼叫
#     它們——同一個原因（沒有可以模擬「連上又斷開」的假 ssh 全流程）。
#   * repair-gateway-fetch 兩行解析：只驗「名字格式」與「兩行都要有」，不驗
#     name 大小寫以外的邊界（例如恰好 32 字元、恰好 1 字元）——那組邊界已經
#     在 OUT-review-ephemeral-launcher.md §1.1 對啟動器那一端測過 17/17，這裡
#     假設 VM 端用同一個 pattern 字面，不重複整組邊界，只驗「壞了會不會被
#     擋」的代表案例。
#   * 新增的 6-9 節全部是**單元測試層級**（source 之後呼叫個別函式，或跑一輪
#     不含成功連線的主迴圈），沒有一個是「真的起一個會成功、又斷線、又用不同
#     port 重連」的端到端模擬——這需要一個遠比現有 fake ssh 複雜的狀態機
#     （維持 ControlMaster 存活、回應 -O check、依序執行遠端指令），這支測試
#     沒有做，留給真機驗收（tasks 8）或後續加強。
#
# 全離線：ssh/curl/sleep 走 PATH shim；不連網、不開 VM；bash 3.2 相容。
# Run: scripts/tests/test-repair-host-vm.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

PTUNNEL="shared-configs/pool-runtime/files/pool-tunnel"
TIDENT="shared-configs/pool-runtime/files/tunnel-identity.sh"
# MLP_REPAIR_TEMPLATE：同 MLP_REPAIR_VM_DIR 的自我驗證用途——指向一份「假裝
# task 5 已經落地」的模板複本，不用真的改 profiles/provider/repair/。
TEMPLATE="${MLP_REPAIR_TEMPLATE:-profiles/provider/repair/user-data.tmpl}"
VM_DIR="${MLP_REPAIR_VM_DIR:-profiles/provider/repair}"
GUARD="${VM_DIR}/repair-token-guard"
FETCH="${VM_DIR}/repair-gateway-fetch"
REPORT="${VM_DIR}/repair-gateway-report"
LAUNCH="${VM_DIR}/repair-tunnel-launch"

for tool in python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: ${tool} not found on PATH" >&2; exit 1; }
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-repair-vm.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
SHIMS="$SANDBOX/shims"
HOME_DIR="$SANDBOX/home"
mkdir -p "$SHIMS" "$HOME_DIR/.ssh" "$HOME_DIR/.mylinuxpool"
printf 'DUMMY\n' > "$HOME_DIR/.ssh/id_tunnel"
chmod 600 "$HOME_DIR/.ssh/id_tunnel"
cp "$REPO_ROOT/$TIDENT" "$SANDBOX/tunnel-identity.sh"

pass=0; fail=0; injpass=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }
inj_skip() { printf '  --    (注入略) %s\n' "$1"; }

# ---- 假 ssh：記 argv；依 SSH_STDERR_MODE 決定 stderr 內容 -------------------
# 撥號（-M -S ...）一律失敗；同時若 MLP_TEST_CLOCK 存在，把撥號當下的虛擬時鐘
# 值記到 MLP_TEST_DIAL_TIMES（§4/§5 用來算滑動視窗）。
cat > "$SHIMS/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SSH_LOG:-/dev/null}"
case "$*" in
    *"-M -S"*)
        if [[ -n "${MLP_TEST_DIAL_TIMES:-}" ]]; then
            cur=0
            [[ -f "${MLP_TEST_CLOCK:-}" ]] && cur="$(cat "$MLP_TEST_CLOCK" 2>/dev/null || echo 0)"
            printf '%s\n' "$cur" >> "$MLP_TEST_DIAL_TIMES"
        fi
        printf '%s\n' "${MLP_TEST_SSH_STDERR:-fake ssh: connection refused}" >&2
        exit 255
        ;;
    *"-O check"*) exit 255 ;;
    *"-O exit"*)  exit 0 ;;
esac
printf '%s\n' "${MLP_TEST_SSH_STDERR:-fake ssh: connection refused}" >&2
exit 255
FAKE

# ---- 假 sleep：從不真的睡；把秒數記到 log，推進一個虛擬時鐘檔案。時鐘超過
# MLP_TEST_CLOCK_CAP 時，送 TERM 給呼叫端（模擬「已經跑了 N 分鐘」，不必真的
# 等），呼叫端（pool-tunnel／repair-tunnel-launch）都會 trap TERM 乾淨結束。
cat > "$SHIMS/sleep" <<'FAKE'
#!/usr/bin/env bash
dur="${1:-0}"; dur="${dur%%.*}"; [[ -z "$dur" ]] && dur=0
printf '%s\n' "$dur" >> "${MLP_TEST_SLEEP_LOG:-/dev/null}"
if [[ -n "${MLP_TEST_CLOCK:-}" ]]; then
    cur=0
    [[ -f "$MLP_TEST_CLOCK" ]] && cur="$(cat "$MLP_TEST_CLOCK" 2>/dev/null || echo 0)"
    new=$((cur + dur))
    printf '%s\n' "$new" > "$MLP_TEST_CLOCK"
    cap="${MLP_TEST_CLOCK_CAP:-0}"
    if [[ "$cap" -gt 0 && "$new" -ge "$cap" ]]; then
        kill -TERM "$PPID" 2>/dev/null || true
    fi
fi
exit 0
FAKE

# ---- 假 curl：記 argv；依 URL 是 /gw 還是 /state 分流，依 FAKE_D2_MODE 決定
# /gw 的行為：
#   ip       — 兩行 body（介面 #4）：第一行 FAKE_D2_IP，第二行
#              name=FAKE_D2_NAME；FAKE_D2_EXTRA_LINE 非空時再加第三行垃圾
#              （§6 的「多一行」案例）。
#   ip_only  — 只回第一行（舊協定的形狀；§6 的「缺第二行」案例）。
#   raw      — 原封不動印 FAKE_D2_RAW_BODY（給任意畸形內容用）。
#   down（或其他）— 模擬服務不在，exit 7。
# /state 一律 exit 0（report 是盡力而為）。
cat > "$SHIMS/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG:-/dev/null}"
if [[ ! -t 0 ]]; then cat > "${CURL_STDIN:-/dev/null}" 2>/dev/null; fi
case "$*" in
    *"/gw"*)
        case "${FAKE_D2_MODE:-ip}" in
            ip)
                body="${FAKE_D2_IP:-198.51.100.7}"$'\r\n'"name=${FAKE_D2_NAME:-mom-pc}"
                [[ -n "${FAKE_D2_EXTRA_LINE:-}" ]] && body="${body}"$'\r\n'"${FAKE_D2_EXTRA_LINE}"
                printf '%s' "$body"
                exit 0
                ;;
            ip_only)
                printf '%s' "${FAKE_D2_IP:-198.51.100.7}"
                exit 0
                ;;
            raw)
                printf '%s' "${FAKE_D2_RAW_BODY:-}"
                exit 0
                ;;
            *)
                echo "curl: (7) Failed to connect to ${MLP_D2_HOST:-10.0.2.2} port ${MLP_D2_PORT:-18080}" >&2
                exit 7
                ;;
        esac
        ;;
    *"/state"*) exit 0 ;;
    *) exit 22 ;;
esac
FAKE
chmod +x "$SHIMS/ssh" "$SHIMS/sleep" "$SHIMS/curl"

# ---- 假 hostnamectl：記 argv（§7 用；不是真的改本機 hostname）------------
cat > "$SHIMS/hostnamectl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HOSTNAMECTL_LOG:-/dev/null}"
exit 0
FAKE
chmod +x "$SHIMS/hostnamectl"

# ---- 假 sudo：記 argv（§10 用；真機發現 repair 帳號跑 hostnamectl 會
# 「Interactive authentication required」，修法是 sudo -n）。FAKE_SUDO_MODE=
# fail 時模擬非互動模式下密碼要求失敗（exit 1，不往下 exec，證明「sudo 失敗
# 不能擋撥號」）；預設（ok 或未設）剝掉 -n 之後真的 exec 剩下的指令，讓底下
# 的假 hostnamectl 也留下記錄，證明整條鏈路真的接起來，不只是 sudo 被叫到。
cat > "$SHIMS/sudo" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SUDO_LOG:-/dev/null}"
if [[ "${FAKE_SUDO_MODE:-ok}" == "fail" ]]; then
    echo "sudo: a password is required" >&2
    exit 1
fi
[[ "$1" == "-n" ]] && shift
exec "$@"
FAKE
chmod +x "$SHIMS/sudo"

# count_max_window <timestamps-file> <window-seconds>
#   印出「任何一個長度 window-seconds 的視窗內，最多落了幾個時間戳」。
#   [t, t+window] 兩端都算在內（跟 fail2ban 的「10 分鐘內」同一種算法：寧可
#   算寬一點，不要因為端點沒算到而放過一個實際上會被封鎖的節奏）。
count_max_window() {
    local file="$1" window="$2"
    if [[ ! -s "$file" ]]; then echo 0; return; fi
    python3 - "$file" "$window" <<'PY'
import sys
times = sorted(int(l) for l in open(sys.argv[1]) if l.strip())
window = int(sys.argv[2])
best = 0
for t0 in times:
    c = sum(1 for t in times if t0 <= t <= t0 + window)
    best = max(best, c)
print(best)
PY
}

# ---- user-data.tmpl 的性質：每個 prop_* 對「一個模板檔案路徑」回真/假 ------
prop_no_packages()          { ! grep -qE '^packages:' "$1" 2>/dev/null; }
prop_sshd_loopback()        { grep -q 'ListenAddress 127.0.0.1' "$1" 2>/dev/null \
                               && grep -q 'ListenAddress ::1' "$1" 2>/dev/null \
                               && grep -q 'PasswordAuthentication no' "$1" 2>/dev/null; }
prop_runcmd_restart_socket() { grep -q 'restart ssh.socket' "$1" 2>/dev/null; }
# 「有任何一個 defer: true」不夠：一份模板可以在隧道私鑰那塊拿掉 defer、卻在
# 別的檔案留一個合法的 defer，這樣量整份檔案「有沒有 defer」還是會綠（review
# OUT-review-repair-t5.md §2 抓到的洞——這曾經是「defer 只能有一個」的形狀
# 巧合在撐綠，不是真的在量私鑰有沒有 defer）。改成只認「隧道私鑰那一塊」：
# 以 `path:` 那行含 id_tunnel（渲染後的真實路徑，tunnel-identity.sh 的單一
# 定義）或 TUNNEL_KEY_PATH（本檔測的是未渲染模板，那一行字面是
# @@TUNNEL_KEY_PATH@@ 這個 placeholder）為錨，區塊往下延伸到下一個
# `- path:` 或 write_files 區段結束（下一個沒有縮排的頂層 key，例如
# runcmd:）為止；defer: true 必須落在這個區塊裡面才算數。這樣「私鑰掉
# defer、別的檔案留 defer」不再誤判成綠，「模板多一個合法 deferred 檔案」
# 也不再誤判 1x 的注入失效。
prop_key_defer_true() {
    awk '
        BEGIN { inkey = 0; keyseen = 0; deferred = 0 }
        /^[[:space:]]*-[[:space:]]*path:/ {
            inkey = ($0 ~ /id_tunnel|TUNNEL_KEY_PATH/) ? 1 : 0
            if (inkey) keyseen = 1
            next
        }
        /^[^[:space:]]/ { inkey = 0 }
        inkey && /^[[:space:]]*defer:[[:space:]]*true[[:space:]]*$/ { deferred = 1 }
        END { exit (keyseen && deferred) ? 0 : 1 }
    ' "$1" 2>/dev/null
}
prop_no_sync_resolve()      { ! grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -qE 'pool-sync|pool-resolve'; }
prop_no_token_literal()     { ! grep -Eq '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})' "$1" 2>/dev/null; }
prop_tunnel_unit_system_user() {
    grep -q '/etc/systemd/system/mlp-tunnel-repair.service' "$1" 2>/dev/null \
    && grep -q 'User=@@LOGIN_USER@@' "$1" 2>/dev/null
}
# ---- 本輪新增（工單 test-live-vm-fixes；真機 ACPI 關機時名牌沒被刪掉）-----
# 真機驗收發現：正常關機時 Gateway 上的名牌沒被刪掉，因為隧道 unit 的
# stop 還沒跑，網路就先斷了。systemd 的停止順序是啟動順序的反向：一個
# unit 若 After=network-online.target（比網路晚起），關機時就會比網路早停
# （網路留到最後才收）。修法方向：mlp-tunnel-repair.service 自己的
# [Unit] 區塊要同時有 `Wants=network-online.target` 與
# `After=network-online.target`（不能只有其中一個，也不能只掛在
# mlp-d2-fetch.service 那個 unit 上——那個 unit 是 oneshot，起完就結束，
# 它的 Wants/After 對隧道 unit 的停止順序沒有幫助）。用同一種「先找
# path: 那行、往下掃到下一個 path: 或頂層 key 為止」的區塊定位法，只認
# **隧道 unit** 自己那個區塊裡的兩行，不被 mlp-d2-fetch.service 那邊本來
# 就有的同名字串誤判成綠。
prop_tunnel_unit_network_ordering() {
    awk '
        BEGIN { inunit = 0; seen = 0; wants = 0; after = 0 }
        /^[[:space:]]*-[[:space:]]*path:[[:space:]]*\/etc\/systemd\/system\/mlp-tunnel-repair\.service[[:space:]]*$/ {
            inunit = 1; seen = 1; next
        }
        /^[[:space:]]*-[[:space:]]*path:/ && $0 !~ /mlp-tunnel-repair\.service/ { inunit = 0 }
        /^[^[:space:]]/ { inunit = 0 }
        inunit && /^[[:space:]]*Wants=/ && /network-online\.target/ { wants = 1 }
        inunit && /^[[:space:]]*After=/ && /network-online\.target/ { after = 1 }
        END { exit (seen && wants && after) ? 0 : 1 }
    ' "$1" 2>/dev/null
}
prop_new_scripts_referenced() {
    grep -q '.mylinuxpool/bin/repair-token-guard' "$1" 2>/dev/null \
    && grep -q '.mylinuxpool/bin/repair-gateway-fetch' "$1" 2>/dev/null \
    && grep -q '.mylinuxpool/bin/repair-gateway-report' "$1" 2>/dev/null \
    && grep -q '.mylinuxpool/bin/repair-tunnel-launch' "$1" 2>/dev/null
}
# ---- 本輪新增（工單 test-live-vm-fixes 追加：KillMode=mixed）--------------
# 真機再次驗收找到名牌洩漏的真正根因：systemd 預設 KillMode=control-group
# 會把 ssh master 跟 launch script 一起 SIGTERM，on_stop 的 trap 觸發時
# master 已經死了，nametag_remove 沒有 ControlMaster 可以多工，退路連線又
# 跟正在斷的網路搶時間，名牌就這樣漏刪（真機量到：ACPI 關機後名牌還在，
# auth.log 沒有新的 sshproxy session）。修法已經在工作樹裡：
# mlp-tunnel-repair.service 自己的 [Service] 區塊要有 `KillMode=mixed`
# （只送 SIGTERM 給主行程，ssh master 留到 on_stop 自己收）。review 說「拿掉
# 這行不會讓任何測試變紅」——這條就是補那個洞。用跟 1k 同一種「先找
# path: 那行、往下掃到下一個 path: 或頂層 key 為止」的區塊定位法，只認
# **隧道 unit** 自己那個區塊裡的這一行，不被別的 unit（如果將來哪個 unit
# 也剛好寫了 KillMode=mixed）誤判成綠；也不接受同區塊出現別的 KillMode 值
# （例如 KillMode=process 或 none）當作合格——`Wants=`/`After=` 用「有沒有
# 提到」就夠，但 KillMode 是個單值旗標，值不對等於沒修。
prop_tunnel_unit_killmode_mixed() {
    awk '
        BEGIN { inunit = 0; seen = 0; km = "" }
        /^[[:space:]]*-[[:space:]]*path:[[:space:]]*\/etc\/systemd\/system\/mlp-tunnel-repair\.service[[:space:]]*$/ {
            inunit = 1; seen = 1; next
        }
        /^[[:space:]]*-[[:space:]]*path:/ && $0 !~ /mlp-tunnel-repair\.service/ { inunit = 0 }
        /^[^[:space:]]/ { inunit = 0 }
        inunit && /^[[:space:]]*KillMode[[:space:]]*=/ {
            line = $0
            sub(/^[[:space:]]*KillMode[[:space:]]*=[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            km = line
        }
        END { exit (seen && km == "mixed") ? 0 : 1 }
    ' "$1" 2>/dev/null
}

# ---- sudo 的性質（2026-09-29 決定，tasks 8b.4） -----------------------------
# 只認 write_files 裡一個 path 以 /etc/sudoers.d/ 開頭的檔案，並且它的
# content 區塊（縮排比 path 那行深、到下一個 - path: 或頂層 key 為止）含一條
# NOPASSWD 規則、principal 是 @@LOGIN_USER@@（渲染後 repair）。
# 不看具體檔名（impl 決定），不看註解裡的說明——只認實際寫進去的 content。
# 為什麼要「只給該帳號」：sudoers 的 principal 若寫成 ALL，等於任何本機
# 使用者（或未來任何被建立的帳號）都有免密碼 root；NOPASSWD 的 blast radius
# 必須跟「這一個登入使用者」對齐（AI 也會用這個帳號，這是使用者的知情決定）。
prop_sudoers_nopasswd() {
    awk '
        BEGIN { insudo = 0; seen = 0; nopass = 0 }
        /^[[:space:]]*-[[:space:]]*path:[[:space:]]*\/etc\/sudoers\.d\// {
            insudo = 1; seen = 1
            # path 行本身也算這個區塊的一部分
        }
        /^[[:space:]]*-[[:space:]]*path:/ && $0 !~ /\/etc\/sudoers\.d\// { insudo = 0 }
        /^[^[:space:]]/ { insudo = 0 }
        insudo && /NOPASSWD/ { nopass = 1 }
        END { exit (seen && nopass) ? 0 : 1 }
    ' "$1" 2>/dev/null
}
# principal 只給登入使用者：sudoers 區塊裡的規則行（含 NOPASSWD 的那些），
# 行首第一個欄位（principal）必須是 @@LOGIN_USER@@，且不得出現 principal 為
# 裸 ALL 的 NOPASSWD 規則。`@@LOGIN_USER@@ ALL=(ALL) NOPASSWD: ALL` 合法
# （principal 就是那一個使用者）；`ALL ALL=(ALL) NOPASSWD: ALL` 是要擋的
# 形狀（任何本機帳號都能免密碼 root，例如未來多開一個低權限帳號）。
prop_sudoers_login_user_only() {
    awk '
        BEGIN { insudo = 0; seen = 0; userline = 0; bad_all = 0 }
        /^[[:space:]]*-[[:space:]]*path:[[:space:]]*\/etc\/sudoers\.d\// { insudo = 1; seen = 1 }
        /^[[:space:]]*-[[:space:]]*path:/ && $0 !~ /\/etc\/sudoers\.d\// { insudo = 0 }
        /^[^[:space:]]/ { insudo = 0 }
        insudo && /NOPASSWD/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]].*$/, "", line)
            if (line == "@@LOGIN_USER@@") userline = 1
            if (line == "ALL") bad_all = 1
        }
        END { exit (seen && userline && !bad_all) ? 0 : 1 }
    ' "$1" 2>/dev/null
}

# ---- 本輪新增：模板不再帶每台不同的名字／單一 port（工單第 6 點） ----------
# 名字現在完全來自 D2（見檔頭），模板不該再有 @@NODE_NAME@@ 這個逐台渲染的
# token（POOL_NODE_NAME 這個變數名字可以留著給 pool-tunnel 自己的 NAME/記錄
# 用，但它的值不能再是每台不同、由 register/package 決定的東西——這裡只驗
# token 沒了，不驗 tunnel.env 還留不留 POOL_NODE_NAME 這一行本身）。
prop_no_packaged_name()   { ! grep -q '@@NODE_NAME@@' "$1" 2>/dev/null; }
# 單一 port 的 @@PROVIDER_PORT@@ 換成段的 @@PROVIDER_PORT_RANGE@@（介面
# #2/#6）。用「精確吃掉右邊的 @@」的寫法，讓 @@PROVIDER_PORT_RANGE@@ 不會
# 誤判成含有 @@PROVIDER_PORT@@（後者要求 PORT 後面立刻是 @@，前者是
# _RANGE@@，兩者不會互相誤判）。
prop_no_single_port()     { ! grep -q '@@PROVIDER_PORT@@' "$1" 2>/dev/null; }
prop_has_port_range()     { grep -q '@@PROVIDER_PORT_RANGE@@' "$1" 2>/dev/null \
                             && grep -q 'POOL_GATEWAY_PORT_RANGE=' "$1" 2>/dev/null; }

echo "=== 0. 先決條件 ==="
if [[ -f "$REPO_ROOT/$PTUNNEL" ]]; then
    ok "0a. ${PTUNNEL} 存在（§5 回歸的對象）"
else
    bad "0a. ${PTUNNEL} 不存在——§5 無法驗證"
fi
TMPL_PATH="$REPO_ROOT/$TEMPLATE"; [[ -f "$TMPL_PATH" ]] || TMPL_PATH="$TEMPLATE"
if [[ -f "$TMPL_PATH" ]]; then
    ok "0b. ${TEMPLATE} 存在（§1 的對象）"
else
    bad "0b. ${TEMPLATE} 不存在——§1 無法驗證"
fi
for f in "$GUARD" "$FETCH" "$REPORT" "$LAUNCH"; do
    if [[ ! -f "$REPO_ROOT/$f" && ! -f "$f" ]]; then
        echo "test-repair-host-vm: ${f} does not exist yet — this test defines its behaviour (interface in the file header); the RED lines below are expected" >&2
    fi
done

echo
echo "=== 1. user-data 的性質 ==="
if [[ -f "$TMPL_PATH" ]]; then
    prop_no_packages "$TMPL_PATH"          && ok "1a. 沒有 packages:"          || bad "1a. 出現 packages: —— 家人的網路可能連不上 apt 鏡像"
    prop_sshd_loopback "$TMPL_PATH"        && ok "1b. sshd 只聽 loopback，PasswordAuthentication no" || bad "1b. sshd 設定不符（只聽 loopback／禁密碼登入）"
    prop_runcmd_restart_socket "$TMPL_PATH" && ok "1c. runcmd 有重啟 ssh.socket（spike pitfall 1）" || bad "1c. runcmd 沒有重啟 ssh.socket"
    prop_key_defer_true "$TMPL_PATH"       && ok "1d. 隧道私鑰那一塊有 defer: true（spike pitfall 2）" || bad "1d. 隧道私鑰那一塊沒有 defer: true"
    prop_no_sync_resolve "$TMPL_PATH"      && ok "1f. 模板沒有提到 pool-sync／pool-resolve（不該在維修承載機上跑）" || bad "1f. 模板提到 pool-sync／pool-resolve"
    prop_no_token_literal "$TMPL_PATH"     && ok "1g0. 模板本身沒有權杖字面（generator 半在 register-repair-host 已驗，這裡只是模板不該內建任何字面）" || bad "1g0. 模板含疑似 GitHub 權杖字面"
    prop_tunnel_unit_system_user "$TMPL_PATH" && ok "1e. 隧道 unit 是 system unit（/etc/systemd/system/mlp-tunnel-repair.service）且帶 User=@@LOGIN_USER@@" \
        || bad "1e. 模板還沒有 system unit + User=——task 5 尚未落地（預期紅）"
    prop_new_scripts_referenced "$TMPL_PATH" && ok "1g. 模板引用了四支新腳本的安裝路徑" \
        || bad "1g. 模板還沒引用 repair-token-guard/-gateway-fetch/-gateway-report/-tunnel-launch——task 5 尚未落地（預期紅）"
    prop_sudoers_nopasswd "$TMPL_PATH" && ok "1h. 模板有 /etc/sudoers.d/ 的 NOPASSWD sudo 規則（2026-09-29 決定）" \
        || bad "1h. 模板沒有任何 /etc/sudoers.d/ 的 NOPASSWD 規則——repair 帳號在 VM 上沒有 root（8b.4，預期紅）"
    prop_sudoers_login_user_only "$TMPL_PATH" && ok "1h2. sudo 規則的 principal 只給登入使用者，不是 ALL" \
        || bad "1h2. sudo 規則的 principal 不是只有 @@LOGIN_USER@@（出現裸 ALL？）——blast radius 要對齐一個帳號（預期紅）"
    prop_no_packaged_name "$TMPL_PATH" && ok "1i. 模板沒有 @@NODE_NAME@@（名字不再逐台包進開機資料，本輪工單第 6 點）" \
        || bad "1i. 模板還有 @@NODE_NAME@@——名字應該完全來自 D2，不該再逐台渲染（預期紅）"
    if prop_no_single_port "$TMPL_PATH" && prop_has_port_range "$TMPL_PATH"; then
        ok "1j. 模板用 port 段（@@PROVIDER_PORT_RANGE@@／POOL_GATEWAY_PORT_RANGE=）取代單一 @@PROVIDER_PORT@@"
    else
        bad "1j. 模板還是單一 @@PROVIDER_PORT@@，或沒有段的 placeholder——port 應該是段，不寫死一個值（預期紅）"
    fi
    prop_tunnel_unit_network_ordering "$TMPL_PATH" \
        && ok "1k. 隧道 unit 自己的 [Unit] 區塊同時有 Wants=／After=network-online.target（真機發現：ACPI 關機時網路比隧道早斷，名牌沒被刪；systemd 反向停止順序要靠這兩行）" \
        || bad "1k. 隧道 unit 自己的 [Unit] 區塊沒有同時具備 Wants=／After=network-online.target——關機時網路可能比隧道先斷，名牌刪不掉"
    prop_tunnel_unit_killmode_mixed "$TMPL_PATH" \
        && ok "1l. 隧道 unit 自己的 [Service] 區塊有 KillMode=mixed（真機發現的真正根因：control-group 預設會把 ssh master 跟 launch script 一起殺掉，on_stop 沒有 master 可以刪名牌）" \
        || bad "1l. 隧道 unit 的 [Service] 區塊沒有 KillMode=mixed（或值不對）——關機時 ssh master 會被跟主行程一起殺掉，名牌刪不掉"
else
    for id in 1a 1b 1c 1d 1e 1f 1g 1g0 1h 1h2 1i 1j 1k 1l; do bad "${id}. ${TEMPLATE} 不存在——無法驗證"; done
fi

echo "--- 1x. 注入：對模板複本動刀，證明上面的比對真的在看內容 ---"
mk_mutant() {
    # mk_mutant <needle-desc> <python-expr-on-src>（stdin 是原始碼，stdout 是改過的）
    python3 - "$TMPL_PATH" "$1" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
mode = sys.argv[2]
if mode == "no-defer":
    # 只拿掉「隧道私鑰那一塊」的 defer: true（跟 prop_key_defer_true 用同一個
    # 錨：path: 那行含 id_tunnel 或 TUNNEL_KEY_PATH，區塊到下一個 - path: 或
    # 頂層 key 為止），不是檔案裡第一個出現的 defer: true——這樣模板裡就算
    # 多一個合法的 deferred 檔案（且剛好排在私鑰前面），這個注入砍的仍然是
    # 私鑰那一塊，不會誤砍別的檔案。
    import re
    lines = src.splitlines(keepends=True)
    path_idxs = [i for i, l in enumerate(lines) if re.match(r'^[ \t]*-[ \t]*path:', l)]
    key_j = None
    for j, i in enumerate(path_idxs):
        if re.search(r'id_tunnel|TUNNEL_KEY_PATH', lines[i]):
            key_j = j
            break
    assert key_j is not None, "key block (id_tunnel/TUNNEL_KEY_PATH) not found"
    start = path_idxs[key_j]
    end = path_idxs[key_j + 1] if key_j + 1 < len(path_idxs) else len(lines)
    block = lines[start:end]
    removed = False
    for k, l in enumerate(block):
        if re.match(r'^[ \t]*defer:[ \t]*true[ \t]*$', l.rstrip("\n")):
            del block[k]
            removed = True
            break
    assert removed, "key block has no defer: true to remove"
    lines[start:end] = block
    src = "".join(lines)
elif mode == "listen-any":
    assert "ListenAddress 127.0.0.1" in src
    src = src.replace("ListenAddress 127.0.0.1", "ListenAddress 0.0.0.0", 1)
elif mode == "add-sync":
    src += "\n# injected for test-repair-host-vm.sh\nruncmd_extra: [ systemctl, enable, --now, pool-sync.timer ]\n"
elif mode == "no-network-ordering":
    # 只動隧道 unit（mlp-tunnel-repair.service）自己那個區塊的 Wants=/After=
    # 那兩行，把 network-online.target 從裡面拿掉（d2-fetch 那個 unit的同名
    # 字串留著不動——這樣如果斷言誤看了別的 unit，這個注入不會讓它翻紅，可以
    # 抓出「掃描範圍抓錯」這種假綠）。
    lines = src.splitlines(keepends=True)
    path_idxs = [i for i, l in enumerate(lines) if re.match(r'^[ \t]*-[ \t]*path:', l)]
    unit_j = None
    for j, i in enumerate(path_idxs):
        if "mlp-tunnel-repair.service" in lines[i]:
            unit_j = j
            break
    assert unit_j is not None, "mlp-tunnel-repair.service block not found"
    start = path_idxs[unit_j]
    end = path_idxs[unit_j + 1] if unit_j + 1 < len(path_idxs) else len(lines)
    block = lines[start:end]
    changed = False
    for k, l in enumerate(block):
        if re.match(r'^[ \t]*Wants=.*network-online\.target', l) or re.match(r'^[ \t]*After=.*network-online\.target', l):
            block[k] = re.sub(r'\s*network-online\.target', '', l, count=1)
            changed = True
    assert changed, "no Wants=/After= network-online.target line to strip in the tunnel unit block"
    lines[start:end] = block
    src = "".join(lines)
elif mode == "no-killmode":
    # 拿掉隧道 unit 自己 [Service] 區塊裡的 KillMode=mixed 那一行（同一種
    # 「先找 path: 再掃到下一個 path: 或頂層 key 為止」的區塊定位，不動別的
    # unit——模板目前只有這一個 unit 有 KillMode，但用同一套區塊掃法保持
    # 跟 no-network-ordering 一致，也不怕以後別的 unit 也長出一行同名設定）。
    lines = src.splitlines(keepends=True)
    path_idxs = [i for i, l in enumerate(lines) if re.match(r'^[ \t]*-[ \t]*path:', l)]
    unit_j = None
    for j, i in enumerate(path_idxs):
        if "mlp-tunnel-repair.service" in lines[i]:
            unit_j = j
            break
    assert unit_j is not None, "mlp-tunnel-repair.service block not found"
    start = path_idxs[unit_j]
    end = path_idxs[unit_j + 1] if unit_j + 1 < len(path_idxs) else len(lines)
    block = lines[start:end]
    removed = False
    for k, l in enumerate(block):
        if re.match(r'^[ \t]*KillMode[ \t]*=', l):
            del block[k]
            removed = True
            break
    assert removed, "no KillMode= line to remove in the tunnel unit block"
    lines[start:end] = block
    src = "".join(lines)
elif mode == "sudo-all":
    # 把 sudoers 規則的 principal 改成 ALL（模擬「不只有該帳號」的退化：
    # 任何本機帳號都能免密碼 root）。只動 sudoers 區塊裡的主體欄位。
    lines = src.splitlines(keepends=True)
    outs = []
    insudo = False
    for l in lines:
        if re.match(r'^[ \t]*-[ \t]*path:[ \t]*/etc/sudoers\.d/', l):
            insudo = True
        elif re.match(r'^[ \t]*-[ \t]*path:', l) or re.match(r'^[^ \t]', l):
            insudo = False
        if insudo and re.match(r'^[ \t]*@@LOGIN_USER@@[ \t]', l):
            l = re.sub(r'^([ \t]*)@@LOGIN_USER@@', r'\1ALL', l, count=1)
        outs.append(l)
    new = "".join(outs)
    assert new != src, "no sudoers principal line to change"
    src = new
else:
    raise SystemExit("unknown mode " + mode)
sys.stdout.write(src)
PY
}
if [[ -f "$TMPL_PATH" ]]; then
    m1="$SANDBOX/tmpl-no-defer.tmpl"; mk_mutant "no-defer" > "$m1" 2>"$SANDBOX/mk1.err"
    if [[ -s "$m1" ]] && ! prop_key_defer_true "$m1"; then
        inj_ok "1x. 拿掉隧道私鑰那一塊的 defer: true 後 1d 會紅"
    else
        inj_bad "1x. 拿掉隧道私鑰那一塊的 defer: true 後 1d 仍綠——注入沒生效或斷言沒在量內容（$(cat "$SANDBOX/mk1.err" 2>/dev/null)）"
    fi
    m2="$SANDBOX/tmpl-listen-any.tmpl"; mk_mutant "listen-any" > "$m2" 2>"$SANDBOX/mk2.err"
    if [[ -s "$m2" ]] && ! prop_sshd_loopback "$m2"; then
        inj_ok "1x. ListenAddress 改成 0.0.0.0 後 1b 會紅"
    else
        inj_bad "1x. ListenAddress 改掉後 1b 仍綠（$(cat "$SANDBOX/mk2.err" 2>/dev/null)）"
    fi
    m3="$SANDBOX/tmpl-add-sync.tmpl"; mk_mutant "add-sync" > "$m3" 2>"$SANDBOX/mk3.err"
    if [[ -s "$m3" ]] && ! prop_no_sync_resolve "$m3"; then
        inj_ok "1x. 加一行 pool-sync 啟用後 1f 會紅"
    else
        inj_bad "1x. 加了 pool-sync 啟用後 1f 仍綠（$(cat "$SANDBOX/mk3.err" 2>/dev/null)）"
    fi
    m5="$SANDBOX/tmpl-no-network-ordering.tmpl"; mk_mutant "no-network-ordering" > "$m5" 2>"$SANDBOX/mk5.err"
    if [[ -s "$m5" ]] && ! prop_tunnel_unit_network_ordering "$m5"; then
        inj_ok "1x. 拿掉隧道 unit 的 Wants=/After=network-online.target 後 1k 會紅"
    else
        inj_bad "1x. 拿掉隧道 unit 的 network-online.target 後 1k 仍綠——注入沒生效或斷言掃錯區塊（$(cat "$SANDBOX/mk5.err" 2>/dev/null)）"
    fi
    m6="$SANDBOX/tmpl-no-killmode.tmpl"; mk_mutant "no-killmode" > "$m6" 2>"$SANDBOX/mk6.err"
    if [[ -s "$m6" ]] && ! prop_tunnel_unit_killmode_mixed "$m6"; then
        inj_ok "1x. 拿掉隧道 unit 的 KillMode=mixed 後 1l 會紅"
    else
        inj_bad "1x. 拿掉隧道 unit 的 KillMode=mixed 後 1l 仍綠——注入沒生效或斷言掃錯區塊（$(cat "$SANDBOX/mk6.err" 2>/dev/null)）"
    fi
    # sudo-all：只有當模板已有一行 principal 是 @@LOGIN_USER@@ 的 sudo 規則
    # 才注入（現碼還沒有，注入會以 mk 失敗收場——那是預期，以 inj_skip 記）。
    if grep -qE '^[[:space:]]*@@LOGIN_USER@@[[:space:]]' "$TMPL_PATH" 2>/dev/null; then
        m4="$SANDBOX/tmpl-sudo-all.tmpl"; mk_mutant "sudo-all" > "$m4" 2>"$SANDBOX/mk4.err"
        if [[ -s "$m4" ]] && ! prop_sudoers_login_user_only "$m4"; then
            inj_ok "1x. principal 改成 ALL 後 1h2 會紅"
        else
            inj_bad "1x. principal 改成 ALL 後 1h2 仍綠（$(cat "$SANDBOX/mk4.err" 2>/dev/null)）"
        fi
    else
        inj_skip "1x. 模板還沒有 NOPASSWD 規則（1h/1h2 現碼本身就是紅）；等 impl 落地後這個注入才有刀可動"
    fi
else
    inj_skip "1x. 模板不存在，無法動刀"
fi
inj_skip "1e/1g. 兩項在 task 5 落地後已綠（見上）；注入 1x 的模板突變各自對應 1d/1b/1f/1k/1l。1h/1h2 的注入（sudo-all）在模板出現 NOPASSWD 規則後才會執行，理由見該處。"
inj_skip "1i/1j. 現碼本身就是紅（模板還沒換掉 @@NODE_NAME@@／@@PROVIDER_PORT@@）；本輪沒有對這兩項做正向注入——落地後只是『拿掉 port 段字串』這種平凡的字串比對，跟 1e/1g 同一類，價值有限"

echo
echo "=== 2. 權杖守衛（D5 後半） ==="
if [[ ! -x "$REPO_ROOT/$GUARD" && ! -x "$GUARD" ]]; then
    for id in 2a 2b 2c 2d; do bad "${id}. ${GUARD} 不存在——本測試定義它的行為（預期紅）"; done
else
    GUARD_BIN="$REPO_ROOT/$GUARD"; [[ -x "$GUARD_BIN" ]] || GUARD_BIN="$GUARD"
    run_guard() {
        env -i PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR" "$@" "$GUARD_BIN"
    }
    # 2a：都沒有 → 放行
    out="$(run_guard 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] && ok "2a. 沒有權杖檔也沒有 GH_* 環境變數 → 放行（rc 0）" \
        || bad "2a. 乾淨環境下 guard 卻拒絕（rc ${rc}，out [${out}]）"

    # 2b：token 檔存在
    rm -f "$HOME_DIR/.mylinuxpool/gh_token"
    printf 'ghp_notarealtokenxxxxxxxxxxxxxxxxxxxx\n' > "$HOME_DIR/.mylinuxpool/gh_token"
    if [[ -f "$HOME_DIR/.mylinuxpool/gh_token" ]]; then
        ok "2b0. 正對照：測試自己確認 fixture 真的落在 guard 文件宣稱的路徑上"
    else
        bad "2b0（正對照失敗）：fixture 沒有真的建立——後面的 2b 不可信"
    fi
    out="$(run_guard 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]]; then
        ok "2b. token 檔存在 → guard 拒絕（rc ${rc}）"
        printf '%s' "$out" | grep -qi token && ok "2b1. 拒絕訊息提到 token" || bad "2b1. 拒絕訊息沒提到 token（out [${out}]）"
    else
        bad "2b. token 檔存在但 guard 仍放行（rc 0）"
    fi
    rm -f "$HOME_DIR/.mylinuxpool/gh_token"

    # 2c：GH_TOKEN 環境變數
    out="$(run_guard GH_TOKEN=notarealtoken 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]]; then
        ok "2c. GH_TOKEN 非空 → guard 拒絕（rc ${rc}）"
    else
        bad "2c. GH_TOKEN 非空但 guard 仍放行（rc 0）"
    fi

    # 2d：GH_POOL_TOKEN 環境變數
    out="$(run_guard GH_POOL_TOKEN=notarealtoken 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]]; then
        ok "2d. GH_POOL_TOKEN 非空 → guard 拒絕（rc ${rc}）"
    else
        bad "2d. GH_POOL_TOKEN 非空但 guard 仍放行（rc 0）"
    fi
fi
inj_skip "2. repair-token-guard 現碼不存在，沒有原始碼可以動刀——本節的紅（或落地後的綠）本身就是量測結果"

echo
echo "=== 3. D2 取值／回報 ==="
if [[ ! -x "$REPO_ROOT/$FETCH" && ! -x "$FETCH" ]]; then
    for id in 3a 3b 3c 3d 3e 3f 3g 3h; do bad "${id}. ${FETCH}／${REPORT} 不存在——本測試定義它的行為（預期紅）"; done
else
    FETCH_BIN="$REPO_ROOT/$FETCH"; [[ -x "$FETCH_BIN" ]] || FETCH_BIN="$FETCH"
    REPORT_BIN="$REPO_ROOT/$REPORT"; [[ -x "$REPORT_BIN" ]] || REPORT_BIN="$REPORT"

    # 3a: 服務回兩行（IP + name，介面 #4）→ 兩個值都寫入 gateway.env
    GWENV="$SANDBOX/gateway.env"
    : > "$SANDBOX/curl.log"
    rm -f "$GWENV"
    out="$(env -i PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR" \
        CURL_LOG="$SANDBOX/curl.log" FAKE_D2_MODE=ip FAKE_D2_IP=198.51.100.7 FAKE_D2_NAME=mom-pc \
        MLP_GATEWAY_ENV_FILE="$GWENV" MLP_D2_HOST=10.0.2.2 MLP_D2_PORT=18080 \
        "$FETCH_BIN" 2>&1)"; rc=$?
    if [[ -s "$SANDBOX/curl.log" ]]; then
        ok "3a0. 正對照：假 curl 真的被呼叫（log 非空）"
        if [[ $rc -eq 0 ]] && grep -q 'POOL_GATEWAY_HOST=198.51.100.7' "$GWENV" 2>/dev/null \
            && grep -q 'REPAIR_NAME=mom-pc' "$GWENV" 2>/dev/null; then
            ok "3a. 兩行都合法 → ${GWENV} 同時有 POOL_GATEWAY_HOST=198.51.100.7 與 REPAIR_NAME=mom-pc（rc ${rc}）"
        else
            bad "3a. body 是兩行合法值，但 ${GWENV} 沒有兩個對的值（rc ${rc}, content [$(cat "$GWENV" 2>/dev/null)], out [${out}]）——現碼很可能還是單行解析（預期紅，見報告：tr -d '[:space:]' 連 CRLF 一起吃掉，兩行會被黏成一行再驗 IPv4，必定驗不過）"
        fi
    else
        bad "3a0（正對照失敗）：假 curl 沒被呼叫——3a 不可信（out [${out}]）"
    fi

    # 3e-3h: /gw 兩行解析的反例——任一不合法都必須「完全不寫」，本輪工單第 1 點
    BASE_ENV="$SANDBOX/tunnel.env"
    cat > "$BASE_ENV" <<ENVEOF
POOL_NODE_NAME=repair-test
POOL_GATEWAY_PORT=2255
POOL_GATEWAY_USER=sshproxy
POOL_GATEWAY_SSH_PORT=2100
POOL_GATEWAY_HOST=gateway-ip-set-at-launch.invalid
ENVEOF
    run_fetch_bad() {
        # run_fetch_bad <id> <描述> <FAKE_D2_MODE 相關 env...>——先在 GWENV3
        # 塞一個「識別得出來的舊值」，跑 fetch，斷言舊值原封不動、exit 非 0。
        local id="$1" desc="$2"; shift 2
        local gwenv="$SANDBOX/gateway-${id}.env"
        printf 'POOL_GATEWAY_HOST=stale-%s.invalid\nREPAIR_NAME=stale-%s\n' "$id" "$id" > "$gwenv"
        local out rc
        out="$(env -i PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR" "$@" \
            MLP_GATEWAY_ENV_FILE="$gwenv" MLP_D2_HOST=10.0.2.2 MLP_D2_PORT=18080 \
            "$FETCH_BIN" 2>&1)"; rc=$?
        if [[ $rc -ne 0 ]] && grep -q "stale-${id}" "$gwenv" 2>/dev/null; then
            ok "${id}. ${desc} → exit 非 0（${rc}）且 gateway.env 原封不動"
        else
            bad "${id}. ${desc} → 沒有 fail closed（rc ${rc}, content [$(cat "$gwenv" 2>/dev/null)], out [${out}]）"
        fi
    }
    run_fetch_bad 3e "第二行缺失（body 只有 IP，舊協定的形狀）" FAKE_D2_MODE=ip_only FAKE_D2_IP=198.51.100.7
    run_fetch_bad 3f "第二行名字格式不合法（大寫）" FAKE_D2_MODE=ip FAKE_D2_IP=198.51.100.7 FAKE_D2_NAME=Mom-Pc
    run_fetch_bad 3g "第一行 IP 格式不合法" FAKE_D2_MODE=raw FAKE_D2_RAW_BODY=$'999.1.1.1\r\nname=mom-pc'
    run_fetch_bad 3h "多一行垃圾" FAKE_D2_MODE=ip FAKE_D2_IP=198.51.100.7 FAKE_D2_NAME=mom-pc FAKE_D2_EXTRA_LINE=extra-garbage-line

    # 3b: gateway.env 有值時，pool-tunnel 的撥號 argv 真的用得到它（直接構造
    # gateway.env，跟 3a 的 fetch 解析結果脫鉤——3b 驗的是「EnvironmentFile
    # 疊加 → 撥號」這條線路本身，不重複驗 fetch 怎麼解析）
    GWENV_PLUMB="$SANDBOX/gateway-plumb.env"
    printf 'POOL_GATEWAY_HOST=198.51.100.7\nREPAIR_NAME=mom-pc\n' > "$GWENV_PLUMB"
    : > "$SANDBOX/ssh.log"
    (
        set -a
        # shellcheck disable=SC1090
        . "$BASE_ENV"
        . "$GWENV_PLUMB"
        set +a
        env -i PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR" SSH_LOG="$SANDBOX/ssh.log" \
            POOL_NODE_NAME="$POOL_NODE_NAME" POOL_GATEWAY_PORT="$POOL_GATEWAY_PORT" \
            POOL_GATEWAY_USER="$POOL_GATEWAY_USER" POOL_GATEWAY_SSH_PORT="$POOL_GATEWAY_SSH_PORT" \
            POOL_GATEWAY_HOST="$POOL_GATEWAY_HOST" \
            bash "$REPO_ROOT/$PTUNNEL" --once >/dev/null 2>&1
    )
    dial="$(grep -e '-M -S' "$SANDBOX/ssh.log" 2>/dev/null | tail -n 1)"
    if [[ -n "$dial" ]]; then
        ok "3b0. 正對照：假 ssh 收到撥號呼叫"
        if printf '%s' "$dial" | grep -q '198.51.100.7'; then
            ok "3b. gateway.env 的 IP 真的傳到 pool-tunnel 的撥號 argv（不是取而不用）"
        else
            bad "3b. gateway.env 有值，但撥號 argv 沒用到它（argv [${dial}]）"
        fi
    else
        bad "3b0（正對照失敗）：假 ssh 沒被呼叫——3b 不可信"
    fi

    # 3c: 服務不在 → repair-gateway-fetch 不覆寫既有 gateway.env（獨立於「要不
    # 要撥號」——撥不撥號的新規則在 §6，這裡只驗 fetch 這一層本身的 fail-closed）
    GWENV2="$SANDBOX/gateway2.env"
    printf 'POOL_GATEWAY_HOST=stale-should-not-be-touched.invalid\n' > "$GWENV2"
    : > "$SANDBOX/curl.log"
    env -i PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR" \
        CURL_LOG="$SANDBOX/curl.log" FAKE_D2_MODE=down \
        MLP_GATEWAY_ENV_FILE="$GWENV2" MLP_D2_HOST=10.0.2.2 MLP_D2_PORT=18080 \
        "$FETCH_BIN" >/dev/null 2>&1
    if grep -q 'stale-should-not-be-touched.invalid' "$GWENV2" 2>/dev/null; then
        ok "3c. 服務不在（curl 失敗）→ 沒有覆寫既有的 gateway.env"
    else
        bad "3c. 服務不在時 gateway.env 被動過（content [$(cat "$GWENV2" 2>/dev/null)]）——family VM 可能連去猜出來的位址"
    fi
    # 舊 §3c2（「沒有 D2 值時，撥號用 placeholder」）已被 PM 取代——見檔頭與
    # 下面的 §6：新規則是「沒有合法答案就不撥號」，不是「撥打一個保證失敗的
    # 位址」。舊斷言本身其實仍然成立（pool-tunnel 拿到 placeholder 還是會去
    # 撥），但它已經不是規格要的行為，繼續留著會誤導——故整段移除，改在 §6
    # 驗新規則。

    # 3d: report
    : > "$SANDBOX/curl.log"
    env -i PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR" \
        CURL_LOG="$SANDBOX/curl.log" MLP_D2_HOST=10.0.2.2 MLP_D2_PORT=18080 \
        "$REPORT_BIN" up >/dev/null 2>&1
    if [[ -s "$SANDBOX/curl.log" ]]; then
        ok "3d0. 正對照：report 的假 curl 真的被呼叫"
        if grep -q '/state' "$SANDBOX/curl.log" && grep -q 'tunnel=up' "$SANDBOX/curl.log"; then
            ok "3d. 隧道起來後 report 用 POST 送出 tunnel=up 給 /state"
        else
            bad "3d. report 沒有送出對的 URL／body（log [$(cat "$SANDBOX/curl.log")]）"
        fi
    else
        bad "3d0（正對照失敗）：report 沒有呼叫假 curl——3d 不可信"
    fi
fi
inj_skip "3. repair-gateway-fetch/-report 現碼不存在，沒有原始碼可以動刀"

echo
echo "=== 4. D7 重試節奏（模擬時間，絕不真的 sleep） ==="
if [[ ! -x "$REPO_ROOT/$LAUNCH" && ! -x "$LAUNCH" ]]; then
    for id in 4a 4b; do bad "${id}. ${LAUNCH} 不存在——本測試定義它的行為（預期紅）"; done
else
    LAUNCH_BIN="$REPO_ROOT/$LAUNCH"; [[ -x "$LAUNCH_BIN" ]] || LAUNCH_BIN="$LAUNCH"
    DIAL_TIMES="$SANDBOX/dial-times-4.log"
    CLOCK="$SANDBOX/clock-4"
    : > "$DIAL_TIMES"; printf '0\n' > "$CLOCK"
    # 700 秒的模擬時間就足夠看「任何 10 分鐘視窗」——超過一個視窗長度即可。
    RUNENV=(
        PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR"
        SSH_LOG="$SANDBOX/ssh-4.log" MLP_TEST_DIAL_TIMES="$DIAL_TIMES"
        MLP_TEST_CLOCK="$CLOCK" MLP_TEST_CLOCK_CAP=700
        MLP_TEST_SSH_STDERR="Permission denied (publickey)."
        MLP_TEST_SLEEP_LOG="$SANDBOX/sleep-4.log"
        MLP_REPAIR_POOL_TUNNEL_BIN="$REPO_ROOT/$PTUNNEL"
        POOL_NODE_NAME=repair-test POOL_GATEWAY_PORT=2255
        POOL_GATEWAY_USER=sshproxy POOL_GATEWAY_SSH_PORT=2100
        POOL_GATEWAY_HOST=203.0.113.9
        # 本輪新增的兩個變數：現碼（沒有 §6/§8 的新邏輯）完全不讀它們，純粹
        # 多餘、無害；未來落地版本需要它們才會撥號（gateway.env 要能被
        # fetch 寫到有效值，MLP_D2_* 沒設就是預設的 10.0.2.2:18080，假 curl
        # 預設 FAKE_D2_MODE=ip 會成功；段給 2400,2499）——這樣 D7 這個既有
        # 斷言在新舊兩種實作下都能維持綠色，不用因為介面換了就報一次假紅。
        MLP_GATEWAY_ENV_FILE="$SANDBOX/gateway-4.env"
        POOL_GATEWAY_PORT_RANGE=2400,2499
    )
    if command -v timeout >/dev/null 2>&1; then
        # belt and suspenders：虛擬時鐘的 TERM 才是真正的終止機制（見假
        # sleep 的註解），這裡的真實 20 秒只是防呆，不是用來模擬 10 分鐘。
        timeout -k 5 20 env -i "${RUNENV[@]}" "$LAUNCH_BIN" >/dev/null 2>&1
    else
        env -i "${RUNENV[@]}" "$LAUNCH_BIN" >/dev/null 2>&1 &
        lpid=$!
        wait "$lpid" 2>/dev/null
    fi
    n_dials="$(wc -l < "$DIAL_TIMES" 2>/dev/null | tr -d '[:space:]')"; [[ -z "$n_dials" ]] && n_dials=0
    if [[ "${n_dials:-0}" -ge 2 ]]; then
        ok "4a. 正對照：模擬 700 秒內假 ssh 收到 ${n_dials} 次撥號嘗試（不是 0 次或 1 次就沒動靜）"
        maxw="$(count_max_window "$DIAL_TIMES" 600)"
        if [[ "$maxw" -lt 5 ]]; then
            ok "4b. 任何 600 秒（10 分鐘）滑動視窗內的嘗試次數 < 5（量到最多 ${maxw} 次）"
        else
            bad "4b. 有一個 600 秒視窗內嘗試 ${maxw} 次（>=5）——會撞到 fail2ban 預設的 10 分鐘 5 次門檻"
        fi
    else
        bad "4a（正對照失敗）：700 秒模擬時間內只收到 ${n_dials} 次撥號——4b 不可信（repair-tunnel-launch 可能整個沒跑起來，或退避拉太長）"
    fi
fi

echo "--- 4c. 自我驗證：視窗計數器不是一個永遠回答「沒問題」的空殼 ---"
BAD_SCHEDULE="$SANDBOX/bad-schedule.times"
python3 - > "$BAD_SCHEDULE" <<'PY'
# 仿 pool-tunnel 自己原生的退避數列 2,4,8,16,30,30,30,...，看它在 600 秒視窗
# 內會不會被抓到違規（它本來就會——這是 D7 存在的理由）。
t = 0
times = [t]
backoffs = [2, 4, 8, 16, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
for b in backoffs:
    t += b
    times.append(t)
for x in times:
    print(x)
PY
maxw_bad="$(count_max_window "$BAD_SCHEDULE" 600)"
if [[ "$maxw_bad" -ge 5 ]]; then
    ok "4c. 計數器對 pool-tunnel 原生退避數列正確回報違規（${maxw_bad} 次 >= 5）——不是空殼"
else
    bad "4c. 計數器對已知會違規的數列（${maxw_bad} 次）沒有抓到——計數器本身有問題，4b 的綠不可信"
fi
GOOD_SCHEDULE="$SANDBOX/good-schedule.times"
python3 -c "print('\n'.join(str(i*180) for i in range(6)))" > "$GOOD_SCHEDULE"
maxw_good="$(count_max_window "$GOOD_SCHEDULE" 600)"
if [[ "$maxw_good" -lt 5 ]]; then
    ok "4c2. 計數器對平坦 180 秒間隔的數列正確回報不違規（${maxw_good} 次 < 5）"
else
    bad "4c2. 計數器對合理數列（${maxw_good} 次）誤報違規"
fi
inj_skip "4. repair-tunnel-launch 現碼不存在，沒有原始碼可以動刀；4c/4c2 是對計數器本身的自我驗證，不是對 subject 的注入"

echo
echo "=== 5. 回歸：非維修模式的 pool-tunnel backoff 不變 ==="
run_ptunnel_backoff() {
    # run_ptunnel_backoff <lib-path> — 跑到收集滿 6 次撥號或虛擬時鐘到頂為止。
    local lib="$1"
    local dial="$SANDBOX/dial-5.log" clock="$SANDBOX/clock-5" sleeplog="$SANDBOX/sleep-5.log"
    : > "$dial"; printf '0\n' > "$clock"; : > "$sleeplog"
    local runenv=(
        PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR"
        SSH_LOG="$SANDBOX/ssh-5.log" MLP_TEST_DIAL_TIMES="$dial"
        MLP_TEST_CLOCK="$clock" MLP_TEST_CLOCK_CAP=120
        MLP_TEST_SLEEP_LOG="$sleeplog"
        POOL_NODE_NAME=repair-test POOL_GATEWAY_PORT=2255
        POOL_GATEWAY_USER=sshproxy POOL_GATEWAY_SSH_PORT=2100
        POOL_GATEWAY_HOST=203.0.113.9
    )
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 5 20 env -i "${runenv[@]}" bash "$lib" >/dev/null 2>&1
    else
        env -i "${runenv[@]}" bash "$lib" >/dev/null 2>&1 &
        wait $! 2>/dev/null
    fi
    RB_SLEEPS="$(grep -v '^1$' "$sleeplog" 2>/dev/null | head -n 6 | tr '\n' ',' )"
    RB_DIALS="$(wc -l < "$dial" 2>/dev/null | tr -d '[:space:]')"; [[ -z "$RB_DIALS" ]] && RB_DIALS=0
}

run_ptunnel_backoff "$REPO_ROOT/$PTUNNEL"
if [[ "${RB_DIALS:-0}" -ge 2 ]]; then
    ok "5a. 正對照：非維修模式下假 ssh 收到 ${RB_DIALS} 次撥號嘗試"
    if [[ "$RB_SLEEPS" == "2,4,8,16,30,30,"* || "$RB_SLEEPS" == "2,4,8,16,30,30" ]]; then
        ok "5b. pool-tunnel 自己的退避數列仍是 2,4,8,16,30,30,...（got [${RB_SLEEPS}]）"
    else
        bad "5b. pool-tunnel 的退避數列變了（got [${RB_SLEEPS}]，預期以 2,4,8,16,30,30 開頭）——D7 不該碰到非維修模式的節奏"
    fi
else
    bad "5a（正對照失敗）：非維修模式下假 ssh 只收到 ${RB_DIALS:-0} 次撥號——5b 不可信"
fi

echo "--- 5x. 注入：拿掉 pool-tunnel 退避的封頂，5b 必須翻紅 ---"
inj_lib="$SANDBOX/ptunnel-nocap"
mkdir -p "$inj_lib"
python3 - "$REPO_ROOT/$PTUNNEL" "$inj_lib/pool-tunnel" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r'next_backoff\(\) \{\n(.*?)\n\}\n', re.S)
m = pat.search(src)
assert m, "next_backoff needle not found"
new_body = (
    'next_backoff() {\n'
    '    echo $(( $1 * 2 ))\n'
    '}\n'
)
src = src[:m.start()] + new_body + src[m.end():]
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
if [[ $? -eq 0 ]] && bash -n "$inj_lib/pool-tunnel" 2>/dev/null; then
    cp "$SANDBOX/tunnel-identity.sh" "$inj_lib/tunnel-identity.sh"
    run_ptunnel_backoff "$inj_lib/pool-tunnel"
    if [[ "${RB_DIALS:-0}" -ge 2 && "$RB_SLEEPS" != "2,4,8,16,30,30,"* && "$RB_SLEEPS" != "2,4,8,16,30,30" ]]; then
        inj_ok "5x. 拿掉封頂（一路倍增）後 5b 會紅（got [${RB_SLEEPS}]）"
    else
        inj_bad "5x. 拿掉封頂後 5b 仍然「通過」——注入沒生效，或斷言沒在量退避數列（dials=${RB_DIALS:-0}, got [${RB_SLEEPS}]）"
    fi
else
    inj_bad "5x. 注入腳本失敗（needle 落空或語法錯）——harness 問題"
fi

echo
echo "=== 6. 沒有合法答案就不撥號（取代舊 §3c2；工單第 1/4 點；PM 裁定） ==="
LAUNCH_BIN="$REPO_ROOT/$LAUNCH"; [[ -x "$LAUNCH_BIN" ]] || LAUNCH_BIN="$LAUNCH"
if [[ ! -x "$LAUNCH_BIN" ]]; then
    for id in 6a 6b 6c; do bad "${id}. ${LAUNCH} 不存在——本測試定義它的行為（預期紅）"; done
else
    run_launch_loop() {
        # run_launch_loop <label> <gwenv-content-or-empty> [port-range|NONE] [sudo-mode]
        #   跑一小段模擬時間（用假時鐘，絕不真的 sleep），把 gateway.env 先塞
        #   成 <gwenv-content>（空字串＝完全沒有這個檔），FAKE_D2_MODE=down
        #   讓即時的 fetch 一律失敗、不會覆寫我塞的內容。第三個參數是
        #   POOL_GATEWAY_PORT_RANGE 的值，預設 2400,2499；傳字面 NONE 表示
        #   完全不設這個環境變數（§8i 用來驗證「讀不到段就拒絕」）。第四個
        #   參數是 FAKE_SUDO_MODE（預設 ok；§10c 傳 fail，驗證 sudo 失敗不會
        #   擋撥號）。結果記到 RL_DIALS／RL_FIRST_SLEEP／RL_DOWN／RL_HOSTCALL／
        #   RL_SUDOCALL 五個全域變數。
        local label="$1" content="$2" prange="${3:-2400,2499}" sudo_mode="${4:-ok}"
        local gwenv="$SANDBOX/gwenv-${label}.env"
        local sshlog="$SANDBOX/ssh-${label}.log" sleeplog="$SANDBOX/sleep-${label}.log"
        local curllog="$SANDBOX/curl-${label}.log" hostlog="$SANDBOX/hostnamectl-${label}.log"
        local sudolog="$SANDBOX/sudo-${label}.log"
        local clock="$SANDBOX/clock-${label}"
        if [[ -n "$content" ]]; then printf '%s\n' "$content" > "$gwenv"; else rm -f "$gwenv"; fi
        : > "$sshlog"; : > "$sleeplog"; : > "$curllog"; : > "$hostlog"; : > "$sudolog"; printf '0\n' > "$clock"
        local runenv=(
            PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR"
            SSH_LOG="$sshlog" MLP_TEST_SLEEP_LOG="$sleeplog"
            MLP_TEST_CLOCK="$clock" MLP_TEST_CLOCK_CAP=100
            MLP_TEST_SSH_STDERR="Could not resolve hostname gateway-ip-set-at-launch.invalid: Name or service not known"
            CURL_LOG="$curllog" FAKE_D2_MODE=down HOSTNAMECTL_LOG="$hostlog"
            SUDO_LOG="$sudolog" FAKE_SUDO_MODE="$sudo_mode"
            MLP_GATEWAY_ENV_FILE="$gwenv"
            MLP_REPAIR_POOL_TUNNEL_BIN="$REPO_ROOT/$PTUNNEL"
            POOL_NODE_NAME=repair-test POOL_GATEWAY_PORT=2255
            POOL_GATEWAY_USER=sshproxy POOL_GATEWAY_SSH_PORT=2100
            POOL_GATEWAY_HOST=gateway-ip-set-at-launch.invalid
        )
        [[ "$prange" != "NONE" ]] && runenv+=( POOL_GATEWAY_PORT_RANGE="$prange" )
        if command -v timeout >/dev/null 2>&1; then
            timeout -k 5 20 env -i "${runenv[@]}" "$LAUNCH_BIN" >/dev/null 2>&1
        else
            env -i "${runenv[@]}" "$LAUNCH_BIN" >/dev/null 2>&1 &
            wait $! 2>/dev/null
        fi
        RL_DIALS="$(grep -c -e '-M -S' "$sshlog" 2>/dev/null | tr -d '[:space:]')"; [[ -z "$RL_DIALS" ]] && RL_DIALS=0
        RL_FIRST_SLEEP="$(grep -v '^1$' "$sleeplog" 2>/dev/null | head -n 1)"; [[ -z "$RL_FIRST_SLEEP" ]] && RL_FIRST_SLEEP=-1
        RL_DOWN="$(grep -c 'tunnel=down' "$curllog" 2>/dev/null | tr -d '[:space:]')"; [[ -z "$RL_DOWN" ]] && RL_DOWN=0
        RL_HOSTCALL="$(wc -l < "$hostlog" 2>/dev/null | tr -d '[:space:]')"; [[ -z "$RL_HOSTCALL" ]] && RL_HOSTCALL=0
        RL_SUDOCALL="$(wc -l < "$sudolog" 2>/dev/null | tr -d '[:space:]')"; [[ -z "$RL_SUDOCALL" ]] && RL_SUDOCALL=0
    }

    # 6a：從來沒有 gateway.env（模擬 D2 從沒回過答案）
    run_launch_loop "6a" ""
    if [[ "$RL_DIALS" -eq 0 ]]; then
        ok "6a. 從沒拿到 D2 答案 → 一次 ssh 撥號都沒有（量到 ${RL_DIALS} 次）"
    else
        bad "6a. 從沒拿到 D2 答案，但還是撥了 ${RL_DIALS} 次號——現碼仍然撥打開機資料的 placeholder（舊 §3c2 的行為，已被取代，預期紅）"
    fi
    [[ "$RL_DOWN" -ge 1 ]] && ok "6a1. 有呼叫 report down（量到 ${RL_DOWN} 次）" \
        || bad "6a1. 沒有呼叫 report down"
    if [[ "$RL_FIRST_SLEEP" -ge 0 && "$RL_FIRST_SLEEP" -lt 300 ]]; then
        ok "6a2. 重試節奏是快退（首次 sleep ${RL_FIRST_SLEEP}s < 300s），不是 D7 的 310 秒"
    else
        bad "6a2. 首次 sleep 是 ${RL_FIRST_SLEEP}s——不是預期的快退（可能整個沒有 sleep，或落到 310 秒的 counted 節奏）"
    fi
    [[ "$RL_HOSTCALL" -eq 0 ]] && ok "6a3. 沒有 gateway.env 時沒有呼叫 hostnamectl" \
        || bad "6a3. 沒有 gateway.env 時卻呼叫了 hostnamectl（${RL_HOSTCALL} 次）"

    # 6b：gateway.env 有合法 IP，但名字格式不合法（大寫）——繞過 fetch 直接塞
    # 這個內容，測的是 repair-tunnel-launch 自己有沒有再驗一次名字格式
    run_launch_loop "6b" $'POOL_GATEWAY_HOST=198.51.100.7\nREPAIR_NAME=Mom-Pc'
    if [[ "$RL_DIALS" -eq 0 ]]; then
        ok "6b. gateway.env 的名字格式不合法（Mom-Pc）→ 一次撥號都沒有"
    else
        bad "6b. 名字格式不合法（Mom-Pc）但還是撥了 ${RL_DIALS} 次號——launch 目前完全不驗 REPAIR_NAME（預期紅：這個概念還不存在）"
    fi
    [[ "$RL_HOSTCALL" -eq 0 ]] && ok "6b1. 名字不合法時沒有呼叫 hostnamectl" \
        || bad "6b1. 名字不合法時卻呼叫了 hostnamectl（${RL_HOSTCALL} 次，argv 內容：$(cat "$SANDBOX/hostnamectl-6b.log" 2>/dev/null)）"

    # 6c（正對照 / 回歸）：兩個值都合法 → 應該照樣撥號（不能矯枉過正變成完全不撥）
    run_launch_loop "6c" $'POOL_GATEWAY_HOST=198.51.100.7\nREPAIR_NAME=mom-pc'
    if [[ "$RL_DIALS" -ge 1 ]]; then
        ok "6c. 正對照：兩個值都合法時，撥號照常發生（量到 ${RL_DIALS} 次）——不是這個 harness 本身沒在動"
    else
        bad "6c（正對照失敗）：兩個值都合法卻一次都沒撥號——上面 6a/6b 的『沒撥號』量不到意義，因為 harness 本身可能有問題"
    fi
fi
inj_skip "6. 現碼的『撥不撥號』邏輯還沒有這一層守門，沒有原始碼可以動刀；6a/6b 對現碼的紅本身就是量測結果"

echo
echo "=== 7. 名字：hostname 動作與唯一來源（工單第 2 點） ==="
run_src() {
    # run_src <body-file> <extra env assignments...>
    #   在乾淨環境＋假時鐘裡 source ${LAUNCH_BIN}，成功的話再 source
    #   <body-file>。假時鐘的 TERM 自毀機制保底：現碼若沒有「被 source 不跑
    #   主迴圈」的守衛，主迴圈會被假時鐘在 5 秒模擬時間內喊停，SRC_OUT 就會
    #   缺少 body 腳本原本要印的標記——那本身就是「沒有守衛」的紅燈證據。
    local bodyfile="$1"; shift
    local clock="$SANDBOX/clock-src"
    : > "$SANDBOX/ssh-src.log"; : > "$SANDBOX/sleep-src.log"; : > "$SANDBOX/hostnamectl-src.log"
    printf '0\n' > "$clock"
    local runenv=(
        PATH="$SHIMS:/usr/bin:/bin" HOME="$HOME_DIR"
        SSH_LOG="$SANDBOX/ssh-src.log" MLP_TEST_SLEEP_LOG="$SANDBOX/sleep-src.log"
        MLP_TEST_CLOCK="$clock" MLP_TEST_CLOCK_CAP=5
        FAKE_D2_MODE=down HOSTNAMECTL_LOG="$SANDBOX/hostnamectl-src.log"
        MLP_REPAIR_POOL_TUNNEL_BIN="$REPO_ROOT/$PTUNNEL"
        "$@"
    )
    if command -v timeout >/dev/null 2>&1; then
        SRC_OUT="$(timeout -k 2 8 env -i "${runenv[@]}" bash -c \
            'source "$1" 2>/dev/null || { echo SOURCE_FAILED; exit 0; }; source "$2"' \
            _ "$LAUNCH_BIN" "$bodyfile" 2>&1)"
    else
        env -i "${runenv[@]}" bash -c \
            'source "$1" 2>/dev/null || { echo SOURCE_FAILED; exit 0; }; source "$2"' \
            _ "$LAUNCH_BIN" "$bodyfile" > "$SANDBOX/src-out.tmp" 2>&1 &
        wait $! 2>/dev/null
        SRC_OUT="$(cat "$SANDBOX/src-out.tmp" 2>/dev/null)"
    fi
}

BODY_HOSTNAME="$SANDBOX/body-hostname.sh"
cat > "$BODY_HOSTNAME" <<'BODY'
if ! declare -F apply_repair_name >/dev/null 2>&1; then
    echo "MISSING:apply_repair_name"
    exit 0
fi
echo "GUARD_OK"
printf 'POOL_GATEWAY_HOST=198.51.100.7\nREPAIR_NAME=mom-pc\n' > "$MLP_GATEWAY_ENV_FILE"
apply_repair_name "mom-pc" 2>/dev/null
if grep -q 'set-hostname mom-pc' "$HOSTNAMECTL_LOG" 2>/dev/null; then echo "OK:7a"; else echo "FAIL:7a"; fi
: > "$HOSTNAMECTL_LOG"
apply_repair_name "Bad_Name" 2>/dev/null
if [[ -s "$HOSTNAMECTL_LOG" ]]; then echo "FAIL:7c"; else echo "OK:7c"; fi
BODY

GWENV_SRC="$SANDBOX/gwenv-src.env"
run_src "$BODY_HOSTNAME" MLP_GATEWAY_ENV_FILE="$GWENV_SRC" \
    POOL_NODE_NAME=repair-test POOL_GATEWAY_PORT=2255 POOL_GATEWAY_USER=sshproxy \
    POOL_GATEWAY_SSH_PORT=2100 POOL_GATEWAY_HOST=gateway-ip-set-at-launch.invalid

if printf '%s' "$SRC_OUT" | grep -q '^MISSING:'; then
    for id in 7.0 7a 7c; do bad "${id}. $(printf '%s' "$SRC_OUT" | grep '^MISSING:')——apply_repair_name 這個函式（或同等機制）還不存在（預期紅）"; done
elif ! printf '%s' "$SRC_OUT" | grep -q '^GUARD_OK$'; then
    for id in 7.0 7a 7c; do bad "${id}. source ${LAUNCH} 沒有在合理時間內把控制權還給呼叫端（沒有守衛，或主迴圈把假時鐘也吃掉了）——SRC_OUT=[${SRC_OUT}]"; done
else
    ok "7.0. source ${LAUNCH} 安全返回（有守衛），可以單獨呼叫內部函式"
    printf '%s' "$SRC_OUT" | grep -q '^OK:7a$' && ok "7a. gateway.env 有合法 REPAIR_NAME → 呼叫 hostnamectl set-hostname <name>" \
        || bad "7a. 沒有呼叫對的 hostnamectl set-hostname（SRC_OUT=[${SRC_OUT}]）"
    printf '%s' "$SRC_OUT" | grep -q '^OK:7c$' && ok "7c. 名字格式不合法（Bad_Name）時，不盲目把它交給 hostnamectl（防禦性再驗一次格式）" \
        || bad "7c. 格式不合法的名字被直接交給 hostnamectl（SRC_OUT=[${SRC_OUT}]）"
fi
inj_skip "7. apply_repair_name 現碼不存在，沒有原始碼可以動刀；7b（唯一來源、無 POOL_NODE_NAME 後門）在 §6a3/6b1 用全流程驗過——只要 gateway.env 沒有合法 REPAIR_NAME，不管 POOL_NODE_NAME 是什麼，hostnamectl 都不該被呼叫"

echo
echo "=== 8. Port 段：起始、換 port、Permission denied 絕不換 port（工單第 3/4 點） ==="
BODY_PORT="$SANDBOX/body-port.sh"
cat > "$BODY_PORT" <<'BODY'
missing=""
declare -F next_port >/dev/null 2>&1 || missing="${missing} next_port"
declare -F classify_dial_failure >/dev/null 2>&1 || missing="${missing} classify_dial_failure"
declare -F has_valid_gateway >/dev/null 2>&1 || missing="${missing} has_valid_gateway"
if [[ -n "$missing" ]]; then
    echo "MISSING:${missing}"
    exit 0
fi
echo "GUARD_OK"
echo "NP1:$(next_port 2400 2400 2499)"
echo "NP2:$(next_port 2499 2400 2499)"
echo "NP3:$(next_port 2450 2400 2499)"
echo "CF1:$(classify_dial_failure 'Permission denied (publickey).')"
echo "CF2:$(classify_dial_failure 'remote port forwarding failed')"
echo "CF3:$(classify_dial_failure 'Connection refused')"
printf 'POOL_GATEWAY_HOST=198.51.100.7\nREPAIR_NAME=mom-pc\n' > "$MLP_GATEWAY_ENV_FILE"
if has_valid_gateway; then echo "HVG1:yes"; else echo "HVG1:no"; fi
printf 'POOL_GATEWAY_HOST=198.51.100.7\nREPAIR_NAME=Bad_Name\n' > "$MLP_GATEWAY_ENV_FILE"
if has_valid_gateway; then echo "HVG2:yes"; else echo "HVG2:no"; fi
: > "$MLP_GATEWAY_ENV_FILE"
if has_valid_gateway; then echo "HVG3:yes"; else echo "HVG3:no"; fi
BODY

run_src "$BODY_PORT" MLP_GATEWAY_ENV_FILE="$SANDBOX/gwenv-src2.env" \
    POOL_NODE_NAME=repair-test POOL_GATEWAY_PORT=2255 POOL_GATEWAY_USER=sshproxy \
    POOL_GATEWAY_SSH_PORT=2100 POOL_GATEWAY_HOST=gateway-ip-set-at-launch.invalid

if printf '%s' "$SRC_OUT" | grep -q '^MISSING:'; then
    for id in 8a 8b 8c 8d 8e; do bad "${id}. $(printf '%s' "$SRC_OUT" | grep '^MISSING:')——port 段／分類函式還不存在（預期紅）"; done
elif ! printf '%s' "$SRC_OUT" | grep -q '^GUARD_OK$'; then
    for id in 8a 8b 8c 8d 8e; do bad "${id}. source ${LAUNCH} 沒能安全返回——SRC_OUT=[${SRC_OUT}]"; done
else
    np1="$(printf '%s' "$SRC_OUT" | grep '^NP1:' | cut -d: -f2)"
    np2="$(printf '%s' "$SRC_OUT" | grep '^NP2:' | cut -d: -f2)"
    np3="$(printf '%s' "$SRC_OUT" | grep '^NP3:' | cut -d: -f2)"
    [[ "$np1" == "2401" ]] && ok "8a. next_port 段中間 +1（2400→${np1}）" || bad "8a. next_port(2400,2400,2499) got ${np1}，預期 2401"
    [[ "$np2" == "2400" ]] && ok "8b. next_port 到段尾繞回段首（2499→${np2}）" || bad "8b. next_port(2499,2400,2499) got ${np2}，預期 2400（繞回段首）"
    [[ "$np3" == "2451" ]] && ok "8b2. next_port 一般情形（2450→${np3}）" || bad "8b2. next_port(2450,2400,2499) got ${np3}，預期 2451"

    cf1="$(printf '%s' "$SRC_OUT" | grep '^CF1:' | cut -d: -f2)"
    cf2="$(printf '%s' "$SRC_OUT" | grep '^CF2:' | cut -d: -f2)"
    cf3="$(printf '%s' "$SRC_OUT" | grep '^CF3:' | cut -d: -f2)"
    [[ "$cf1" == "counted" ]] && ok "8c. Permission denied 分類為 counted（絕不換 port，D7 節奏）" || bad "8c. classify_dial_failure(Permission denied) got [${cf1}]，預期 counted"
    [[ "$cf2" == "forward" ]] && ok "8d. remote port forwarding failed 分類為 forward（換下一個 port）" || bad "8d. classify_dial_failure(remote port forwarding failed) got [${cf2}]，預期 forward（獨立於 counted／其他 not-counted）"
    [[ "$cf3" == "other" || "$cf3" == "not-counted" ]] && ok "8e. Connection refused 分類為其他 not-counted（不換 port，也不算次數）" || bad "8e. classify_dial_failure(Connection refused) got [${cf3}]，預期 other／not-counted 且不是 forward"

    hvg1="$(printf '%s' "$SRC_OUT" | grep '^HVG1:' | cut -d: -f2)"
    hvg2="$(printf '%s' "$SRC_OUT" | grep '^HVG2:' | cut -d: -f2)"
    hvg3="$(printf '%s' "$SRC_OUT" | grep '^HVG3:' | cut -d: -f2)"
    [[ "$hvg1" == "yes" ]] && ok "8f. has_valid_gateway：兩個值都合法 → true" || bad "8f. 兩個值都合法時 has_valid_gateway got [${hvg1}]"
    [[ "$hvg2" == "no" ]] && ok "8g. has_valid_gateway：名字格式不合法 → false" || bad "8g. 名字不合法時 has_valid_gateway got [${hvg2}]"
    [[ "$hvg3" == "no" ]] && ok "8h. has_valid_gateway：檔案是空的 → false" || bad "8h. 空檔時 has_valid_gateway got [${hvg3}]"
fi

# 8i：讀不到 port 段（環境裡沒有 POOL_GATEWAY_PORT_RANGE）→ 大聲拒絕、不撥號
# ——用全流程跑（不是 source），因為這是「一開機就該拒絕」的行為，不是單一函式
run_launch_loop "8i" $'POOL_GATEWAY_HOST=198.51.100.7\nREPAIR_NAME=mom-pc' NONE
if [[ "$RL_DIALS" -eq 0 ]]; then
    ok "8i. 沒有 POOL_GATEWAY_PORT_RANGE 時，即使 gateway.env 合法，也完全不撥號（大聲拒絕，fail-closed）"
else
    bad "8i. 沒有 POOL_GATEWAY_PORT_RANGE，但還是撥了 ${RL_DIALS} 次號——現碼還是單一 POOL_GATEWAY_PORT（環境裡的 2255），沒有段的概念、也沒有『讀不到就拒絕』這層（預期紅）"
fi
inj_skip "8. next_port／classify_dial_failure／has_valid_gateway／port 段拒絕 現碼都不存在，沒有原始碼可以動刀"

echo
echo "=== 9. Gateway 名牌（工單第 5 點） ==="
BODY_NAMETAG="$SANDBOX/body-nametag.sh"
cat > "$BODY_NAMETAG" <<'BODY'
missing=""
declare -F nametag_write >/dev/null 2>&1 || missing="${missing} nametag_write"
declare -F nametag_remove >/dev/null 2>&1 || missing="${missing} nametag_remove"
if [[ -n "$missing" ]]; then
    echo "MISSING:${missing}"
    exit 0
fi
echo "GUARD_OK"
nametag_write 2455 mom-pc 2>/dev/null
nametag_remove 2455 2>/dev/null
echo "DONE"
BODY

run_src "$BODY_NAMETAG" MLP_GATEWAY_ENV_FILE="$SANDBOX/gwenv-src3.env" \
    POOL_NODE_NAME=repair-test POOL_GATEWAY_PORT=2255 POOL_GATEWAY_USER=sshproxy \
    POOL_GATEWAY_SSH_PORT=2100 POOL_GATEWAY_HOST=198.51.100.7

if printf '%s' "$SRC_OUT" | grep -q '^MISSING:'; then
    for id in 9a 9b; do bad "${id}. $(printf '%s' "$SRC_OUT" | grep '^MISSING:')——名牌函式還不存在（預期紅）"; done
elif ! printf '%s' "$SRC_OUT" | grep -q '^GUARD_OK$'; then
    for id in 9a 9b; do bad "${id}. source ${LAUNCH} 沒能安全返回——SRC_OUT=[${SRC_OUT}]"; done
else
    write_line="$(grep -e '-S' "$SANDBOX/ssh-src.log" 2>/dev/null | grep '2455' | grep -v 'rm ' | tail -n 1)"
    remove_line="$(grep -e '-S' "$SANDBOX/ssh-src.log" 2>/dev/null | grep '2455' | grep 'rm ' | tail -n 1)"
    if [[ -n "$write_line" ]]; then
        ok "9a0. 正對照：假 ssh 收到針對 port 2455 的名牌寫入呼叫"
        if printf '%s' "$write_line" | grep -q '/home/sshproxy/repair/2455' && printf '%s' "$write_line" | grep -q 'mom-pc'; then
            ok "9a. 名牌寫入 /home/sshproxy/repair/2455，內容含名字 mom-pc，走同一條 ControlMaster（-S）"
        else
            bad "9a. 名牌寫入的路徑或內容不對（argv [${write_line}]）"
        fi
    else
        bad "9a0（正對照失敗）：假 ssh 沒收到名牌寫入呼叫——9a 不可信（SSH_LOG=[$(cat "$SANDBOX/ssh-src.log" 2>/dev/null)]）"
    fi
    if [[ -n "$remove_line" ]]; then
        ok "9b0. 正對照：假 ssh 收到針對 port 2455 的名牌刪除呼叫"
        printf '%s' "$remove_line" | grep -q '/home/sshproxy/repair/2455' && ok "9b. 名牌刪除指到對的路徑" \
            || bad "9b. 名牌刪除指令沒有指到 /home/sshproxy/repair/2455（argv [${remove_line}]）"
    else
        bad "9b0（正對照失敗）：假 ssh 沒收到名牌刪除呼叫——9b 不可信"
    fi
fi
inj_skip "9. nametag_write／nametag_remove 現碼不存在，沒有原始碼可以動刀；本節只驗這兩個函式單獨呼叫時組出的 ssh 遠端指令，不驗主迴圈在『接上／換 port／SIGTERM』三個時間點真的有呼叫它們（見檔頭限制）"

echo "=== 10. hostname 要用 sudo -n（真機發現 polkit 拒絕，見下方註解） ==="
# 真機（fh-l Windows 上的 VM）live 驗收發現：apply_repair_name 目前用
# 「$bin set-hostname $name」直接呼叫（bin 預設 hostnamectl，可用
# MLP_REPAIR_HOSTNAME_BIN 覆寫），跑在無 root 的 repair 帳號下會被 polkit
# 拒絕（"Interactive authentication required"），hostname 永遠不會被改。
# repair 帳號有 8b.4 決定的 NOPASSWD sudo，修法方向是改成
# `sudo -n "$bin" set-hostname "$name"`：-n 是非互動旗標，密碼要求會直接
# 失敗（exit 非 0）而不是掛住等輸入——這在無人值守的 systemd 服務裡是必要的
# （掛住＝隧道也起不來）。
#
# 本節的斷言不綁死「sudo」這個字面一定要出現在 apply_repair_name 的原始碼
# 裡（那是實作細節）；用一個放在 PATH 上、會記錄 argv 並且真的 exec 下去的
# 假 sudo（同 ssh/curl/sleep/hostnamectl 的慣例）來量「這個外部指令有沒有
# 被呼叫、有沒有帶 -n、有沒有真的把 hostnamectl 接下去」。這樣不管 impl
# 怎麼組裝這行呼叫，只要底層真的透過 `sudo -n ...` 執行，這裡就量得到。
BODY_HOSTNAME_SUDO="$SANDBOX/body-hostname-sudo.sh"
cat > "$BODY_HOSTNAME_SUDO" <<'BODY'
if ! declare -F apply_repair_name >/dev/null 2>&1; then
    echo "MISSING:apply_repair_name"
    exit 0
fi
echo "GUARD_OK"
printf 'POOL_GATEWAY_HOST=198.51.100.7\nREPAIR_NAME=mom-pc\n' > "$MLP_GATEWAY_ENV_FILE"
apply_repair_name "mom-pc" 2>/dev/null
echo "DONE"
BODY

: > "$SANDBOX/sudo-src.log"
run_src "$BODY_HOSTNAME_SUDO" MLP_GATEWAY_ENV_FILE="$SANDBOX/gwenv-src10.env" \
    SUDO_LOG="$SANDBOX/sudo-src.log" FAKE_SUDO_MODE=ok \
    POOL_NODE_NAME=repair-test POOL_GATEWAY_PORT=2255 POOL_GATEWAY_USER=sshproxy \
    POOL_GATEWAY_SSH_PORT=2100 POOL_GATEWAY_HOST=gateway-ip-set-at-launch.invalid

if printf '%s' "$SRC_OUT" | grep -q '^MISSING:'; then
    for id in 10a 10a0; do bad "${id}. $(printf '%s' "$SRC_OUT" | grep '^MISSING:')——apply_repair_name 不存在（預期紅）"; done
elif ! printf '%s' "$SRC_OUT" | grep -q '^GUARD_OK$'; then
    for id in 10a 10a0; do bad "${id}. source ${LAUNCH} 沒能安全返回——SRC_OUT=[${SRC_OUT}]"; done
else
    sudo_line="$(grep -i 'hostnamectl\|set-hostname' "$SANDBOX/sudo-src.log" 2>/dev/null | tail -n 1)"
    if [[ -n "$sudo_line" ]]; then
        ok "10a0. 正對照：假 sudo 真的被呼叫（argv 提到 hostnamectl／set-hostname）"
        if printf '%s' "$sudo_line" | grep -qE '^-n[[:space:]]' && printf '%s' "$sudo_line" | grep -q 'set-hostname mom-pc'; then
            ok "10a. hostname 是透過 sudo -n 執行（argv 開頭是 -n，帶 set-hostname mom-pc）"
        else
            bad "10a. sudo 有被呼叫，但沒有帶 -n，或參數不對（argv [${sudo_line}]）——真機上會卡在互動式密碼提示或用錯旗標"
        fi
        if grep -q 'set-hostname mom-pc' "$SANDBOX/hostnamectl-src.log" 2>/dev/null; then
            ok "10a1. sudo 真的把呼叫 exec 給底下的 hostnamectl（不是只記 log 沒放行）"
        else
            bad "10a1. 假 sudo 被叫到，但底下的 hostnamectl 沒有真的被 exec（log [$(cat "$SANDBOX/hostnamectl-src.log" 2>/dev/null)]）"
        fi
    else
        bad "10a0（正對照失敗）：假 sudo 完全沒被呼叫——現碼還是直接呼叫 hostnamectl，沒有經過 sudo（預期紅；真機上這就是「Interactive authentication required」的原因）"
    fi
fi

echo "--- 10b. sudo 失敗（非互動模式密碼要求）不能擋撥號 ---"
run_launch_loop "10b" $'POOL_GATEWAY_HOST=198.51.100.7\nREPAIR_NAME=mom-pc' 2400,2499 fail
if [[ "$RL_DIALS" -ge 1 ]]; then
    ok "10b. sudo -n 失敗（模擬密碼被要求、非互動模式直接拒絕）時，撥號照常進行（量到 ${RL_DIALS} 次）——hostname 設不設是裝飾性的，不能擋隧道"
else
    bad "10b. sudo 失敗時完全沒有撥號——hostname 失敗把隧道也一起卡住了（真機上會整台維修機連不上）"
fi
if grep -qi 'password is required\|sudo' "$SANDBOX/sudo-10b.log" 2>/dev/null; then
    ok "10b0. 正對照：假 sudo 在這一輪真的被呼叫且真的回報失敗"
else
    inj_skip "10b0. 現碼還沒有呼叫 sudo，這個正對照量不到（跟 10a0 紅是同一個原因）"
fi
inj_skip "10. apply_repair_name 目前沒有呼叫 sudo，沒有『拿掉 -n』或『拿掉 sudo』這種刀可以動；10a/10a0 對現碼的紅本身就是量測結果。10b 不管現碼有沒有 sudo 都應該綠（apply_repair_name 的回傳值本來就不擋撥號），這裡量到的是既有行為沒有因為這輪新斷言而被誤判。"

echo
printf 'passed %d / failed %d / injection-pass %d / injection-fail %d\n' \
    "$pass" "$fail" "$injpass" "$injfail"
[[ "$fail" -ne 0 ]] && exit 1
[[ "$injfail" -ne 0 ]] && exit 2
exit 0
