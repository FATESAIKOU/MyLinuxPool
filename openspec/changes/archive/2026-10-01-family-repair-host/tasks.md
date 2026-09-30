## 0. 開工前

- [x] 0.1 review：唯讀調查（隧道金鑰權限、靜態模式、register-provider 各步、既有假設、rotate、fail2ban、MyAiEntry 可見性、sshd 綁定）→ `OUT-issue6-recon.md`
- [x] 0.2 使用者裁示：金鑰不收窄、給 AI 看、NAT、首次安裝可以要 UAC
- [x] 0.3 （2026-10-01 使用者驗收後同意封關）使用者 review 本 change（proposal／specs／design）。2026-09-28 使用者指示先在 `feat/family-repair-host` 分支開工，review 之後補
- [x] 0.4 測試機：fh-l 開在 Windows（**實為 Windows 11** 10.0.26200，VirtualBox 7.2.20，無 Hyper-V），PM 從 Mac 經區網 192.168.0.136:2022 連入（22 被 VMware 的 vmnat 佔用）

## 1. 可行性 spike（不改 repo）

- [x] 1.1 impl（Claude 子代理，`OUT-spike-repair.md`）：可行。Ubuntu cloud image（amd64）只靠 NoCloud 開機資料、不從網路裝套件，就能跑起 `pool-tunnel` 靜態模式的 unit。先在 Mac 上用 QEMU 驗 cloud-init 的內容（arm64 原生或 amd64 模擬）
- [x] 1.2 impl（同上，在 fh-l 的 Win11 上）：D2 三種都實測可行，選 (c) HTTP 經 10.0.2.2；非系統管理員跑 VBoxManage 未證（要在桌面 session 驗）
- [x] 1.3 PM：依 spike 結果更新 design.md 的 D1／D2 與 Risks（給使用者看）

## 2. pool-tunnel 靜態模式的 SSH port（D3）

- [x] 2.1 test（`test-pool-tunnel-static-port.sh`，現碼紅 1b／1c／4）：行為測試：靜態模式帶 port → ssh 用那個 port；不帶 → 維持 22（對現碼紅在第一條）
- [x] 2.2 impl（haiku 子代理；報告不可信，由 review 獨立驗收）：加選填環境變數
- [x] 2.3 review：獨立驗收（`OUT-review-repair-t2t3.md`，找到前導零／超大數字與測試缺口 → 已修並補測試）；commit

## 3. create-worker 的 capability 閘門（D6）

- [x] 3.1 PM：確認三台現役 provider 都宣告了 `worker-host`（唯讀，2026-09-28：fh-l、fh-proxy、fh-proxy-asus 皆有）
- [x] 3.2 test（`test-create-worker-capability-gate.sh`，現碼紅 2a／2b／3；實作時要一起更新 `test-provider-validation.sh` 的 fixture）：指名沒有 `worker-host` 的 provider → 在寫入任何狀態之前失敗（對現碼紅）
- [x] 3.3 impl（haiku 子代理）；3.4 review（讀取失敗時訊息誤導、jq 1.7 語法 → 已修）；commit

## 4. Mac 端登錄（D4、D5 的前半）

- [x] 4.1 test（`test-register-repair-host.sh`，定義介面 `--name/--gateway-port/--login-key/--output-dir`；兩種丟棄式實作皆 20/0）：登錄指令的行為測試（寫出的 `NODE_<NAME>` 形狀、port 衝突拒絕、開機資料不含權杖、含權杖的輸入被拒）
- [x] 4.2 impl（子代理，`OUT-impl-repair-t4.md`）：新登錄指令；開機資料產生器（模板在 `profiles/provider/repair/`）。**共用函式沒抽**（register-provider 是單檔執行，抽出會打壞兩支既有測試），改用 parity 比對；待補：refresh-wait 呼叫端清單、fixture 補 NODE_GATEWAY
- [x] 4.3 review：獨立驗收（`OUT-review-repair-t4.md`：實作過；測試側四項待補——§7 同名檢查假綠、Gateway 值無斷言、callsite 清單、parity 守衛 → 子代理以 test 角色補）；commit

## 5. VM 端（D5 的後半、D7、D8）

- [x] 5.1 test（DeepSeek 兩輪無產出 → sonnet 子代理接手；`test-repair-host-vm.sh`，現碼紅 12 條、檔頭定義四支腳本與兩個 unit 的介面）：權杖守衛（有權杖檔或 `GH_*` 變數 → 不啟動）、重試節奏（連續被拒時 10 分鐘內的嘗試不到 5 次）
- [x] 5.2 impl（Claude 子代理，`OUT-impl-repair-t5.md`）：四支 VM 端腳本、兩個 system unit、開機資料自帶 pool-tunnel；缺嵌入檔時打包直接拒絕
- [x] 5.3 review（`OUT-review-repair-t5.md`，含真 cloud-init 容器驗 defer 與 runcmd 順序）：defer 斷言弱點已修；commit

## 6. Windows 啟動器（D2 定案後）

- [x] 6.1 impl（`cecefca`；Muse Spark，`OUT-impl-repair-launcher.md`；review 找到首次安裝死在第一筆 log、健康連線被顯示成連不上等 → 修正中）：首次安裝腳本、啟動器（問並記住 IP、傳給 VM、無頭開機、狀態視窗、關視窗即關機、連不上時的訊息）、打包指令
- [x] 6.2 （PowerShell 語法每批在 fh-l 以 Parser 驗；打包內容由 `test-package-repair-host.sh` 覆蓋）test：能在 Mac 上做的靜態檢查與單元測試（PowerShell 語法、打包內容）
- [x] 6.3 review（`OUT-review-repair-launcher.md`、`OUT-review-repair-launcher-2.md`：六項修好、Win11 抽驗連上真 Gateway）；**桌面驗收待使用者**

## 7. 文件

- [x] 7.1 （`9e9a5a5`，`docs/REPAIR-HOST.md`）`docs/` 下一份操作文件：怎麼替一位家人登錄、怎麼打包交給他、rotate 後怎麼告訴家人新 IP、怎麼撤掉一台

## 8. 真機驗收

- [x] 8.1 登錄 `fam-test`（NODE_FAM_TEST，埠 2240），refresh run 36465401724 成功（`OUT-live-repair.md`）
- [x] 8.2 在 fh-l 的 **Win11** 上以 VirtualBox 開 VM（啟動器以臨時 PowerShell 服務模擬），約 21 秒 tunnel=up；從 Mac 經 Gateway 登入 VM；VM 連 192.168.0.1 回 200。**未驗**：桌面 session、真啟動器、雙擊、Win10
- [x] 8.3 從同一區網的 Mac 連不到 VM 的 sshd
- [x] 8.4 （第一版；新版的關視窗即關機與名牌清除見 10.7）以 acpipowerbutton 關機 → 6 秒內關機、回報 tunnel=down、Gateway 上 2240 消失（「關視窗即關機」要等啟動器）
- [x] 8.5 （第一版；`only in master` 在改版後不再發生）`mlp ls` up ✓；分支上的 create-worker 在 Validate inputs 拒絕 fam-test、零寫入 ✓；**`mlp state` 報 only in master: fam-test**（登錄時沒推 state 快取）✗

## 8b. 真機驗收找到的問題（待使用者裁決）

- [x] 8b.1 （`140d4a1`；使用者 09-29：產生開機資料時把 CLIENT_* 公鑰快照放進去，不自動更新。實作＋review 過；補強中：非 JSON 值略過、**排除 CLIENT_ACTIONS**（PM 裁定，最小權限））VM 只信任專用登入金鑰 → `mlp ssh fam-test`（用 `~/.ssh/id_mlp`）與 MyAiEntry（AI）都登不進：要不要把使用者已登錄的 client 公鑰（CLIENT_*）也放進 VM
- [x] 8b.2 （改版後不再寫 NODE_*，問題消失）登錄後 `mlp state` 不一致：登錄指令要不要順便推 state 快取
- [x] 8b.3 （`cecefca`，資料夾只剩使用者＋SYSTEM）Windows 上 seed.iso 權限繼承 `C:\`（本機任何使用者讀得到隧道私鑰）→ 啟動器安裝時鎖資料夾權限（併入 6.1）
- [x] 8b.4 （使用者 09-29：給免密碼 sudo；實作＋review 過，真 sudo 1.9.15 驗 visudo）`repair` 帳號沒有 root（sudo 要密碼、密碼鎖住）：要不要給 NOPASSWD sudo（AI 也會拿到）
- [x] 8b.5 （PM 預設維持現狀，使用者可推翻）Gateway host key：目前每次開機清 known_hosts（每次 accept-new）；要不要「先釘、不符退回」

## 8d. 新開機資料的真機驗證（2026-09-30，`OUT-live-clientkeys.md`）

- [x] 8d.1 撤掉舊 fam-test、以新版重新登錄（NODE_FAM_TEST、2240）、新打包在 Win11 從頭安裝
- [x] 8d.2 `mlp ssh fam-test` 用使用者平常的金鑰登入成功；免密碼 sudo；VM 內無權杖；CLIENT_ACTIONS 不在授權清單
- [x] 8d.3 （`bd4e1bf`，`Install.cmd`）**雙擊 `.ps1` 在真的 Windows 上不會執行**（預設用商店 App 打開、執行原則 Restricted）→ 包裡加 `.cmd` 入口（impl 修正中）

## 8c. repo 改成公開（2026-09-30）之後

- [x] 8c.1 稽核（`OUT-public-key-audit.md`）：歷史 6 份加密公鑰中 4 份連現行金鑰都解不開；解得開的 2 把舊 RSA 不在任何現行授權清單，實際撥號 `Permission denied`；現行清單 0 把 ssh-rsa → **不需撤銷**。缺口：fh-l（開在 Windows）的 Linux 側未查。review 為活體測試解了兩把舊私鑰（超出工單、已自行揭露、已刪）
- [x] 8c.2 （`174c30b`；review 過，唯一漏抓是跨行引號 run:、repo 內 0 處）修 master 既有的兩個測試缺陷（`must_green()` 紅不了、審計誤判描述文字；使用者：在本分支一起修）
- [x] 8c.3 RUNBOOK 的家用 IP：使用者決定不處理

## 9. 收尾

- [x] 9.1 known-limitations.md（2026-09-30）（至少：隧道金鑰未收窄、AI 可見、rotate 後重輸 IP、登入金鑰難撤）
- [x] 9.2 （使用者 2026-10-01：開 PR merge、archive）commit 本 change；**merge 等使用者在桌面點兩下驗完**；是否 archive 由使用者決定

## 10. 改版：臨時跳板（2026-09-30，design D9–D14；第一版不 merge）

- [x] 10.0 review：唯讀調查（`OUT-recon-ephemeral.md`）；PM 定案 D10／D11 的細節
- [x] 10.1 （`4664e92`；review `OUT-review-ephemeral-mac.md` 無必修）共用金鑰進 Gateway：test（refresh／rotate 共用組裝函式收 `REPAIR_TUNNEL_PUBKEY`）→ impl → review
- [x] 10.2 （`4664e92`；`--rotate` 先寫 var 成功才取代舊鑰）Mac 端：`setup-repair-key`（產生／更換共用金鑰、寫 var、refresh）取代 `register-repair-host`；`package-repair-host` 改成全家共用一份包；拆掉舊指令、舊測試與各清單裡的登記：test → impl → review
- [x] 10.3 （`4664e92`；測試由 Claude 子代理寫——DeepSeek 三輪無產出；review `OUT-review-ephemeral-vm.md` 無必修）VM 端：從啟動器拿名字、設 hostname、在段內挑 port、在 Gateway 上寫／刪名牌；forward 失敗換 port、認證失敗不換的測試：test → impl → review
- [x] 10.4 （`7274745`；review 無必修，桌面 GUI 待使用者）Windows 啟動器：名字跟 IP 一起問並記住、經 D2 傳給 VM、捷徑與 VM 名改成通用：impl → review（在 fh-l 用測試位置驗）
- [x] 10.5 （`c6c94ef`；測試與實作皆 Claude 子代理；review 抓到名牌內容可決定 port → 改成 port 只取 listener、名牌整行合格式才算數，二次 review 無必修）`mlp`：掃描跳板、`ls` 分區、`ssh <名字>`／`ssh <port>`、同名拒絕：test → impl → review
- [x] 10.6 文件（`NODE_GATEWAY.ports.repair` 的真值在 10.7 寫入）：ARCHITECTURE、LAYOUT、README、`docs/REPAIR-HOST.md`、known-limitations、proposal
- [x] 10.7 （`OUT-live-ephemeral.md`、`OUT-impl-live-fixes.md`、`OUT-impl-smoke-no-oldkey.md`；真機找到三個問題 → `5a9be1b`；重裝 → `87d2b64`；fam-test 已撤）真機：設定共用金鑰、新包裝到 fh-l、`mlp ls` 看得到名字、佔住 2400 時改用 2401、關視窗後消失、手機看不到；通過後撤掉 `fam-test`
- [x] 10.8 （使用者在 fh-l 桌面驗收通過；畫面意見 → `88a5f74`：repair 併入主表、ssh 選單列出）使用者桌面驗收 → merge
