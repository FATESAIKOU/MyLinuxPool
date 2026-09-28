## 0. 開工前

- [x] 0.1 review：唯讀調查（隧道金鑰權限、靜態模式、register-provider 各步、既有假設、rotate、fail2ban、MyAiEntry 可見性、sshd 綁定）→ `OUT-issue6-recon.md`
- [x] 0.2 使用者裁示：金鑰不收窄、給 AI 看、NAT、首次安裝可以要 UAC
- [ ] 0.3 使用者 review 本 change（proposal／specs／design）。2026-09-28 使用者指示先在 `feat/family-repair-host` 分支開工，review 之後補
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
- [ ] 4.3 review：獨立驗收（`OUT-review-repair-t4.md`：實作過；測試側四項待補——§7 同名檢查假綠、Gateway 值無斷言、callsite 清單、parity 守衛 → 子代理以 test 角色補）；commit

## 5. VM 端（D5 的後半、D7、D8）

- [ ] 5.1 test：權杖守衛（有權杖檔或 `GH_*` 變數 → 不啟動）、重試節奏（連續被拒時 10 分鐘內的嘗試不到 5 次）
- [ ] 5.2 impl：維修承載機的 profile、unit、sshd 設定（只聽 loopback、只收金鑰）、cloud-init 範本
- [ ] 5.3 review：獨立驗收；commit

## 6. Windows 啟動器（D2 定案後）

- [ ] 6.1 impl：首次安裝腳本、啟動器（問並記住 IP、傳給 VM、無頭開機、狀態視窗、關視窗即關機、連不上時的訊息）、打包指令
- [ ] 6.2 test：能在 Mac 上做的靜態檢查與單元測試（PowerShell 語法、打包內容）
- [ ] 6.3 review：獨立驗收；commit

## 7. 文件

- [ ] 7.1 `docs/` 下一份操作文件：怎麼替一位家人登錄、怎麼打包交給他、rotate 後怎麼告訴家人新 IP、怎麼撤掉一台

## 8. 真機驗收

- [ ] 8.1 在 Mac 上登錄一台真的維修承載機（挑一個沒被佔用的 provider port）
- [ ] 8.2 在 Win10 上首次安裝、雙擊啟動、從 Gateway 登入 VM、從 VM 連到那個網路的路由器
- [ ] 8.3 從同一個區網的另一台裝置連 VM 的 22 port → 連不上
- [ ] 8.4 關掉狀態視窗 → VM 關機、Gateway 上那個 port 消失
- [ ] 8.5 `mlp ls`／`mlp state` 正常；指名它建 worker 被拒

## 9. 收尾

- [ ] 9.1 known-limitations.md（至少：隧道金鑰未收窄、AI 可見、rotate 後重輸 IP、登入金鑰難撤）
- [ ] 9.2 commit 本 change；是否 archive 由使用者決定
