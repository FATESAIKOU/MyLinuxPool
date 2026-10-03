# `power.launch.via` 擴張成清單

> **2026-10-02 更新（D6）**：`via` 決定**順序**，`wol` 能力決定**資格**。
> `mlp wake` 只嘗試宣告了 `wol` 的代送方；被略過的照樣佔一個 `(n/m)` 序號、
> 不分走時間預算，並且會說明原因。四態與時間預算不變。細節見
> `CAPABILITY-DESIGN.md` §5 與 `spec.md`〈叫醒只交給有資格的代送方〉。

fh-l 的喚醒只有一條路：`NODE_FH_L.power.launch.via`（**已於 2026-09-25 翻成陣列**，
順序就是優先序；見 §1）。
那台第一順位代送者一關機，mlp 與手機 App **一起**失效——不是兩條路，是一條路兩個前端。

---

## 1. 形狀

`via` 接受**字串或陣列**，陣列的順序就是優先序：

```json
"via": "fh-proxy-asus"                        ← 舊形狀，繼續支援
"via": ["fh-proxy-asus", "fh-proxy"]          ← 新形狀
```

讀取端寬容是刻意的：主本翻不翻、什麼時候翻，與 mlp 的上線無關。
單一字串等價於只有一個元素的陣列，不另立程式碼路徑。

## 2. 上線順序與手機端（給 MyAiEntry 的 PM）

使用者**明確選擇了「mlp 做完就翻 var」**，並且知道代價：手機端會壞掉。

壞法是 MyAiEntry 那側的 PM 逐行查證後更正給我們的，本節照他們的結論重寫過
（初版寫的「回報指向一台不存在的節點」是錯的，那是我方的臆測）。我方另行
核對過 `~/testAI/MyAiEntry` 的三處，與他們所述一致：

- `src/port/pool/poolSnapshot.ts:74` 的守衛是 `typeof launch.via === 'string'`。
  陣列過不了，於是整個 `out.launch` 不會被寫進 snapshot——**資料在解析階段就被丟掉**。
- `src/port/pool/types.ts:130` 明訂「宣告不合法 → `undefined`，畫面上就不提供開機動作」。
- 所以症狀是 **fh-l 的開機按鈕直接消失**，不是按下去失敗，也沒有任何錯誤訊息。

這比一則誤導的訊息更難察覺：它不說謊，它什麼都不說。

要改的是解析層與型別，**不是呼叫層**——`powerOps` 收不到資料，只改它救不回來：

- `types.ts:118` 的 `via: string` → `string | string[]`
- `poolSnapshot.ts:71-77` 的守衛要接受兩種形狀
- 最小修正到此為止即可恢復今天的行為（取第一個元素）
- 完整修正再依序試，觸發條件見 §3——**不要用「送出成功」當判準**

不受影響的：`hops.via` 是另一個欄位（`poolSnapshot.ts:175-177` 有自己的驗證），
`device_list` 與 `device_exec` 照常。

var 已於 2026-09-25 翻成陣列，現值 `["fh-proxy-asus", "fh-proxy"]`。
手機端修不修、什麼時候修，由他們的使用者決定。

## 3. fallback 的觸發條件：fh-l 有沒有真的醒

**不是** `pool-wol` 的結束碼。

`pool-wol` 回 exit 0 只代表封包離開了送出端。這個 repo 有現成的反例：
RUNBOOK §4.1 記的那條 PowerShell 路徑**從來沒送出過任何封包**，
而它不會因此回非 0。用結束碼當判準，等於問了一個
**「壞掉時不會給出不同答案」的問題**——那正是這個 repo 反覆踩的坑。

判準只能是既有的那個輪詢迴圈：Gateway 上 fh-l 的埠有沒有變 up。

於是每個代送者有三種收場，處置各不同（回傳碼 `0`／`2`／`3`／`4`）：

| 收場 | 怎麼發現 | 處置 |
|---|---|---|
| 送不出去（代送者關機、沒裝 pool-wol、ssh 不通） | `run_on_node` 非 0 | **立刻**換下一台，不浪費等待預算 |
| 送出了但機器沒醒 | 等待預算用完仍未 up | 換下一台 |
| 送出了但無法驗證（Gateway master 打不開） | master 建連失敗 | 換下一台，記為 `unknown`，**不可說成沒醒** |

最後一列不能併入前一列：沒醒是我們**觀察到**的（看完整個預算，埠一直是 down），
無法驗證是我們**什麼都沒觀察到**。把後者說成前者，使用者會斷定代送者壞了、
或去重開一台其實可能已經醒了的機器——說錯的代價不對稱，所以不確定的事不說成沒發生。
這正是 fwd 目標探測分四態裡 `inconclusive` 與 `unreachable` 不合併的同一個理由
（FWD-DESIGN.md §4：一個是「我不知道」，一個是「我知道到不了」）。

MyAiEntry 那側有一個同源的狀態 `pool_unknown_result`，**判準相同但後果不同，
所以刻意不共用名字**。共用的是原則：不確定的事不說成沒發生。
分開的是政策——他們的 unknown 代表「不可重送、去讀狀態」，因為遠端指令可能已經執行；
我們的 unknown 代表「繼續試下一台」，因為 WoL 魔術封包是冪等的，多送一次沒有代價。
沿用他們的名字會把那條重送禁令一起帶進來，那在這裡是錯的。
（這個區分是他們的 PM 提醒的：名字要跟後果綁在一起，不是跟症狀。）

## 4. 等待預算

實測基準（2026-09-24，fh-proxy-asus 送、fh-l 收）：**50 秒**從送出到埠 up。

- 每台代送者 **90 秒**（50 秒加餘裕，涵蓋較慢的冷開機）
- **最後一台拿剩下的全部**，總預算維持現行的 300 秒
- 送不出去的代送者不計入預算（見 §3）

最後一台吃剩餘是刻意的：清單耗盡之後就沒有別的辦法了,
這時應該盡量等，而不是因為算術剛好用完而提早放棄。

## 5. 分層（沿用 `mlp fwd` 的規則）

- **Model**：回傳資料，一個字都不印
- **ViewModel**：決策與動作，不印字
- **View**：`printf`、顏色

`cmd_wake` 目前是三者混在一起。這次只抽出必要的部分：
`wake_senders <json>`（Model，回傳正規化後的代送者清單）與
`wake_try_sender`（ViewModel，送一台、等一台、回傳狀態碼）。
`cmd_wake` 保留為 View 加流程。**不順手重構其他部分。**

## 6. 輸出必須說得出「為什麼換人」

單點消除之後，最危險的狀態是「它一直在用第二順位，而你以為在用第一順位」。
所以每一次換人都要留下痕跡：

```
waking fh-l via fh-proxy-asus (1/2): unicast WoL to b4:2e:99:fb:63:5e @ 192.168.0.136 ...
  fh-proxy-asus: sent, but fh-l did not come up within 90s
waking fh-l via fh-proxy (2/2): ...
  fh-l is up (after 138s, via fh-proxy)
```

成功那一行要指名是誰叫醒的。全部失敗時要列出每一台的失敗原因，
不是只說「timed out」。有一台以上是 `unknown` 時，結尾不可說
`could not wake`（那是在宣稱沒醒），要說無法確認並提示自行驗證；
全數 `unknown` 時加註每一台都未驗證：

```
waking fh-l via fh-proxy-asus (1/2): unicast WoL to b4:2e:99:fb:63:5e @ 192.168.0.136 ...
  fh-proxy-asus: sent, but fh-l did not come up within 90s
waking fh-l via fh-proxy (2/2): ...
  fh-proxy: sent, but could not verify whether fh-l woke (gateway unreachable, cannot verify wake)
could not verify whether fh-l woke:
  fh-proxy-asus: sent, but did not come up within 90s
  fh-proxy: sent, but could not verify whether fh-l woke (gateway unreachable, cannot verify wake)
mlp: wake result unknown for fh-l — check 'mlp ls' to verify
```

## 7. 不做

- 自動把失效的代送者從清單移除
- 同時對所有代送者發送（會讓主路徑的靜默失效被第二台蓋住，永遠不被發現）
- 改動 `power.shutdown`（它沒有 `via`，直接 ssh 到節點自己）
- 記住上次哪一台成功（那會變成第二份真實來源）

## 8. 已知風險

- **清單耗盡時的總等待會變長。** 兩台就是 90 + 210 秒。這是消除單點的代價。

### 已解除（不再是風險）

- **`via` 指到節點自己** —— `wake_senders` 在進迴圈之前就把它濾掉（`ops-scripts/mlp` 的 `[[ "$s" == "$self" ]] && continue`）。**注意這是刻意的例外**：自我引用是靜靜濾掉的， 操作者不會看到提示，所以 D6「跳過要說明原因」的原則**不適用到它**。
- **手機端形狀不過** —— MyAiEntry 已收兩種形狀（`types.ts` 的 `via: string | string[]`、`poolSnapshot.ts` 兩形狀都收斂、`powerOps.ts` 分流）。

## 9. 任務拆分

### impl
1. `wake_senders`：`.power.launch.via` 吃字串或陣列，正規化成陣列；
   去重；剔除等於被喚醒節點自己的項目；空清單是錯誤；**只保留宣告了 `wol` 的**（D6）
2. `wake_try_sender`：送一台、等一台，回傳「送不出去／沒醒／醒了」三態
3. `cmd_wake` 改成走清單，輸出照 §6

### test
離線單元測試，假造 `pool-resolve` / `run_on_node` / 埠探測。注入必須包含：

| 注入 | 應該轉紅的斷言 |
|---|---|
| 觸發條件改回「送出結束碼」 | 送出成功但沒醒時不會換人 |
| 送不出去時仍耗掉整個等待預算 | 快速略過失效代送者 |
| 只吃陣列、不吃字串 | 舊形狀的 var 直接壞掉 |
| 最後一台不吃剩餘預算 | 總等待被算術提早截斷 |
| 成功訊息不指名代送者 | §6 的可觀測性 |

### qa
1. 獨立確認 `power.launch.via` 在 repo 內沒有第二個讀取點
2. `mlp wake` / `mlp down` / `mlp ls` 沒有回歸
3. 分層邊界成立
4. 全套測試與 `preflight` 全綠
