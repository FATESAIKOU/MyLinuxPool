## 0. 開工前

- [x] 0.1 使用者裁示（2026-10-01）：只做 fwd；換 port／離線＝自然斷掉；做到 PR，等使用者看過再 merge；可用 mom-pc，可以 GET 路由器登入頁；隊員只用 Muse Spark／Space Bunny／DeepSeek
- [x] 0.2 review：唯讀調查 → `OUT-recon-fwd.md`；PM 依此定 D1–D4

## 1. 紅燈測試

- [ ] 1.1 test：`scripts/tests/test-mlp-fwd.sh` 加 repair 節——名字形式（argv 有 `-p <port>`、`repair@127.0.0.1`、`-L` 完整、`mlp-fwd-node=<名字>`）、段內 port 形式用 `repair`（現碼紅）、未設定段時裸數字仍是 worker、同名拒絕並列 port（現碼紅）、離線說明與未設定段警告（現碼紅）、選單有 repair 且選到的是 port（現碼紅）、`fwd ls` 不重新解析名字；每條附注入

## 2. 實作

- [ ] 2.1 impl：D1 共用判斷、D2 選單、D3 訊息、usage 一句；`test-mlp-fwd.sh`、`test-mlp-repair.sh` 與全套綠

## 3. 驗收

- [ ] 3.1 review：獨立驗收（D1 的語意邊界、選單、訊息、`test-mlp-repair.sh` §4 不退化）
- [ ] 3.2 真機（mom-pc）：`mlp fwd add mom-pc 8080:192.168.0.1:80` → `curl -I http://localhost:8080` 拿到路由器的回應（只 GET、不登入）；用 port 形式再做一次；`mlp fwd ls` 正常；關掉 mom-pc 的啟動器 → 轉發自然失效、`fwd ls` 顯示 down 或消失；`fwd rm` 收乾淨

## 4. 收尾

- [ ] 4.1 文件：`docs/FWD-DESIGN.md` 參數表、`docs/REPAIR-HOST.md` §4 加 fwd 的例子
- [ ] 4.2 commit、CI、開 PR；**等使用者早上看過再 merge**；archive 由使用者決定
