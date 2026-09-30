# 家人維修承載機（repair host）：操作手冊

這是什麼（一句話）：家人在他自己的 Windows 上點兩下，一台 Ubuntu VM 就在
VirtualBox 裡開起來、經反向隧道連回 Gateway；你從 Gateway 登入那台 VM，
再從它碰到家人家裡的區網（例如路由器管理頁面）。**家人那台電腦裡沒有任何
GitHub 權杖**——登錄全部在你的 Mac 上完成，家人那邊不需要設定任何東西。

規劃與契約在 `openspec/changes/family-repair-host/`
（proposal／`specs/repair-host/spec.md`／design／tasks）。
本文件只寫操作；為什麼這樣設計去看那裡。

> **本文件不含任何私鑰、權杖與 IP。** 範例裡的位址一律寫
> `<Gateway IP>`。repo 是公開的（tasks 8c），不要往這份文件裡填真的。

## 1. 替一位家人登錄

在你的 Mac 上跑（repo 根目錄）。它會寫 GitHub variable 並觸發
`refresh-authorized-keys`、等到確認 Gateway 收下新金鑰才算完：

```bash
bash ops-scripts/register-repair-host --name <名字> --gateway-port <空埠> \
    --login-key ~/.ssh/id_mlp.pub --output-dir <seed 目錄>
```

| 參數 | 意思 |
|---|---|
| `--name` | 節點名，小寫 `[a-z0-9-]`（會變成 `NODE_<NAME>`；已存在就拒絕，不覆蓋） |
| `--gateway-port` | 它在 Gateway 上佔用的埠，provider 段 **2220–2299**，已被佔用就拒絕並點名佔用者 |
| `--login-key` | 你要拿來登入 VM 的**公鑰**。想讓 `mlp ssh <名字>` 直接能用，就給 `~/.ssh/id_mlp.pub`（見 §4；給錯成私鑰會被拒） |
| `--output-dir` | 開機資料（user-data／meta-data／seed.iso）輸出的**空目錄**；裡面會有隧道**私鑰**（三種形式），整包當祕密 |
| `--no-iso` | 只要 user-data／meta-data（**交給家人一定要 seed.iso，不要加這個**） |

先挑一個沒人用的埠（現況：`2222`、`2226`、`2230`、`2240` 已佔用；
撞了也沒關係，指令會拒絕並告訴你撞到誰，換一個再跑）：

```bash
for v in NODE_FH_L NODE_FH_PROXY NODE_FH_PROXY_ASUS NODE_FAM_TEST; do
    gh variable get "$v" 2>/dev/null | jq -r '"\(.name): \(.gateway_port)"'
done
```

成功時它會印 `refresh confirmed`。若結尾是 exit `3`
（`NODE_<NAME>` 與 seed 已寫、refresh 沒確認），在家人開機**之前**
手動跑一次 `refresh-authorized-keys` 並等它 success，否則隧道連不上。

> **登入授權是產生當下的快照。** 開機資料裡的登入公鑰＝你的 `--login-key`
> **加上當時所有 `CLIENT_*` 的公鑰**（`CLIENT_ACTIONS` 除外，它是跑
> workflow 的東西，PM 已裁定不進家人網路）。之後新增／換掉 client（例如換
> 手機），已發出去的 seed 不會自己跟上——要走 §6 重做。

> **輸出目錄就是祕密。** `id_tunnel`、user-data、`seed.iso` 三處都是同一把
> 隧道私鑰。打包完、家人裝好之後，從 Mac 上刪掉（留著就是多一份拷貝）。

## 2. 打包交給家人

⚠️ **一個包只給一台電腦。**同一個包裡的名字、port 與隧道金鑰是同一組；裝在兩台電腦上同時開的話，先連上的那台佔住 Gateway 的 port，另一台會一直重試，而 `mlp ssh <名字>` 連到哪一台由誰先連上決定，你無法指定。第二位家人（或同一位家人的第二台電腦）要另外跑一次 §1 的登錄，用不同的名字與 port。

```bash
bash ops-scripts/package-repair-host --name <名字> --seed-dir <上面的 seed 目錄> \
    --out <bundle 目錄> --image-sha256 <當日 SHA> --contact-name <家人怎麼稱呼你>
```

- `--image-sha256` **沒有預設值**：去
  `https://cloud-images.ubuntu.com/noble/current/SHA256SUMS`
  抄當日 `noble-server-cloudimg-amd64.vmdk` 那行的 hash（`current` 會動，
  寫死的 hash 會爛掉）。映像本身約 600MB，**不安裝包**——安裝當天在家人
  電腦上下載一次並驗 SHA（裝不起來的，見 §3 的失敗分支）。
- 包裡有什麼：`Install.cmd`（雙擊入口，家人點這個；直接點 `.ps1` 只會打開編輯器）、`Install-RepairHost.ps1`（首次安裝）、
  `Start-RepairLauncher.ps1`（之後每次）、`repair-config.json`（節點／VM 名、
  D2 埠、聯絡人、映像與 VirtualBox 的 URL＋SHA——**無機密**）、`seed/`
  （開機資料）、`MANIFEST.sha256`、`README-FAMILY.txt`（給家人的三行）。
- **怎麼傳**：整包是祕密（seed 裡有隧道私鑰）。用私下、端對端加密的管道
  傳；不要放公開連結、群組、轉發郵件。對方確認收到並裝好後，兩邊能刪就刪。

## 3. 家人端：照著念給他聽

先轉告三件事：全程只需要在「跳出詢問」時按是／輸入 IP，不要自己開
VirtualBox；不要用「以系統管理員身分執行」；修好之前不要關機拔線。

**第一次**（解開包，點兩下 `Install.cmd`——**不是那個 `.ps1`**，直接點它只會打開編輯器，不會安裝）：

1. 跳出詢問按「是」（只問這一次，裝 VirtualBox＋建 VM 要管理員）。
2. 看到「安裝完成」就好（原來的黑視窗會停著等按任意鍵，叫他按一下關掉）。以後都在桌面點「維修連線 (…)」。

**之後每次**（點桌面「維修連線 (…)」）：

1. 輸入你給他的 IP（上次的值會先填好，直接確定也行），按確定。
2. 出現「維修連線中」的視窗就放著，看到綠色的「已連上維修通道」。
3. 修好或不想修時，**把這個視窗關掉就斷線了**。

**連不上的樣子**：等幾分鐘還是紅字「連不上，請向你索取新的 IP」——
叫他跟你要新的 IP（通常是你剛 rotate 完 Gateway，見 §5），拿到後關窗重開、
輸入新 IP。不是一直重試，重試不會自己變好。

## 4. 你怎麼連進去

家人那邊顯示已連上之後：

```bash
mlp ssh <名字>        # 例如 mlp ssh fam-test
```

這條走的是 `mlp ssh-config` 的 `ProxyJump`（經 Gateway 到
`127.0.0.1:<gateway-port>`），金鑰固定用 `~/.ssh/id_mlp`。
**它能用的前提**：`~/.ssh/id_mlp.pub` 在 seed 裡——要麼登錄時
`--login-key` 就是給的它，要麼它是已登記的 `CLIENT_*` 之一（§1 的快照）。
都不是的話，這條會 `Permission denied`，改用：

```bash
ssh -J mlp-gateway -p <gateway-port> -i <seed 裡有的那把私鑰對應的公鑰那把> \
    -o IdentitiesOnly=yes repair@127.0.0.1
```

進去之後：`repair` 有**免密碼 sudo**（整台，`sudo -i` 直接 root；
sudoers 語法以真 `sudo` 驗過，見 tasks 8b.4），能改網路設定、抓封包、
連家人區網。VM 上沒有 GitHub 權杖（tunnel 啟動前有守衛擋；見 §7 的限制），
也沒有 `pool-sync`——它是靜態隧道承載機，不是一般 provider。

## 5. Gateway rotate 之後

Rotate 會換 Gateway 的 IP（主機金鑰也會換）。叢集側不用動，但兩件事要做：

1. **查新 IP**（二選一，都不碰祕密）：
   `gh variable get NODE_GATEWAY | jq -r .ip`，
   或 `mlp ssh-config | head`（第一行 `Gateway:` 後面那個）。
   你自己 Mac 的連線第一次會被擋（主機金鑰變了）→ 照訊息跑
   `mlp trust-gateway`（RUNBOOK §2，同樣的事）。
2. **把新 IP 告訴家人**。他下次點捷徑時輸入一次即可（啟動器記住上次的值）；
   若他正在連、看到紅色的「索取新的 IP」，就是在等你這串數字。

## 6. 新增／換掉 client（快照更新）

seed 是靜態檔，client 變動不會自動跟進。重做流程（隧道金鑰也會換掉，
舊包自動失效，正好當撤銷）：

```bash
gh variable delete NODE_<NAME 大寫底線>     # 先刪，登錄指令不覆蓋現役
bash ops-scripts/register-repair-host --name <同名> --gateway-port <同埠> \
    --login-key ~/.ssh/id_mlp.pub --output-dir <新 seed 目錄>
# 等 refresh confirmed，再照 §2 重新打包
```

家人側不用重裝：把新包裡的 `seed.iso` 蓋掉資料夾裡舊的
（`%LOCALAPPDATA%\MyLinuxPool\<名字>\seed.iso`），關窗重開。
VM 下次開機看到新的 instance-id 就會重跑整份開機設定。

## 7. 撤銷一台

池側（照 `OUT-live-repair.md` §8 走過的步驟）：

```bash
gh variable delete NODE_<NAME 大寫底線>
gh workflow run refresh-authorized-keys.yml --repo FATESAIKOU/MyLinuxPool
# 等它 success（它的 log 會寫 assembled N sshproxy key(s)，數字應少一把）
mlp ls    # <名字> 不見了
```

`mlp state` 若還報 `only in master: <名字>`，那是 Gateway 的 state 快取還沒
被壓回去（登錄時本來就沒推，見 tasks 8b.2）——下一次任一 workflow
（create／delete／rotate／repair）push 即消失；等不及就照 RUNBOOK §1.5
第 4 步手動壓一次。

家人電腦上（叫他做，或遠端指導；VM 先是關的）：

```powershell
VBoxManage unregistervm mlp-repair-<名字> --delete-all
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\MyLinuxPool\<名字>"
```

桌面捷徑一併刪掉。Mac 上的 seed 目錄與 bundle 也刪掉。
從此那把隧道私鑰連不上任何東西（refresh 已把它從 Gateway 拿掉）。

## 8. 已知限制與風險

完整追蹤在 `openspec/changes/family-repair-host/`（`tasks.md` §9.1 收
`known-limitations.md`；本節是操作側的版本，兩邊要對得上）：

- **隧道金鑰沒有收窄**（使用者知情決定，本輪不做）：外洩＝對方拿到 Gateway
  上 `sshproxy` 的 shell，也能監聽任意埠。seed 與 bundle 都是祕密就是因為
  這把鑰匙——傳輸與保存按 §2 做，不要打折。
- **AI 看得到這台**（使用者決定；MyAiEntry 會把它列成承載機）：AI 能在家
  人網路裡執行指令（且是帶 sudo 的 `repair`）。介意的話不要開這台。
- **每次開機重新信任 Gateway 主機金鑰**（`accept-new`，tasks 8b.5 維持現狀）：
  第一次連線時若有人冒充 Gateway，對方最多拿到一個指向 VM sshd 的轉發，
  登入仍要你的金鑰——但 rotate 完家人輸入新 IP 的那一下，理論上有這個窗口。
- **登入金鑰難撤**：只能重做 seed（§6）或登入後手改 `authorized_keys`；
  沒有 CRL、沒有過期時間。
- **rotate 後要人工傳新 IP**（§5）；家人打錯 IP 只會一直紅，不會自己好。
- **家人區網若剛好是 `10.0.2.0/24`**，會撞 VirtualBox NAT 預設網段，
  連不到路由器——要改 VM 的 `--natnet1`（建完才發現的話，重裝前先講）。
- **家人電腦開著 Hyper-V**：VirtualBox 退到較慢模式，能跑但慢（安裝器只警告）。
- **D2 埠固定 `18080`**：被佔用就大聲拒絕，沒有備案（VM 只認這個埠）。
- **整包無簽名**：家人只能靠「收到的管道」信任它；`MANIFEST.sha256` 是給你
  複驗的，不是給家人的。
- **不承載 worker 是機制**：`create-worker` 指名它會在 Validate 拒絕、
  零寫入（別拿它當跳板開容器）。
