# 家人維修承載機（repair host）：操作手冊

這是什麼（一句話）：你在 Mac 上做一次設定、打**一份全家共用的包**；家人
在他自己的 Windows 上點兩下，一台 Ubuntu VM 就在 VirtualBox 裡開起來、
經反向隧道連回 Gateway（`2400–2499` 段裡現場挑一個空埠）；啟動時家人輸入
**名字與 IP**，你用 `mlp ls` 看到它、`mlp ssh <名字>` 登入，再從它碰到
家人家裡的區網（例如路由器管理頁面）。**家人那台電腦裡沒有任何 GitHub
權杖**——Mac 側也只放一把隧道私鑰，不放任何能動整座池的權杖。

規劃與契約在 `openspec/changes/family-repair-host/`
（proposal／`specs/repair-host/spec.md`／design／tasks）。
本文件只寫操作；為什麼這樣設計去看那裡。

> **本文件不含任何私鑰、權杖與 IP。** 範例裡的位址一律寫
> `<Gateway IP>`。repo 是公開的（tasks 8c），不要往這份文件裡填真的。
>
> **「待實作確認」**＝VM 端或 `mlp` 那半還沒落地，寫的是設計（design D9–D14
> 與 `EPHEMERAL-INTERFACE.md`），不是量過的行為。`mlp` 的輸出範例一律標
> 「示意」，不要當真。

## 1. 一次性設定：共用隧道金鑰

全家只做一次，在你的 Mac 上跑（repo 根目錄）。它會產生 ed25519 金鑰對、
把**公鑰**寫進 GitHub variable `REPAIR_TUNNEL_PUBKEY`，並觸發
`refresh-authorized-keys`、等到確認 Gateway 收下才算完：

```bash
bash ops-scripts/setup-repair-key
```

- 金鑰放在 `~/.config/mlp/repair-tunnel/`（`700`，`id_tunnel`＋`id_tunnel.pub`，
  私鑰 `600`）。**私鑰不離開這個目錄**：不進 repo、不進 log、不上傳。
- 已經設過再跑會**拒絕**（不覆蓋——蓋掉它等於讓全家已發的包同時失效）。
  真的要換鑰匙才加 `--rotate`（見 §6，代價是全家重裝）。
- 成功時它會印 refresh 成功。refresh 沒過的話先看 Actions 的訊息，
  不要直接把包發出去——包裡的鑰匙 Gateway 還不認，家人永遠連不上。

## 2. 打一份全家共用的包

同一份包給每一位家人（裡面**沒有任何每台不同的東西**：沒有名字、沒有
固定 port）。在你的 Mac 上跑：

```bash
bash ops-scripts/package-repair-host --key-dir ~/.config/mlp/repair-tunnel \
    --out <bundle 目錄> --image-sha256 <當日 SHA> --contact-name <家人怎麼稱呼你>
```

- `--image-sha256` **沒有預設值**：去
  `https://cloud-images.ubuntu.com/noble/current/SHA256SUMS`
  抄當日 `noble-server-cloudimg-amd64.vmdk` 那行的 hash（`current` 會動，
  寫死的 hash 會爛掉）。映像本身約 600MB，**不安裝包**——安裝當天在家人
  電腦上下載一次並驗 SHA。
- 打包時讀（不寫）：`CLIENT_*` 登入公鑰快照（`CLIENT_ACTIONS` 除外，它是跑
  workflow 的東西，不進家人網路）與 `NODE_GATEWAY` 的 SSH port 和
  `ports.repair` 段。讀不到就大聲拒絕，不會用寫死的值矇混。
- 包裡有什麼：`Install.cmd`（雙擊入口）、`Install-RepairHost.ps1`（首次安裝）、
  `Start-RepairLauncher.ps1`（之後每次）、`repair-config.json`（`vmName` 固定
  `mlp-repair-host`、port 段、Gateway SSH port、聯絡人、映像與 VirtualBox 的
  URL＋SHA——**無機密、無家人名字**）、開機資料（`user-data` 含共用隧道私鑰
  與 CLIENT 快照公鑰、`meta-data`、`seed.iso`）、`MANIFEST.sha256`、
  `README-FAMILY.txt`（給家人的四行）。
- **怎麼傳**：整包是祕密（開機資料裡有隧道私鑰）。用私下、端對端加密的管道
  傳；不要放公開連結、群組、轉發郵件。對方確認收到並裝好後，兩邊能刪就刪。

> **登入授權是打包當下的快照。** 包裡的登入公鑰＝當時所有 `CLIENT_*` 的公鑰。
> 之後新增／換掉 client（例如換手機），已發出去的包不會自己跟上——要重打
> 一份包（§6 的流程，不用換隧道金鑰）。

## 3. 家人端：照著念給他聽

先轉告三件事：全程只需要在「跳出詢問」時按是／輸入名字與 IP，不要自己開
VirtualBox；不要用「以系統管理員身分執行」；修好之前不要關機拔線。

**第一次**（解開包，點兩下 `Install.cmd`——**不是那個 `.ps1`**，直接點它只會打開編輯器，不會安裝）：

1. 跳出詢問按「是」（只問這一次，裝 VirtualBox＋建 VM 要管理員）。
2. 看到「安裝完成」就好（原來的黑視窗會停著等按任意鍵，叫他按一下關掉）。
   以後都在桌面點「維修連線」（**捷徑沒有名字**，全家同一份包同一個捷徑）。

**之後每次**（點桌面「維修連線」）：

1. 輸入**名字**與 IP（你事先跟他約好名字，例如 `dad-pc`：小寫英文開頭，
   後面小寫英文、數字或 `-`，1 到 32 個字；上次的值會先填好，直接確定也行），按確定。
2. 出現「維修連線中」的視窗就放著，看到綠色的「已連上維修通道」。
3. 修好或不想修時，**把這個視窗關掉就斷線了**。

**連不上的樣子**：等幾分鐘還是紅字「連不上，請向你索取新的 IP」——
叫他跟你要新的 IP（通常是你剛 rotate 完 Gateway，見 §5），拿到後關窗重開、
輸名字與新 IP。不是一直重試，重試不會自己變好。

## 4. 你怎麼連進去

家人那邊顯示已連上之後：

```bash
mlp ls             # 在 provider／worker 之外多一區 repair：名字／port／up（待實作確認）
mlp ssh <名字>     # 名字唯一時連上；同名多台時拒絕並列出 port，改用 mlp ssh <port>（待實作確認）
```

輸出示意（**示意**——`mlp` 那半還沒實作）：

```text
repair:
  dad-pc   2403   up
```

進去之後：登入的使用者是 `repair`，有**免密碼 sudo**（整台，
`sudo -i` 直接 root），能改網路設定、抓封包、連家人區網。登入用的金鑰是
你在 §2 打包時已登記的 `CLIENT_*` 之一（`~/.ssh/id_mlp` 若有登記就直接能用）。
VM 上沒有 GitHub 權杖（tunnel 啟動前有守衛擋），也沒有 `pool-sync`——它是
臨時跳板，不是一般 provider（`create-worker` 看不到它）。

> 待實作確認：`mlp` 掃描 Gateway 的做法（一次連線讀名牌＋listener）、同名判
> `?` 的顯示字樣，以落地為準。機制不變的是：走 Gateway 跳板進
> `127.0.0.1:<當次挑到的 port>`，登入 `repair`。

## 5. Gateway rotate 之後

Rotate 會換 Gateway 的 IP（主機金鑰也會換）。叢集側不用動，但兩件事要做：

1. **查新 IP**（二選一，都不碰祕密）：
   `gh variable get NODE_GATEWAY | jq -r .ip`，
   或 `mlp ssh-config | head`（第一行 `Gateway:` 後面那個）。
   你自己 Mac 的連線第一次會被擋（主機金鑰變了）→ 照訊息跑
   `mlp trust-gateway`（RUNBOOK §2，同樣的事）。
2. **把新 IP 告訴家人**。他下次點捷徑時輸名字與新 IP 即可（兩格都會記住
   上次的值）；若他正在連、看到紅色的「索取新的 IP」，就是在等你這串數字。

## 6. 換共用金鑰＝全家重裝

隧道金鑰只有一把，全家共用。換鑰匙的代價是**每一位家人都要重裝**（design
裁示，家人不多可接受）：

```bash
bash ops-scripts/setup-repair-key --key-dir ~/.config/mlp/repair-tunnel --rotate
# 等 refresh 成功，再照 §2 重打一份包
```

然後把新包交給**每一位**家人：已裝好的 VM 不用刪，把新包的開機資料換進去、
關窗重開即可（**待實作確認**：確切是換哪幾個檔、instance-id 怎麼帶，VM 工單
落地為準；舊世界是蓋 `seed.iso` 重開）。舊包在 refresh 成功後自動失效——
這正是撤銷的機制（見 §7）。

Mac 上的舊 bundle 刪掉（留著就是多一份私鑰拷貝）。

## 7. 撤掉某一位＝換金鑰

**沒有「只撤一位」的開關**（design 裁示）：任何一位的電腦不再可信（送人、
遺失、重灌），做法就是 §6 的換金鑰——舊鑰匙隨下一次 refresh 失效，那台 VM
從此連不上任何東西，其他家人換新包重開。

家人電腦上的移除（叫他做，或遠端指導；VM 先是關的）：

```powershell
VBoxManage unregistervm mlp-repair-host --delete-all
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\MyLinuxPool\repair-host"
```

桌面「維修連線」捷徑一併刪掉。

## 8. 同名與手機

- **同名怎麼辦**：名字是家人自己打的，沒有認證——兩台取同一個名字也能連上。
  `mlp ssh <名字>` 遇到同名會拒絕並列出 port，改用 `mlp ssh <port>` 直達
  （待實作確認）。連上後仍要你的金鑰才能登入，但**你可能登入到冒名的那台**，
  动手前先對一下家人那邊的狀態（design 已知風險）。
- **手機（MyAiEntry）看不到**：跳板不寫 `NODE_*`、不進 state 快取、不出現在
  MyAiEntry 讀的任何資料裡（design D14）。AI 不會把它列出來，也不會在上面
  執行指令——跟第一版（AI 看得到）不一樣。

## 9. 已知限制與風險

完整追蹤在 `openspec/changes/family-repair-host/`
（`known-limitations.md`；本節是操作側的版本，兩邊要對得上）：

- **共用隧道金鑰外洩影響全家**（使用者知情決定不收窄）：任何一位家人的電腦
  外洩，對方拿到 Gateway 上 `sshproxy` 的 shell，能冒充任何一位家人、佔住
  整段 port。包是祕密就是因為這把鑰匙——傳輸與保存按 §2 做，不要打折。
- **名字沒有認證可冒名**（見 §8）：包落到誰手裡，誰就能自稱任何名字；
  動手前先跟家人對狀態。
- **撤銷＝全家重裝**（見 §6、§7）：沒有單獨吊銷一台的辦法。
- **登入金鑰是快照**：新增／換掉 client 要重打包（§2）；沒有 CRL、沒有過期時間。
- **每次開機重新信任 Gateway 主機金鑰**（`accept-new`，沿舊）：rotate 完家人
  輸新 IP 的那一下理論上有窗口；登入仍要你的金鑰。
- **rotate 後要人工傳新 IP**（§5）；家人打錯 IP 只會一直紅，不會自己好。
- **家人區網若剛好是 `10.0.2.0/24`**，會撞 VirtualBox NAT 預設網段，
  連不到路由器——要改 VM 的 `--natnet1`（建完才發現的話，重裝前先講）。
- **家人電腦開著 Hyper-V**：VirtualBox 退到較慢模式，能跑但慢（安裝器只警告）。
- **D2 埠固定 `18080`**：被佔用就大聲拒絕，沒有備案（VM 只認這個埠）。
- **整包無簽名**：家人只能靠「收到的管道」信任它；`MANIFEST.sha256` 是給你
  複驗的，不是給家人的。
- **名牌是快取**：`mlp` 以 Gateway 上的實際 listener 為準（待實作確認）；
  非常態關機（斷電）可能留下名牌殘留，看到名字卻連不上時先叫家人重開一次。
- **`pool-status` 的 `2000–2999` 摘要行會列出跳板 port**：只有數字沒有名字，
  不報警（沿舊行為）。
