# wcag22-check：WCAG 2.2 AA 自動化檢核工具

給定目標網址，以 headless Chrome 載入頁面（可自動爬取同網域連結），結合 axe-core 與自訂的鍵盤、重排、文字間距、表單檢查，產出 WCAG 2.2 A／AA 共 55 項成功準則的檢核報告（HTML、Markdown、JSON）。

設計細節見 [DESIGN.md](DESIGN.md)。

## 重要提醒

自動化檢測大約只能涵蓋三到四成的準則。報告中「需人工確認」與「僅能人工檢核」的項目，仍要以鍵盤操作與螢幕報讀軟體（NVDA、VoiceOver）實際確認。**「自動檢測未發現問題」不代表符合。**

## 環境需求

| 項目 | 需求 |
|:---|:---|
| 作業系統 | Linux、macOS（Windows 請用 WSL 或 Git Bash） |
| Node.js | 18 以上（含 npm） |
| 瀏覽器 | Google Chrome 或 Chromium |
| 網路 | 首次執行需要連到 npm registry 安裝套件 |

第一次執行時，會把 `puppeteer-core`、`@axe-core/puppeteer`、`axe-core@4` 安裝到 `~/.cache/wcag22-check`，不會動到目前的專案。

## 快速開始

```bash
# 從首頁爬取同網域連結，最多檢測 15 頁
./wcag22-check.sh https://www.google.com/

# 避開反向代理快取，並補測首頁沒有連到的頁面
./wcag22-check.sh --bust -u /ForgotPassword -u "/ShowItem?p=5358" https://www.google.com/

# 只檢測指定的頁面，不爬取
./wcag22-check.sh --no-crawl -u /LoginPage -u /Statistics https://www.google.com/

# 指定輸出目錄、提高頁數上限
./wcag22-check.sh --bust -n 30 -o ./a11y-report https://www.google.com/
```

執行時，進度會輸出到 stderr；結束時會印出摘要與報告路徑。

## 使用 Docker 執行

映像檔已內建 Node.js、Chromium、正體中文字型（Noto CJK）與所需的 npm 相依套件，預設時區為台北（`Asia/Taipei`），可在無須額外安裝本機環境或無外網的內網環境下直接執行。

```bash
# 建置映像檔
docker build -t wcag22-check .

# 執行檢核並將報告輸出至本機 ./reports 目錄
mkdir -p ./reports
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$(pwd)/reports:/output" \
  wcag22-check https://www.google.com/

# 檢核宿主機本機執行的服務（例如 http://localhost:8080）
# macOS / Windows（Docker Desktop）
docker run --rm --user "$(id -u):$(id -g)" \
  --add-host=host.docker.internal:host-gateway \
  -v "$(pwd)/reports:/output" \
  wcag22-check --no-crawl http://host.docker.internal:8080

# Linux（若防火牆阻擋 Docker bridge，可改用 --network host）
docker run --rm --network host --user "$(id -u):$(id -g)" \
  -v "$(pwd)/reports:/output" \
  wcag22-check --no-crawl http://127.0.0.1:8080
```

- 預設工作目錄為 `/output`，未指定 `-o` 時報告會直接產出在掛載的 `/output` 目錄中。
- **請務必先執行 `mkdir -p ./reports`** 再執行 `docker run`，避免掛載目錄不存在時由 Docker 以 `root` 自動建立而造成 `Permission denied`。若不慎由 Docker 建立，可於宿主機執行 `rmdir ./reports && mkdir -p ./reports` 重建。
- 加上 `--user "$(id -u):$(id -g)"` 可避免宿主機帳號 UID（如網域帳號）與容器預設 `node`（UID `1000`）不一致導致無法寫入，並讓報告檔案擁有者與目前使用者一致。
- 若需更換時區，可透過 `-e TZ=UTC` 等環境變數覆蓋。

## 選項

| 選項 | 預設值 | 說明 |
|:---|:---|:---|
| `-o, --out DIR` | `./wcag-report-<主機>-<時間>` | 報告輸出目錄 |
| `-n, --max-pages N` | 15 | 最多檢測頁數。略過的頁面（非 HTML）與發生錯誤的頁面不計入 |
| `-u, --url URL` | — | 額外指定要檢測的頁面。可重複使用，可用相對路徑（如 `-u /Login`） |
| `--no-crawl` | 關 | 不爬取首頁連結，只測目標網址與 `-u` 指定的頁面 |
| `--bust` | 關 | 每次請求加上 `_wcag=<隨機值>` 參數，避開 nginx、CDN 快取 |
| `--tabs N` | 50 | 每頁鍵盤走訪的 Tab 次數上限 |
| `--exclude REGEX` | `logout\|log-out\|signout\|sign-out\|登出\|delete\|remove` | 爬取時排除的連結，同時比對網址與連結文字（不分大小寫）。指定時會**取代**預設值 |
| `--timeout SEC` | 45 | 單頁載入逾時秒數。逾時後仍以當下狀態繼續檢測 |
| `--chrome PATH` | 自動尋找 | Chrome 執行檔路徑 |
| `-k, --insecure` | 關 | 忽略 TLS 憑證錯誤（測試環境自簽憑證用） |
| `-h, --help` | — | 顯示說明 |

### 環境變數

| 變數 | 說明 |
|:---|:---|
| `WCAG_CHECK_HOME` | 相依套件與 `runner.js` 的存放目錄，預設 `~/.cache/wcag22-check` |
| `CHROME_PATH` | Chrome 路徑，優先順序低於 `--chrome` |
| `PUPPETEER_EXECUTABLE_PATH` | 沒有設定 `CHROME_PATH` 時使用 |

## 爬取規則

- 只從**目標網址那一頁**收集連結（深度 1），不做遞迴爬取。其他頁面請用 `-u` 補上。
- 只收同一來源（scheme、host、port 都相同）的 http、https 連結。
- 自動排除：
  - 檔案下載（pdf、xlsx、docx、zip、圖片、影音等副檔名）。
  - 符合 `--exclude` 的連結。
  - 路徑或查詢字串含 `undefined`、`null`、`NaN` 的連結（前端資料還沒綁定時的連結，例如 `/api/Export/undefined`）。
- 去重時會忽略網址的 `#hash` 與 `_wcag` 參數。

> ⚠️ 爬取時會實際開啟連結。如果在**已登入**或**有寫入權限**的環境執行，請確認 `--exclude` 已排除所有會異動資料的 GET 連結。

## 輸出

| 檔案 | 內容 |
|:---|:---|
| `wcag-report.html` | 單一檔案、不連外部資源的報告，可直接寄送。有結論卡片、可篩選的 55 項準則總表、可展開的明細，支援深淺色與列印。報告本身經 axe 檢查符合 AA |
| `wcag-report.md` | 內容相同的 Markdown 版（每處問題最多列 5 個元素；HTML 版最多 20 個） |
| `wcag-result.json` | 完整原始結果，可供其他工具串接（結構見設計文件） |

### 結果分類

| 分類 | 意義 |
|:---|:---|
| ❌ 不符合 | 自動判定的違規，例如 axe 的 violations、沒有焦點樣式、焦點被完全遮蔽、鍵盤陷阱、密碼欄沒有 autocomplete、驗證頁阻擋貼上 |
| ⚠️ 需人工確認 | 工具無法判定（例如 axe 的 incomplete）或啟發式偵測到的疑似問題 |
| ✅ 自動檢測未發現問題 | 有自動化規則涵蓋這項準則，但沒有發現問題 |
| 📝 僅能人工檢核 | 沒有任何自動化規則涵蓋，報告會附上檢核要點 |

### 結束代碼

| 代碼 | 意義 |
|:---|:---|
| 0 | 沒有發現「不符合」的項目（可能仍有需人工確認的項目） |
| 2 | 發現「不符合」的項目 |
| 1 | 執行錯誤（參數錯誤、找不到 Chrome、套件安裝失敗、瀏覽器異常） |

用在 CI 時，可以用 exit code 2 讓建置失敗，再把輸出目錄存成 artifact：

```bash
set +e
./wcag22-check.sh --bust --no-crawl -u /LoginPage -o ./wcag-out https://www.google.com/
rc=$?
set -e
case $rc in
    0) echo "未發現不符合項目" ;;
    2) echo "有 WCAG 不符合項目，詳見 wcag-out/wcag-report.html"; exit 1 ;;
    *) echo "檢核執行失敗"; exit 1 ;;
esac
```

## 檢查項目

| 準則 | 檢查方式 | 結果分類 |
|:---|:---|:---|
| axe 涵蓋的 A／AA 準則 | axe-core（正體中文訊息），1366px 與 320px（選單展開後）各掃一次 | violations：不符合；incomplete：需確認 |
| 1.3.5 識別輸入目的 | 密碼欄、疑似個人資料欄位的 `autocomplete` | 密碼欄：不符合；其他：需確認 |
| 1.4.10 重排 | 320px 時的水平溢出來源；漢堡選單能否展開 | 非表格造成的溢出：不符合；表格、選單問題：需確認 |
| 1.4.12 文字間距 | 套用規定的文字間距後，新增被 `overflow:hidden` 裁切的內容 | 需確認 |
| 2.1.1 鍵盤 | 游標是手指但無法聚焦的元素；整頁沒有可聚焦的元素 | 需確認 |
| 2.1.2 無鍵盤陷阱 | 連續 4 次 Tab 焦點都停在同一元素 | 不符合 |
| 2.4.7 焦點可見 | 比對聚焦與失焦時的樣式差異 | 不符合（極小元素、聚焦在畫面外：需確認） |
| 2.4.11 焦點未被遮蔽 | 元素中心與四角都被 fixed／sticky 元素蓋住 | 不符合 |
| 3.3.8 無障礙驗證 | 偵測驗證碼、`onpaste` 阻擋貼上 | 驗證碼：需確認；驗證頁阻擋貼上：不符合 |

## 常見情境

- **結果和瀏覽器看到的不同**：可能讀到反向代理快取的舊頁面，加上 `--bust`。
- **登入後才看得到的頁面**：目前不支援帶入登入狀態，只能檢測匿名可以看到的頁面（作法見設計文件「擴充」一節）。
- **對話框、下拉選單裡的內容**：不會自動操作，需人工檢查，或比照設計文件的方式自行加入。
- **更新 axe-core**：刪除 `~/.cache/wcag22-check/node_modules` 後重新執行，會安裝最新版。
- **`runner.js` 被改掉**：每次執行都會由腳本覆寫，修改請改 `wcag22-check.sh` 裡的 heredoc。

## 已知限制

- 只會檢查載入後的初始狀態。互動流程（送出表單、錯誤訊息、對話框、分頁）都不會自動操作。
- 鍵盤走訪只用 Tab 前進，不會測方向鍵、Esc、Enter 的操作行為。
- 焦點可見只判斷「有沒有樣式變化」，不判斷變化是否夠明顯（對比、面積）。
- 3.3.8 只能偵測到驗證碼的存在，是否提供替代方式需人工判斷。
- 只有 Chromium 一種引擎。
