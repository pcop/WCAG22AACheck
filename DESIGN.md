# wcag22-check 設計文件

使用方式見 [README.md](README.md)。本文件說明架構、各項檢查的判定演算法、資料結構、取捨與擴充方式，供維護者修改時參考。

## 1. 目標與範圍

| 目標 | 說明 |
|:---|:---|
| 一行指令產出 AA 檢核結果 | 只要給網址，就能拿到可以交付的報告 |
| 逐條對應 WCAG 2.2 | 55 項 A／AA 準則每一項都要有明確狀態，不能只列 axe 的規則 ID |
| 補足 axe 的盲點 | axe 只分析靜態 DOM。焦點可見、焦點遮蔽、鍵盤陷阱、重排、文字間距、3.3.8 都需要實際操作或比對前後狀態 |
| 誠實標示自動化的極限 | 區分「不符合／需確認／未發現問題／僅能人工」，不讓「沒發現」被誤讀成「符合」 |
| 不汙染專案 | 不寫入專案目錄（輸出目錄除外），不要求 npm 專案 |

**不在範圍內**：AAA 準則、登入後頁面、互動流程（表單送出、對話框）、跨瀏覽器、PDF 文件檢查。

## 2. 架構

```
wcag22-check.sh  (Bash)
 ├─ 解析參數、驗證輸入
 ├─ 檢查 Node.js ≥ 18、尋找 Chrome
 ├─ 確保相依套件  →  $WCAG_CHECK_HOME/node_modules
 ├─ 以 heredoc 寫出 runner.js  →  $WCAG_CHECK_HOME/runner.js（每次覆寫）
 └─ 以環境變數 WCAG_* 傳參數，執行 node runner.js，轉傳 exit code

runner.js  (Node.js)
 ├─ puppeteer-core 啟動 headless Chrome（單一分頁，循序處理）
 ├─ 逐頁執行檢查 → findings[]
 ├─ 彙整、對應 55 項準則 → summary[]
 └─ 寫出 wcag-result.json、wcag-report.md、wcag-report.html
```

### 設計決策

| 決策 | 理由 | 代價 |
|:---|:---|:---|
| 單一 Bash 檔案，內嵌 JS | 只需要複製一個檔案；Bash 負責環境檢查與錯誤訊息，JS 負責瀏覽器操作 | heredoc 內的 JS 沒有編輯器語法支援。修改後可以用 §9 的指令抽出來做 `node --check` |
| heredoc 使用 `<<'JS'`（引號） | 避免 Bash 展開 JS 裡的 `$`、反引號 | 參數只能透過環境變數傳入 |
| 參數以環境變數傳遞 | 不必處理 argv 跳脫；`-u` 多值用換行分隔 | — |
| 套件裝在 `~/.cache` | 不影響專案（本專案規定前端不用 npm），多個專案可以共用 | 第一次執行要連網；版本沒有鎖定（見 §8） |
| `puppeteer-core` 搭配系統 Chrome | 不下載約 150 MB 的內建 Chromium | 需要自行安裝 Chrome |
| `setBypassCSP(true)` | 目標網站（本專案）的 CSP 不允許 eval 與外部 script，axe 注入會被擋 | 檢測時的 CSP 環境和真實環境不同。CSP 本身不是 WCAG 的檢查項目 |
| `evaluateOnNewDocument(installHelpers)` | 共用工具函式掛在 `window.__wcag`，每次導覽都自動安裝 | — |
| 單一分頁循序處理 | 鍵盤走訪需要分頁位於前景與真實焦點；並行會互相搶焦點 | 每頁約 15 秒，15 頁約 4 分鐘 |
| 自動關閉 `alert`、`confirm` | 避免頁面的 SweetAlert 以外的原生對話框卡住流程 | — |

## 3. 每頁的處理流程

```
桌機 1366×900
  1. goto（networkidle2；逾時不中斷）＋等待 1.2 秒
     └─ Content-Type 不是 HTML → 標記 skipped，換下一頁
  2. 只在第一頁：收集連結加入佇列（§4）
  3. axe 掃描（並在第一次時計算 axe 涵蓋的準則）
  4. 表單檢查：autocomplete、驗證碼、阻擋貼上
  5. 滑鼠限定元素
  6. 鍵盤走訪（最多 --tabs 次）
  7. 重新載入 → 記錄已被裁切的元素 → 注入文字間距 CSS → 找出新增被裁切的元素
窄版 320×640
  8. 重新載入 → 重排檢查
  9. 尋找漢堡選單按鈕並點擊 → 判斷是否展開
 10. axe 掃描（選單展開時會一起掃到選單內容）
```

第 7、8 步重新載入，是為了避免前面的鍵盤走訪改變頁面狀態（捲動位置、展開的元件）。

單頁發生例外時，記錄在 `pages[].error`，繼續下一頁。頁數上限以「實際完成檢測的頁數」計算（`testedCount()`），所以略過和錯誤的頁面不會占用名額。

## 4. 爬取

- 只在第一頁收集 `a[href]`，深度固定為 1。登入前的網站通常導覽列就能涵蓋主要頁面，深度 1 比較好預測執行時間，也比較不會誤觸危險連結。
- 篩選順序：協定與來源 → 下載副檔名 → `--exclude`（比對網址和連結文字）→ `undefined/null/NaN` 片段。
- `normUrl()` 會去掉 `#hash` 與 `_wcag` 再去重。`--bust` 只在 `goto` 時由 `bustUrl()` 加上參數，報告上顯示的網址不含這個參數。

## 5. 檢查項目演算法

### 5.1 axe-core

- 標籤：`wcag2a, wcag2aa, wcag21a, wcag21aa, wcag22a, wcag22aa`；語系使用 `axe-core/locales/zh_TW.json`（找不到時改用英文）。
- 每條規則的 `tags`（例如 `wcag143`）由 `scFromTag()` 轉成準則編號 `1.4.3`。同一條規則對應多項準則時，每項準則各產生一筆 finding。
- `violations` 記為 fail，`incomplete` 記為 review。每筆最多保留 10 個節點，`count` 是實際節點數。
- **涵蓋計算**：第一頁執行 `axe.getRules(AXE_TAGS)`，把所有規則的準則加入 `axeCovered`，再和 `CUSTOM_COVER` 合併。合併後的集合決定沒有 finding 的準則是 `pass` 還是 `manual`。

### 5.2 表單（`checkForms`）

| 項目 | 判定 |
|:---|:---|
| 密碼欄 autocomplete | `type=password` 且 `autocomplete` 沒設定、為 `off` 或 `on` → **fail** |
| 個人資料欄 autocomplete | text、email、tel 欄位，標籤、placeholder、name、id 符合帳號、Email、姓名、電話、地址等關鍵字，且不符合驗證碼、搜尋類關鍵字，autocomplete 也沒有設定 → review（關鍵字比對可能誤判，所以不判 fail） |
| 驗證碼 | img、iframe、input、canvas、audio 的 src、id、class、alt 等屬性含 captcha、驗證碼、recaptcha、hcaptcha、turnstile；div 只認第三方驗證碼的容器 class → review |
| 阻擋貼上 | `onpaste` 屬性含 `return false` 或 `preventDefault`。只看得到 inline 屬性，看不到 addEventListener 註冊的事件 |
| 驗證頁判定 | 頁面有密碼欄，或網址、標題含 login、password、登入、密碼、驗證 → 阻擋貼上升級為 fail，驗證碼訊息改用 3.3.8 的措辭 |

驗證碼只列為 review、不判 fail，原因是 3.3.8 允許「提供替代方式」與「辨識物件」等例外，工具無法判斷。注意：音訊驗證碼不算替代方式，訊息裡已經寫明。

### 5.3 滑鼠限定元素（`checkPointerOnly`）

篩選條件：`cursor: pointer`、可見、本身不可聚焦、沒有可聚焦的祖先，也沒有可聚焦的子孫。`cursor` 會繼承，所以只保留最外層的候選元素（父元素不在候選集合裡）。最多 30 個。

這是啟發式判斷：CSS 誤設了 pointer 也會被抓到，而且看不到元素是否綁了 click 事件（puppeteer 的 `getEventListeners` 需要 CDP，目前沒用），因此只列為 review。

### 5.4 鍵盤走訪（`keyboardWalk` + `measureFocus`）

開始前先 blur、捲回頂端，接著重複「按 Tab → `waitSettle` → 量測」：

- **`waitSettle`**：輪詢 `scrollX/Y` 和焦點元素位置，連續兩次相同才算穩定（最多 15 次 × 80 毫秒），再等 150 毫秒讓焦點樣式的轉場跑完。以前在平滑捲動途中量測，曾把元素誤判為「完全遮蔽」，所以加了這一步。
- **結束條件**：焦點回到 body（而且之前已聚焦過元素）、回到第一個元素（繞完一圈），或達到 `--tabs` 次數。
- **識別元素**：`sig = 選擇器@文件座標`，用來分辨同一選擇器的不同元素。

**焦點可見（2.4.7）**

1. outline 樣式不是 none、寬度大於 0、顏色不透明 → 有焦點指示。
2. 否則，對元素本身與前 8 個子孫，擷取 outline、box-shadow、border、background、color、text-decoration、filter、transform、opacity，以及 `::before`、`::after` 的樣式，分別在聚焦和 `blur()` 後各取一次快照。取快照前先把 `transition` 設為 none，否則讀到的會是轉場中的值。量完後重新 `focus({preventScroll:true})`。
3. 兩次快照有任何差異就算有指示；完全相同就判 **fail**。
4. 寬或高 ≤ 2px 的元素（自訂核取方塊隱藏的原生 input 這類）改記為 review，因為焦點樣式通常畫在相鄰的元素上。

限制：只判斷有沒有變化，不判斷變化是否明顯。焦點外框的對比屬於 1.4.11 的人工檢查範圍。

**焦點遮蔽（2.4.11）**

- 取元素中心點與四個角往內縮的點（15%／85%、20%／80%），只取落在視窗內的點，用 `elementFromPoint` 找出最上層的元素。
- 最上層元素不是焦點元素本身、它的子孫或祖先時，往上追溯：只要有 `position: fixed/sticky` 的祖先，就算這個點被遮住。
- **所有點**都被遮住 → fail。2.4.11（AA）只要求「不能完全遮蔽」，部分遮蔽屬於 2.4.12（AAA）。
- 元素在視窗外 → 記為 `focus-offscreen` review（瀏覽器通常會自動捲動，仍在畫面外表示捲動被攔截或元素位置異常）。

**鍵盤陷阱（2.1.2）**：連續 4 次 Tab 的 `sig` 都相同 → fail。iframe 例外，因為焦點進入 iframe 內部時，外層看到的 activeElement 一直都是 iframe。

### 5.5 文字間距（1.4.12）

1. 重新載入，收集「可見、有文字、`overflow-x/y` 為 hidden 或 clip，而且 scroll 尺寸大於 client 尺寸 2px 以上」的元素作為基準。原本就被裁切的元素，例如刻意設計的省略號，不列入結果。
2. 注入 `line-height:1.5; letter-spacing:.12em; word-spacing:.16em; p{margin-bottom:2em}`（全部 `!important`）。
3. 再收集一次，扣掉基準後剩下的元素就是新增被裁切的元素 → review。
4. 限制：只抓得到被 overflow 裁切的情況。overflow 可見但文字互相重疊、或溢出到其他元素上的情況抓不到，需要人工目視檢查。

### 5.6 重排（1.4.10）

- 320×640 下，`scrollWidth > clientWidth + 1` 就是溢出。
- **找出溢出來源**：收集右緣超過視窗的可見元素，以及寬度超出的文字節點（用 Range 量測，抓得到元素寬度正常但長字串沒有斷行的情況）。排除「已經被可捲動或會裁切的祖先容器包住」的元素，因為那種情況只有容器內部捲動，不會讓整頁水平捲動。最後只保留最外層的元素。
- 來源是 `table` 或位在 table 裡面 → 記為 `reflow-table` review。資料表格屬於 1.4.10 的例外，但仍建議包一層可捲動的容器。其他來源 → fail。有溢出卻找不到來源 → review。
- **窄版選單**：在 header、nav 裡找 class、id 符合 toggler、hamburger 等字樣，或 aria-label 含「選單」，或同時有 `aria-expanded` 與 `aria-controls` 的按鈕。點擊後如果可見連結數增加，或 `aria-expanded` 由非 true 變成 true，就算成功展開；否則記為 `menu-toggle` review。展開狀態會保留給後面 320px 的 axe 掃描，讓選單內容也被檢查到。

## 6. 彙整與狀態模型

### 6.1 合併

finding 以 `sc|status|check|page` 為鍵合併。桌機和窄版的 axe 常常重複報同一個問題，合併時：

- `viewports` 會列出兩種寬度。
- `nodes` 依 `selector` 去重後合併；`count` 只加上新出現的節點數。

### 6.2 準則狀態

```
statusOf(sc):
  有任何 fail finding        → fail
  有任何 finding（皆 review） → review
  在 axeCovered ∪ CUSTOM_COVER → pass
  否則                        → manual
```

`SC` 常數是 55 項準則的單一來源：編號、等級、中文名稱、人工檢核要點。4.1.1 在 WCAG 2.2 已廢止，所以不列入。axe 回報不在 `SC` 內的準則（例如 AAA）時會被 `scList()` 濾掉。

### 6.3 結束代碼

只要 `counts.fail > 0`，exit code 就是 2。review 不影響結束代碼，避免 CI 因為無法判定的項目一直失敗。

## 7. 輸出格式

### 7.1 `wcag-result.json`

```jsonc
{
  "meta": {
    "target": "https://…", "generatedAt": "ISO 8601", "axeVersion": "4.x", "chrome": "/usr/bin/google-chrome",
    "options": { "maxPages": 15, "crawl": true, "bust": false, "tabs": 50 },
    "counts": { "fail": 0, "review": 3, "pass": 25, "manual": 27 }
  },
  "summary": [ { "id": "1.4.3", "level": "AA", "name": "對比（最低）", "hint": "…", "status": "review", "automated": true } ],
  "pages": [ {
    "url": "…", "finalUrl": "…", "status": 200, "title": "…", "error": null, "skipped": null,
    "keyboard": { "focusable": 23 },
    "reflow": { "scrollWidth": 320, "clientWidth": 320 },
    "menu": { "toggler": "button.navbar-toggler", "linksBefore": 3, "linksAfter": 12, "ariaExpanded": ["false", "true"] }
  } ],
  "findings": [ {
    "page": "…", "sc": "2.4.7", "status": "fail", "check": "focus-visible",
    "viewport": "1366px", "viewports": ["1366px"],
    "message": "…", "impact": "serious", "helpUrl": "…",      // impact、helpUrl 只有 axe 有
    "count": 2, "nodes": [ { "selector": "…", "html": "…", "detail": "…" } ]
  } ]
}
```

### 7.2 `check` 識別碼

| check | 準則 | 狀態 |
|:---|:---|:---|
| `axe:<rule-id>` | 依規則標籤 | fail／review |
| `autocomplete` | 1.3.5 | fail（密碼）／review |
| `captcha` | 3.3.8 | review |
| `paste-block` | 3.3.8 | fail（驗證頁）／review |
| `pointer-only` | 2.1.1 | review |
| `keyboard-none` | 2.1.1 | review |
| `keyboard-trap` | 2.1.2 | fail |
| `focus-visible` | 2.4.7 | fail |
| `focus-visible-hidden-element` | 2.4.7 | review |
| `focus-offscreen` | 2.4.7 | review |
| `focus-obscured` | 2.4.11 | fail |
| `text-spacing` | 1.4.12 | review |
| `reflow` | 1.4.10 | fail／review（找不到來源） |
| `reflow-table` | 1.4.10 | review |
| `menu-toggle` | 1.4.10 | review |

### 7.3 報告

- **Markdown**：依序是結論、總表、不符合明細、需確認明細、僅能人工清單、未發現問題清單、頁面清單。每處問題最多列 5 個節點。表格內容的 `|` 會跳脫。
- **HTML**：
  - 單一檔案，CSS 寫在檔案內；只有一小段 inline script 處理總表篩選，沒有外部資源。
  - 所有動態內容都經過 `h()` 做 HTML 跳脫。連結只接受 `http(s)://` 開頭的網址（`safeUrl()`），避免受測頁面的內容造成 XSS。
  - 報告本身也符合 AA：跳至主要內容連結、地標與標題層級、`th scope`、可捲動表格有 `tabindex=0` 與 `role=region`、篩選結果用 `role=status` 報讀、`:focus-visible` 外框、色彩對比 ≥ 4.5:1（深淺色都是）、320px 不出現水平捲動、狀態不只靠顏色區分（圖示加文字）。
  - 同一準則同時有 fail 和 review 時，錨點 `#sc-<id>` 只掛在 fail 的明細上，避免 id 重複。
  - 列印時強制展開所有 `<details>`，並隱藏篩選區。
  - 每處問題最多列 20 個節點。

## 8. 相依套件與版本

| 套件 | 用途 | 版本策略 |
|:---|:---|:---|
| `puppeteer-core` | 控制 Chrome | 第一次安裝時取最新版 |
| `@axe-core/puppeteer` | 注入 axe 並收集結果 | 同上 |
| `axe-core@4` | 規則引擎與 `zh_TW` 語系 | 鎖定 major 4 |

目前沒有鎖定次要版本，因此不同機器、不同時間安裝的版本可能不一樣，axe 規則的增減會讓結果不同。報告和 JSON 都記錄了 `axeVersion`。需要固定結果時（例如稽核留存），可以把 `npm install` 那一行改成指定的確切版本。開發時驗證的版本是 puppeteer-core 25.18.1、axe-core 4.14.1、Node.js 24。

## 9. 修改與驗證

```bash
# 語法檢查（Bash 與內嵌的 JS）
bash -n tools/wcag22-check.sh
sed -n '/^cat > "\$RUNNER" <<.JS.$/,/^JS$/p' tools/wcag22-check.sh | sed '1d;$d' > /tmp/runner-check.js
node --check /tmp/runner-check.js
```

**回歸測試建議**：準備一組刻意埋入已知問題的本機 HTML 頁面，用 `python3 -m http.server` 提供，以 `--no-crawl -u` 逐頁檢測，確認每一類問題都有被抓到。開發時驗證過的 12 類問題：

1. `outline:none` 且沒有替代樣式
2. 焦點被 fixed 頁首完全遮蔽
3. 鍵盤陷阱（`keydown` 攔截 Tab）
4. `div` 搭配 click 模擬按鈕
5. 320px 長字串不斷行
6. 資料表格溢出（應列為例外）
7. 漢堡選單無法展開
8. 文字間距造成裁切（固定高度 + `overflow:hidden`）
9. 密碼欄 `autocomplete="off"`
10. 驗證碼圖片
11. `onpaste="return false"`
12. 爬取排除登出連結與 PDF

另外，用真實網站驗證時，應該和人工檢核的結論一致。開發時以實際網站的 8 頁驗證：0 項不符合、3 項需確認，與人工複測的結論相符。

## 10. 擴充

### 新增一項檢查

1. 寫一個在頁面內執行的函式。它會被序列化後送進頁面，所以不能使用閉包變數；共用工具請用 `window.__wcag`（`sel`、`visible`、`text`、`focusable`）。
2. 在主迴圈的適當位置呼叫 `page.evaluate(fn)`，再用 `add({ sc, status, check, viewport, message, count, nodes })` 回報。
3. 新的準則如果原本不在 axe 的涵蓋範圍，要加進 `CUSTOM_COVER`，否則沒有問題時會顯示「僅能人工檢核」。
4. 更新 §7.2 的表格與 README。

### 支援登入後的頁面（尚未實作，建議作法）

- 新增 `--cookie "名稱=值"` 選項，在 `goto` 之前呼叫 `page.setCookie()`（本專案的驗證 Cookie 名稱是 `MyCookie`）。
- 或新增 `--login-script FILE`，在檢測開始前用 puppeteer 自動登入。
- 登入狀態下爬取，誤觸寫入動作的風險比較高，`--exclude` 預設值應該加強，或改成預設不爬取。

### 檢查互動狀態（對話框、下拉選單）

- 新增 `--actions FILE`，用 JSON 描述「網址 → 點擊選擇器 → 等待 → 以某個範圍執行 axe 與鍵盤走訪」。
- 對話框可以額外檢查：開啟後焦點是否移入、Tab 是否留在對話框內、Esc 後焦點是否回到觸發元素。這些驗證腳本在開發過程中都寫過（對應 2.4.3），可以直接移植。

### 加速

鍵盤走訪需要前景焦點，不適合在同一個瀏覽器內並行。要加速的話，可以把頁面分組，啟動多個瀏覽器實例分別處理；但伺服器負載與快取行為會不同，需要評估。
