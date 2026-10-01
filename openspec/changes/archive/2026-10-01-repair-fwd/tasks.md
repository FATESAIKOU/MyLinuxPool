## 0. 開工前

- [x] 0.1 使用者裁示（2026-10-01）：只做 fwd；換 port／離線＝自然斷掉；做到 PR，等使用者看過再 merge；可用 mom-pc，可以 GET 路由器登入頁；隊員只用 Muse Spark／Space Bunny／DeepSeek
- [x] 0.2 review：唯讀調查 → `OUT-recon-fwd.md`；PM 依此定 D1–D4

## 1. 紅燈測試

- [x] 1.1 （`OUT-test-repair-fwd.md`：現碼 8 紅；落地後注入改成真護欄，含「D2 依賴 D1」的 inj7）test：`scripts/tests/test-mlp-fwd.sh` 加 repair 節——名字形式（argv 有 `-p <port>`、`repair@127.0.0.1`、`-L` 完整、`mlp-fwd-node=<名字>`）、段內 port 形式用 `repair`（現碼紅）、未設定段時裸數字仍是 worker、同名拒絕並列 port（現碼紅）、離線說明與未設定段警告（現碼紅）、選單有 repair 且選到的是 port（現碼紅）、`fwd ls` 不重新解析名字；每條附注入

## 2. 實作

- [x] 2.1 （`OUT-impl-repair-fwd.md`；`repair_port_p` 共用判斷）impl：D1 共用判斷、D2 選單、D3 訊息、usage 一句；`test-mlp-fwd.sh`、`test-mlp-repair.sh` 與全套綠

## 3. 驗收

- [x] 3.1 （`OUT-review-repair-fwd.md`：產品行為無必修，文件兩句與 usage 一行已修）review：獨立驗收（D1 的語意邊界、選單、訊息、`test-mlp-repair.sh` §4 不退化）
- [x] 3.2 （`OUT-impl-repair-fwd-live.md`：名字、port、選單三種都拿到路由器 200，`fwd ls`／`fwd rm` 正常、本機 port 收乾淨；fh-l 整夜不可達，「關掉後自然斷掉」由使用者 2026-10-01 早上親自驗過）真機（mom-pc）：`mlp fwd add mom-pc 8080:192.168.0.1:80` → `curl -I http://localhost:8080` 拿到路由器的回應（只 GET、不登入）；用 port 形式再做一次；`mlp fwd ls` 正常；關掉 mom-pc 的啟動器 → 轉發自然失效、`fwd ls` 顯示 down 或消失；`fwd rm` 收乾淨

## 4. 收尾

- [x] 4.1 文件：`docs/FWD-DESIGN.md` 參數表、`docs/REPAIR-HOST.md` §4 加 fwd 的例子
- [x] 4.2 commit、CI、PR #9；使用者驗過後要求整理並以 merge commit 合進 master（不 fast-forward）
