#!/usr/bin/env bash
# =============================================================================
# WCAG 2.2 AA 自動化檢核
#
# 提供目標網址後，以 headless Chrome 載入頁面（可自動爬取同網域連結），執行：
#   - axe-core（WCAG 2.0/2.1/2.2 A、AA 規則，正體中文訊息），桌機與 320px 窄版各一次
#   - 鍵盤走訪：焦點可見（2.4.7）、焦點未被遮蔽（2.4.11）、鍵盤陷阱（2.1.2）
#   - 疑似僅滑鼠可操作的元素（2.1.1）
#   - 320px 重排與窄版選單可否展開（1.4.10）
#   - 文字間距（1.4.12）
#   - 表單 autocomplete（1.3.5）、驗證碼與阻擋貼上（3.3.8）
# 產出 HTML 與 Markdown 報告（逐條列出 55 項 A/AA 準則狀態）及 JSON 原始結果。
#
# 自動化檢測約只能涵蓋三到四成的準則，報告中「需人工確認」「僅能人工檢核」的項目
# 仍須以人工（鍵盤操作、螢幕報讀軟體）確認。
#
# 相依：Node.js 18+、Google Chrome / Chromium。
#       首次執行會把 puppeteer-core 與 axe-core 安裝到 $WCAG_CHECK_HOME（預設 ~/.cache/wcag22-check）。
# 結束代碼：0 = 未發現不符合項目；2 = 發現不符合項目；1 = 執行錯誤
# =============================================================================
set -euo pipefail

CACHE_DIR="${WCAG_CHECK_HOME:-$HOME/.cache/wcag22-check}"

usage() {
    cat <<'EOF'
用法：wcag22-check.sh [選項] <目標網址>

選項：
  -o, --out DIR        報告輸出目錄（預設 ./wcag-report-<主機>-<時間>）
  -n, --max-pages N    最多檢測頁數（預設 15）
  -u, --url URL        額外指定要檢測的頁面（可重複；可用相對路徑，如 -u /Login）
      --no-crawl       不自動爬取首頁上的同網域連結，只檢測目標網址與 -u 指定的頁面
      --bust           每次請求加上隨機參數，避開反向代理／CDN 快取
      --tabs N         每頁鍵盤走訪的 Tab 次數上限（預設 50）
      --exclude REGEX  爬取時排除的連結（比對網址與連結文字；
                       預設 'logout|log-out|signout|sign-out|登出|delete|remove'）
      --timeout SEC    單頁載入逾時秒數（預設 45）
      --chrome PATH    Chrome 執行檔路徑（預設自動尋找，或用 CHROME_PATH 環境變數）
  -k, --insecure       忽略 TLS 憑證錯誤（測試環境自簽憑證用）
  -h, --help           顯示說明

範例：
  wcag22-check.sh https://www.google.com/
  wcag22-check.sh --no-crawl -u /LoginPage -u "/ShowItem?p=5358" https://www.google.com/
  wcag22-check.sh --bust -n 30 -o ./a11y-report https://www.google.com/
EOF
}

die() { echo "錯誤：$*" >&2; exit 1; }

URL=""
OUT=""
MAX_PAGES=15
CRAWL=1
BUST=0
TABS=50
TIMEOUT=45
INSECURE=0
EXCLUDE=""
CHROME="${CHROME_PATH:-${PUPPETEER_EXECUTABLE_PATH:-}}"
EXTRA=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--out)       [[ $# -ge 2 ]] || die "$1 需要參數"; OUT="$2"; shift 2 ;;
        -n|--max-pages) [[ $# -ge 2 ]] || die "$1 需要參數"; MAX_PAGES="$2"; shift 2 ;;
        -u|--url)       [[ $# -ge 2 ]] || die "$1 需要參數"; EXTRA+=("$2"); shift 2 ;;
        --no-crawl)     CRAWL=0; shift ;;
        --bust)         BUST=1; shift ;;
        --tabs)         [[ $# -ge 2 ]] || die "$1 需要參數"; TABS="$2"; shift 2 ;;
        --exclude)      [[ $# -ge 2 ]] || die "$1 需要參數"; EXCLUDE="$2"; shift 2 ;;
        --timeout)      [[ $# -ge 2 ]] || die "$1 需要參數"; TIMEOUT="$2"; shift 2 ;;
        --chrome)       [[ $# -ge 2 ]] || die "$1 需要參數"; CHROME="$2"; shift 2 ;;
        -k|--insecure)  INSECURE=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        -*)             echo "未知選項：$1" >&2; usage >&2; exit 1 ;;
        *)
            [[ -z "$URL" ]] || die "只能指定一個目標網址（其他頁面請用 -u）"
            URL="$1"; shift ;;
    esac
done

[[ -n "$URL" ]] || { usage >&2; exit 1; }
[[ "$URL" =~ ^https?:// ]] || die "目標網址需以 http:// 或 https:// 開頭：$URL"
for v in MAX_PAGES TABS TIMEOUT; do
    [[ "${!v}" =~ ^[0-9]+$ && "${!v}" -gt 0 ]] || die "$v 必須是正整數：${!v}"
done

# ---- Node.js ----
command -v node >/dev/null || die "找不到 node，請先安裝 Node.js 18 以上版本"
command -v npm >/dev/null || die "找不到 npm"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[[ "$NODE_MAJOR" -ge 18 ]] || die "Node.js 版本過舊（$(node -v)），需要 18 以上"

# ---- Chrome ----
if [[ -z "$CHROME" ]]; then
    for c in google-chrome google-chrome-stable chromium chromium-browser chrome; do
        if command -v "$c" >/dev/null; then CHROME="$(command -v "$c")"; break; fi
    done
    [[ -z "$CHROME" && -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]] \
        && CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
fi
[[ -n "$CHROME" && -x "$CHROME" ]] || die "找不到 Chrome，請以 --chrome 或 CHROME_PATH 指定執行檔路徑"

# ---- 相依套件（安裝於快取目錄，不汙染目前專案）----
mkdir -p "$CACHE_DIR"
if [[ ! -f "$CACHE_DIR/node_modules/@axe-core/puppeteer/package.json" \
   || ! -f "$CACHE_DIR/node_modules/puppeteer-core/package.json" \
   || ! -f "$CACHE_DIR/node_modules/axe-core/package.json" ]]; then
    echo "首次執行：安裝 puppeteer-core、@axe-core/puppeteer、axe-core 至 $CACHE_DIR …" >&2
    [[ -f "$CACHE_DIR/package.json" ]] || echo '{"name":"wcag22-check-deps","private":true}' > "$CACHE_DIR/package.json"
    (cd "$CACHE_DIR" && PUPPETEER_SKIP_DOWNLOAD=1 npm install --no-audit --no-fund --loglevel=error \
        puppeteer-core @axe-core/puppeteer axe-core@4) >&2 || die "套件安裝失敗"
fi

# ---- 輸出目錄 ----
if [[ -z "$OUT" ]]; then
    HOST="$(node -e 'console.log(new URL(process.argv[1]).host.replace(/[^A-Za-z0-9.-]/g,"_"))' "$URL")"
    OUT="./wcag-report-${HOST}-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# ---- 檢測程式（每次覆寫，確保與本腳本版本一致）----
RUNNER="$CACHE_DIR/runner.js"
cat > "$RUNNER" <<'JS'
'use strict';
const fs = require('fs');
const path = require('path');
const puppeteer = require('puppeteer-core');
const { AxePuppeteer } = require('@axe-core/puppeteer');

const env = process.env;
const cfg = {
    start: env.WCAG_START,
    extra: (env.WCAG_EXTRA || '').split('\n').map(s => s.trim()).filter(Boolean),
    maxPages: +env.WCAG_MAX_PAGES,
    crawl: env.WCAG_CRAWL === '1',
    bust: env.WCAG_BUST === '1',
    tabs: +env.WCAG_TABS,
    outDir: env.WCAG_OUT,
    chrome: env.WCAG_CHROME,
    timeout: +env.WCAG_TIMEOUT * 1000,
    insecure: env.WCAG_INSECURE === '1',
    exclude: new RegExp(env.WCAG_EXCLUDE || 'logout|log-out|signout|sign-out|登出|delete|remove', 'i'),
};
const AXE_TAGS = ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22a', 'wcag22aa'];
const sleep = ms => new Promise(r => setTimeout(r, ms));
const log = (...a) => console.error('[wcag]', ...a);

// WCAG 2.2 A / AA 全部 55 項準則（4.1.1 已於 2.2 廢止）與人工檢核要點
const SC = [
    ['1.1.1', 'A', '非文字內容', '圖片、圖示按鈕、驗證碼是否有適當替代文字；裝飾性圖片使用空 alt'],
    ['1.2.1', 'A', '純音訊與純視訊（預錄）', '預錄音訊提供逐字稿；預錄純視訊提供文字或音訊替代'],
    ['1.2.2', 'A', '字幕（預錄）', '預錄影片提供同步字幕'],
    ['1.2.3', 'A', '音訊描述或媒體替代（預錄）', '影片提供口述影像或完整文字替代'],
    ['1.3.1', 'A', '資訊與關係', '標題層級、清單、表格標頭、表單標籤以語意標記呈現'],
    ['1.3.2', 'A', '有意義的順序', '以螢幕報讀軟體線性閱讀時順序合理'],
    ['1.3.3', 'A', '感官特性', '操作說明不只依賴形狀、位置、顏色或聲音'],
    ['1.4.1', 'A', '色彩的使用', '不只用顏色傳達資訊（必填、錯誤、連結與文字區別）'],
    ['1.4.2', 'A', '音訊控制', '自動播放超過 3 秒的音訊可暫停或調整音量'],
    ['2.1.1', 'A', '鍵盤', '所有功能皆可只用鍵盤操作（含下拉選單、收合區塊、對話框）'],
    ['2.1.2', 'A', '無鍵盤陷阱', '焦點可用鍵盤移入也能移出每個元件'],
    ['2.1.4', 'A', '字元快捷鍵', '單一字元快捷鍵可關閉、重新對應或僅於聚焦時作用'],
    ['2.2.1', 'A', '可調整的時間', '有時間限制（如登入逾時）時可關閉、調整或延長'],
    ['2.2.2', 'A', '暫停、停止、隱藏', '自動輪播、捲動、閃動內容可暫停或停止'],
    ['2.3.1', 'A', '三次閃爍或低於閾值', '內容每秒閃爍不超過三次'],
    ['2.4.1', 'A', '跳過區塊', '有跳到主要內容的機制（跳過導覽連結、地標）'],
    ['2.4.2', 'A', '網頁標題', '每頁有描述主題或目的且彼此可區別的標題'],
    ['2.4.3', 'A', '焦點順序', 'Tab 順序合理；對話框開啟時焦點移入、關閉後回到觸發元素'],
    ['2.4.4', 'A', '連結目的（上下文）', '連結文字（含上下文）可判斷目的'],
    ['2.5.1', 'A', '指標手勢', '多點或路徑手勢有單點替代操作'],
    ['2.5.2', 'A', '指標取消', '按下時不觸發動作，或可中止、復原'],
    ['2.5.3', 'A', '名稱中的標籤', '可見標籤文字包含在可存取名稱中'],
    ['2.5.4', 'A', '動作啟動', '搖晃、傾斜等動作操作有替代方式且可停用'],
    ['3.1.1', 'A', '網頁語言', 'html 有正確的 lang 屬性'],
    ['3.2.1', 'A', '聚焦時', '元件取得焦點時不會自動改變情境'],
    ['3.2.2', 'A', '輸入時', '變更設定時不會自動改變情境，或事先告知'],
    ['3.2.6', 'A', '一致的求助', '各頁求助機制（聯絡方式等）出現的相對順序一致'],
    ['3.3.1', 'A', '錯誤識別', '輸入錯誤時以文字指出錯誤項目'],
    ['3.3.2', 'A', '標籤或說明', '表單欄位有可見標籤或說明（placeholder 不足以取代）'],
    ['3.3.7', 'A', '重複輸入', '同一流程中已輸入的資訊不需再次輸入'],
    ['4.1.2', 'A', '名稱、角色、值', '自訂元件具正確名稱、角色與狀態（如 aria-expanded）'],
    ['1.2.4', 'AA', '字幕（直播）', '直播影音提供即時字幕'],
    ['1.2.5', 'AA', '音訊描述（預錄）', '預錄影片提供口述影像'],
    ['1.3.4', 'AA', '方向', '內容不限制只能直向或橫向顯示'],
    ['1.3.5', 'AA', '識別輸入目的', '個人資料欄位有正確的 autocomplete 屬性'],
    ['1.4.3', 'AA', '對比（最低）', '文字對比至少 4.5:1（大字 3:1）；背景圖、漸層上的文字需目測'],
    ['1.4.4', 'AA', '調整文字大小', '瀏覽器放大至 200% 不遺失內容或功能'],
    ['1.4.5', 'AA', '文字圖像', '避免以圖片呈現文字（標誌除外）'],
    ['1.4.10', 'AA', '重排', '320 CSS px 寬（放大 400%）不需水平捲動、不遺失功能'],
    ['1.4.11', 'AA', '非文字對比', '元件邊框、焦點框、圖示對比至少 3:1'],
    ['1.4.12', 'AA', '文字間距', '調整行高、字距、段距後內容不被裁切'],
    ['1.4.13', 'AA', '懸停或聚焦的內容', '提示框可用 Esc 關閉、可懸停於其上、持續顯示'],
    ['2.4.5', 'AA', '多種方式', '提供網站導覽、搜尋等兩種以上找到頁面的方式'],
    ['2.4.6', 'AA', '標題與標籤', '標題與標籤能描述主題或目的'],
    ['2.4.7', 'AA', '焦點可見', '鍵盤焦點有可見的指示'],
    ['2.4.11', 'AA', '焦點未被遮蔽（最低）', '取得焦點的元素不會被固定頁首、浮動元件完全遮住'],
    ['2.5.7', 'AA', '拖曳動作', '拖曳操作有單點替代方式'],
    ['2.5.8', 'AA', '目標尺寸（最低）', '點擊目標至少 24×24 CSS px 或有足夠間距'],
    ['3.1.2', 'AA', '部分內容的語言', '不同語言段落以 lang 標示'],
    ['3.2.3', 'AA', '一致的導覽', '重複出現的導覽順序一致'],
    ['3.2.4', 'AA', '一致的識別', '相同功能的元件識別一致'],
    ['3.3.3', 'AA', '錯誤建議', '錯誤時提供修正建議'],
    ['3.3.4', 'AA', '錯誤預防（法律、財務、資料）', '重要送出可檢查、確認或撤回'],
    ['3.3.8', 'AA', '無障礙驗證（最低）', '登入、找回帳號不得要求抄寫驗證碼（含語音）等認知測試，除非有替代方式；須允許貼上與密碼管理器'],
    ['4.1.3', 'AA', '狀態訊息', '查詢結果、錯誤等狀態訊息可被報讀（role=status / alert）'],
];
const SC_IDS = new Set(SC.map(s => s[0]));
// 本程式自訂檢查涵蓋的準則（axe 涵蓋者另由規則標籤計算）
const CUSTOM_COVER = ['1.3.5', '1.4.10', '1.4.12', '2.1.1', '2.1.2', '2.4.7', '2.4.11', '3.3.8'];

function scFromTag(tag) {
    const m = /^wcag(\d)(\d)(\d+)$/.exec(tag);
    return m ? `${m[1]}.${m[2]}.${m[3]}` : null;
}
const scList = tags => [...new Set(tags.map(scFromTag).filter(s => s && SC_IDS.has(s)))];

function normUrl(u) {
    const x = new URL(u);
    x.hash = '';
    x.searchParams.delete('_wcag');
    return x.href;
}
function bustUrl(u) {
    if (!cfg.bust) return u;
    const x = new URL(u);
    x.searchParams.set('_wcag', Date.now().toString(36));
    return x.href;
}

// ---- 注入頁面的共用工具（以 evaluateOnNewDocument 安裝，不受 CSP 限制）----
function installHelpers() {
    const H = {};
    H.sel = function (e) {
        if (!e || e.nodeType !== 1) return '';
        const parts = [];
        let cur = e;
        for (let i = 0; cur && cur.nodeType === 1 && i < 4; i++) {
            if (cur.id) { parts.unshift('#' + CSS.escape(cur.id)); break; }
            let s = cur.tagName.toLowerCase();
            const cls = typeof cur.className === 'string'
                ? cur.className.split(/\s+/).filter(c => c && !/^(v-|router-|ng-)/.test(c)).slice(0, 2) : [];
            if (cls.length) s += '.' + cls.map(c => CSS.escape(c)).join('.');
            const p = cur.parentElement;
            if (p) {
                const same = [...p.children].filter(c => c.tagName === cur.tagName);
                if (same.length > 1) s += `:nth-of-type(${same.indexOf(cur) + 1})`;
            }
            parts.unshift(s);
            cur = p;
        }
        return parts.join(' > ');
    };
    H.visible = function (e) {
        const cs = getComputedStyle(e);
        if (cs.display === 'none' || cs.visibility === 'hidden' || +cs.opacity === 0) return false;
        const r = e.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
    };
    H.text = e => (e.innerText || e.value || e.getAttribute('aria-label') || e.getAttribute('title') || e.getAttribute('alt') || '')
        .toString().trim().replace(/\s+/g, ' ').slice(0, 40);
    H.focusable = function (e) {
        if (e.disabled) return false;
        if (e.hasAttribute('tabindex')) return e.tabIndex >= 0;
        if (e.tagName === 'A') return e.hasAttribute('href');
        return /^(BUTTON|INPUT|SELECT|TEXTAREA|SUMMARY|IFRAME)$/.test(e.tagName) || e.isContentEditable;
    };
    Object.defineProperty(window, '__wcag', { value: H, configurable: true });
}

async function gotoPage(page, url) {
    let resp = null;
    try {
        resp = await page.goto(bustUrl(url), { waitUntil: 'networkidle2', timeout: cfg.timeout });
    } catch (e) {
        if (!/timeout/i.test(e.message)) throw e;
        log('  載入逾時，以目前狀態繼續檢測');
    }
    await sleep(1200);
    return resp;
}

async function runAxe(page, locale) {
    let a = new AxePuppeteer(page).withTags(AXE_TAGS);
    if (locale) a = a.configure({ locale });
    return a.analyze();
}

function axeFindings(ax, viewport) {
    const out = [];
    const nodeOf = (n, incomplete) => ({
        selector: n.target.map(t => Array.isArray(t) ? t.join(' >>> ') : t).join(' '),
        html: (n.html || '').slice(0, 200),
        detail: incomplete
            ? ((n.any && n.any[0] && n.any[0].message) || (n.all && n.all[0] && n.all[0].message) || '').slice(0, 300)
            : (n.failureSummary || '').replace(/\s+/g, ' ').slice(0, 300),
    });
    for (const v of ax.violations) {
        for (const sc of scList(v.tags)) {
            out.push({ sc, status: 'fail', check: 'axe:' + v.id, viewport, message: v.help, impact: v.impact,
                helpUrl: v.helpUrl, count: v.nodes.length, nodes: v.nodes.slice(0, 10).map(n => nodeOf(n, false)) });
        }
    }
    for (const v of ax.incomplete) {
        for (const sc of scList(v.tags)) {
            out.push({ sc, status: 'review', check: 'axe:' + v.id, viewport, message: v.help + '（axe 無法自動判定）',
                helpUrl: v.helpUrl, count: v.nodes.length, nodes: v.nodes.slice(0, 10).map(n => nodeOf(n, true)) });
        }
    }
    return out;
}

// ---- 表單：1.3.5 autocomplete、3.3.8 驗證碼與阻擋貼上 ----
function checkForms() {
    const H = window.__wcag;
    const out = { autocomplete: [], captcha: [], pasteBlock: [], hasPassword: false };
    const purposeRe = /帳號|使用者名稱|user ?name|user ?id|login|account|e-?mail|電子郵件|信箱|姓名|full ?name|電話|手機|phone|mobile|\btel\b|地址|address|郵遞區號|zip|postal|生日|birth/i;
    const skipRe = /驗證碼|captcha|search|搜尋|查詢|關鍵字|keyword/i;
    for (const i of document.querySelectorAll('input')) {
        const t = (i.getAttribute('type') || 'text').toLowerCase();
        if (['hidden', 'submit', 'button', 'reset', 'checkbox', 'radio', 'file', 'image', 'range', 'color'].includes(t)) continue;
        const label = [...(i.labels || [])].map(l => l.innerText).join(' ') + ' '
            + [i.getAttribute('aria-label'), i.placeholder, i.name, i.id, i.title].filter(Boolean).join(' ');
        if (t === 'password') out.hasPassword = true;
        if (!H.visible(i)) continue;
        const ac = (i.getAttribute('autocomplete') || '').trim().toLowerCase();
        const bad = !ac || ac === 'off' || ac === 'on';
        if (t === 'password' && bad) {
            out.autocomplete.push({ selector: H.sel(i), strong: true,
                detail: `密碼欄 autocomplete="${ac || '（未設定）'}"，應為 current-password 或 new-password` });
        } else if (t !== 'password' && bad && ['text', 'email', 'tel'].includes(t) && !skipRe.test(label) && purposeRe.test(label)) {
            out.autocomplete.push({ selector: H.sel(i), strong: false,
                detail: `欄位「${label.trim().replace(/\s+/g, ' ').slice(0, 30)}」疑似個人資料，autocomplete="${ac || '（未設定）'}"` });
        }
        const op = i.getAttribute('onpaste') || '';
        if (/return\s+false|preventDefault/i.test(op)) out.pasteBlock.push({ selector: H.sel(i), detail: 'onpaste 屬性阻擋貼上' });
    }
    for (const e of document.querySelectorAll('img,iframe,input,canvas,audio,div')) {
        const s = [e.getAttribute('src'), e.id, typeof e.className === 'string' ? e.className : '', e.getAttribute('name'),
            e.getAttribute('alt'), e.getAttribute('title'), e.getAttribute('aria-label'), e.getAttribute('placeholder')]
            .filter(Boolean).join(' ');
        if (!/captcha|驗證碼|recaptcha|hcaptcha|turnstile/i.test(s)) continue;
        if (e.tagName === 'DIV' && !/g-recaptcha|h-captcha|cf-turnstile/i.test(s)) continue;
        out.captcha.push({ selector: H.sel(e), detail: e.tagName.toLowerCase() + '：' + s.replace(/\s+/g, ' ').slice(0, 80) });
    }
    return out;
}

// ---- 2.1.1：游標為手指但無法以鍵盤聚焦的元素（疑似以 click 事件模擬按鈕）----
function checkPointerOnly() {
    const H = window.__wcag;
    const focusSel = 'a[href],button,input,select,textarea,summary,label,[tabindex]:not([tabindex="-1"]),[contenteditable="true"]';
    const cand = [];
    for (const e of document.querySelectorAll('body *')) {
        if (/^(LABEL|OPTION|svg|path|use|g)$/i.test(e.tagName)) continue;
        if (getComputedStyle(e).cursor !== 'pointer') continue;
        if (!H.visible(e) || H.focusable(e)) continue;
        if (e.closest(focusSel)) continue;
        if ([...e.querySelectorAll('a[href],button,input,select,textarea,summary,[tabindex]')].some(H.focusable)) continue;
        cand.push(e);
    }
    const set = new Set(cand);
    // cursor 會繼承，只保留最外層
    return cand.filter(e => !set.has(e.parentElement)).slice(0, 30)
        .map(e => ({ selector: H.sel(e), detail: `<${e.tagName.toLowerCase()}>「${H.text(e)}」` }));
}

// ---- 鍵盤走訪：量測目前焦點元素 ----
function measureFocus() {
    const H = window.__wcag;
    const e = document.activeElement;
    if (!e || e === document.body || e === document.documentElement) return { body: true };
    const r = e.getBoundingClientRect();
    const base = {
        sig: H.sel(e) + '@' + Math.round(r.left + scrollX) + ',' + Math.round(r.top + scrollY),
        selector: H.sel(e), text: H.text(e), w: Math.round(r.width), h: Math.round(r.height),
        tiny: r.width <= 2 || r.height <= 2,
    };
    if (e.tagName === 'IFRAME') return { ...base, iframe: true, indicator: true, obscured: null };

    // 焦點指示：outline 可見，或聚焦／失焦時元素、子元素、偽元素樣式有差異
    const cs = getComputedStyle(e);
    const outlineOn = cs.outlineStyle !== 'none' && parseFloat(cs.outlineWidth) > 0
        && !/rgba\(\d+,\s*\d+,\s*\d+,\s*0\)|transparent/.test(cs.outlineColor);
    let indicator = outlineOn;
    let how = outlineOn ? `outline ${cs.outlineWidth} ${cs.outlineStyle}` : '';
    if (!outlineOn) {
        const props = ['outlineStyle', 'outlineWidth', 'boxShadow', 'borderTopColor', 'borderBottomColor', 'borderTopWidth',
            'borderBottomWidth', 'backgroundColor', 'backgroundImage', 'color', 'textDecorationLine', 'filter', 'transform', 'opacity'];
        const nodes = [e, ...[...e.querySelectorAll('*')].slice(0, 8)];
        const snap = () => {
            const o = [];
            for (const n of nodes) {
                const c = getComputedStyle(n);
                o.push(props.map(p => c[p]).join('§'));
                for (const ps of ['::before', '::after']) {
                    const pc = getComputedStyle(n, ps);
                    o.push([pc.content, pc.borderColor, pc.backgroundColor, pc.outlineStyle, pc.boxShadow, pc.opacity].join('§'));
                }
            }
            return o;
        };
        const saved = nodes.map(n => n.style.transition);
        nodes.forEach(n => { n.style.transition = 'none'; });
        const f = snap();
        e.blur();
        const b = snap();
        e.focus({ preventScroll: true });
        nodes.forEach((n, i) => { n.style.transition = saved[i]; });
        indicator = f.some((v, i) => v !== b[i]);
        how = indicator ? '聚焦樣式變化' : '';
    }

    // 焦點遮蔽：取元素中心與四角內縮點，若全被 fixed / sticky 元素蓋住即為完全遮蔽
    let obscured = null;
    const vw = innerWidth, vh = innerHeight;
    if (r.bottom <= 0 || r.top >= vh || r.right <= 0 || r.left >= vw) {
        obscured = { kind: 'offscreen', detail: '聚焦後元素仍位於可視範圍外' };
    } else if (!base.tiny) {
        const pts = [[.5, .5], [.15, .2], [.85, .2], [.15, .8], [.85, .8]]
            .map(([x, y]) => [r.left + r.width * x, r.top + r.height * y])
            .filter(([x, y]) => x >= 0 && y >= 0 && x < vw && y < vh);
        const covered = pts.map(([x, y]) => {
            const t = document.elementFromPoint(x, y);
            if (!t || t === e || e.contains(t) || t.contains(e)) return null;
            for (let n = t; n && n !== document.body; n = n.parentElement) {
                const p = getComputedStyle(n).position;
                if (p === 'fixed' || p === 'sticky') return H.sel(n);
            }
            return null;
        });
        if (pts.length && covered.every(Boolean)) obscured = { kind: 'covered', detail: '被固定定位元素完全遮蔽：' + covered[0] };
    }
    return { ...base, indicator, how, obscured };
}

async function waitSettle(page) {
    await sleep(120);
    let last = '';
    for (let i = 0; i < 15; i++) {
        const p = await page.evaluate(() => {
            const a = document.activeElement;
            const r = a ? a.getBoundingClientRect() : { top: 0, left: 0 };
            return [scrollX, scrollY, Math.round(r.top), Math.round(r.left)].join(',');
        });
        if (p === last) break;
        last = p;
        await sleep(80);
    }
    await sleep(150); // 等焦點樣式轉場結束
}

async function keyboardWalk(page) {
    const res = { count: 0, noIndicator: [], tinyNoIndicator: [], obscured: [], offscreen: [], trap: null };
    await page.bringToFront();
    await page.evaluate(() => { if (document.activeElement) document.activeElement.blur(); window.scrollTo(0, 0); });
    let first = null, prev = null, same = 0;
    for (let i = 0; i < cfg.tabs; i++) {
        await page.keyboard.press('Tab');
        await waitSettle(page);
        const info = await page.evaluate(measureFocus);
        if (info.body) { if (res.count > 0) break; continue; }
        if (first === null) first = info.sig;
        else if (info.sig === first) break; // 已繞完一圈
        if (!info.iframe && info.sig === prev) {
            if (++same >= 4) { res.trap = info; break; }
        } else same = 0;
        prev = info.sig;
        res.count++;
        if (!info.indicator) (info.tiny ? res.tinyNoIndicator : res.noIndicator).push(info);
        if (info.obscured && info.obscured.kind === 'covered') res.obscured.push(info);
        if (info.obscured && info.obscured.kind === 'offscreen') res.offscreen.push(info);
    }
    return res;
}

// ---- 1.4.12 文字間距 ----
function collectClipped() {
    const H = window.__wcag;
    const out = [];
    for (const e of document.querySelectorAll('body *')) {
        if (!H.visible(e)) continue;
        const cs = getComputedStyle(e);
        const hx = /(hidden|clip)/.test(cs.overflowX), hy = /(hidden|clip)/.test(cs.overflowY);
        if (!hx && !hy) continue;
        if (!(e.innerText || '').trim()) continue;
        if ((hy && e.scrollHeight > e.clientHeight + 2) || (hx && e.scrollWidth > e.clientWidth + 2)) {
            out.push({ selector: H.sel(e), detail: `「${H.text(e)}」內容被裁切` });
        }
    }
    return out.slice(0, 60);
}

// ---- 1.4.10 重排 ----
function checkReflow() {
    const H = window.__wcag;
    const W = document.documentElement.clientWidth;
    const sw = document.documentElement.scrollWidth;
    if (sw <= W + 1) return { overflow: false, sw, W, sources: [] };
    const clippedByAncestor = e => {
        for (let a = e.parentElement; a && a !== document.body; a = a.parentElement) {
            const c = getComputedStyle(a);
            if (/(auto|scroll|hidden|clip)/.test(c.overflowX) && a.getBoundingClientRect().right <= W + 1) return true;
        }
        return false;
    };
    const cands = new Set();
    for (const e of document.querySelectorAll('body *')) {
        const r = e.getBoundingClientRect();
        if (r.width > 0 && r.right > W + 1 && H.visible(e) && !clippedByAncestor(e)) cands.add(e);
    }
    // 不斷行的文字節點（元素本身寬度正常但文字溢出）
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const range = document.createRange();
    let n;
    while ((n = walker.nextNode())) {
        if (!n.textContent.trim() || !n.parentElement) continue;
        range.selectNodeContents(n);
        const r = range.getBoundingClientRect();
        if (r.right > W + 1 && H.visible(n.parentElement) && !clippedByAncestor(n.parentElement)) cands.add(n.parentElement);
    }
    const list = [...cands];
    const top = list.filter(e => !list.some(o => o !== e && o.contains(e)));
    return {
        overflow: true, sw, W,
        sources: top.slice(0, 10).map(e => ({
            selector: H.sel(e),
            table: e.tagName === 'TABLE' || !!e.closest('table'),
            detail: `寬至 ${Math.round(e.getBoundingClientRect().right)}px：「${H.text(e)}」`,
        })),
    };
}

function findMenuToggler() {
    const H = window.__wcag;
    const re = /toggler|hamburger|menu-toggle|nav-toggle|menu-btn|navbar-toggle|burger|menu-trigger/i;
    const labelRe = /選單|功能表|導覽|menu|navigation/i;
    const c = [...document.querySelectorAll('button,[role=button],a')].filter(e => H.visible(e)
        && e.closest('header,nav,[role=banner],[role=navigation]')
        && (re.test((typeof e.className === 'string' ? e.className : '') + ' ' + e.id)
            || labelRe.test((e.getAttribute('aria-label') || '') + ' ' + (e.title || ''))
            || (e.hasAttribute('aria-expanded') && e.hasAttribute('aria-controls'))));
    return c.length ? H.sel(c[0]) : null;
}
const visibleLinkCount = () => [...document.querySelectorAll('a[href]')].filter(window.__wcag.visible).length;

// ---- 主程式 ----
(async () => {
    fs.mkdirSync(cfg.outDir, { recursive: true });
    const browser = await puppeteer.launch({
        executablePath: cfg.chrome,
        headless: true,
        acceptInsecureCerts: cfg.insecure,
        args: ['--no-sandbox', '--disable-dev-shm-usage', '--lang=zh-TW', ...(cfg.insecure ? ['--ignore-certificate-errors'] : [])],
    });
    const page = await browser.newPage();
    await page.setBypassCSP(true);
    await page.evaluateOnNewDocument(installHelpers);
    page.setDefaultTimeout(cfg.timeout);
    page.on('dialog', d => d.dismiss().catch(() => {}));

    let locale = null;
    try { locale = require('axe-core/locales/zh_TW.json'); } catch { /* 無中文語系時使用英文訊息 */ }
    const axeVersion = require('axe-core/package.json').version;

    const startOrigin = new URL(cfg.start).origin;
    const queue = [normUrl(cfg.start)];
    for (const u of cfg.extra) {
        const n = normUrl(new URL(u, cfg.start).href);
        if (!queue.includes(n)) queue.push(n);
    }

    const pages = [];
    const findings = [];
    const axeCovered = new Set();
    let crawled = !cfg.crawl;

    const testedCount = () => pages.filter(p => !p.skipped && !p.error).length;
    for (let qi = 0; qi < queue.length && testedCount() < cfg.maxPages; qi++) {
        const url = queue[qi];
        const rec = { url, status: null, title: '', error: null, skipped: null, keyboard: null };
        pages.push(rec);
        log(`(${pages.length}) ${url}`);
        const add = f => findings.push({ page: url, ...f });
        try {
            // 桌機版
            await page.setViewport({ width: 1366, height: 900 });
            const resp = await gotoPage(page, url);
            rec.status = resp ? resp.status() : null;
            const ct = resp ? (resp.headers()['content-type'] || '') : '';
            if (resp && ct && !/html/i.test(ct)) { rec.skipped = `非 HTML 內容（${ct}）`; continue; }
            rec.finalUrl = page.url();
            rec.title = await page.title();

            if (!crawled) {
                crawled = true;
                const links = await page.evaluate(() => [...document.querySelectorAll('a[href]')]
                    .map(a => ({ href: a.href, text: (a.innerText || a.title || '').trim() })));
                for (const l of links) {
                    let u;
                    try { u = new URL(l.href); } catch { continue; }
                    if (!/^https?:$/.test(u.protocol) || u.origin !== startOrigin) continue;
                    if (/\.(pdf|xlsx?|docx?|pptx?|odt|ods|zip|rar|7z|png|jpe?g|gif|webp|svg|ico|csv|txt|xml|json|mp4|mp3|wav|avi|mov)$/i.test(u.pathname)) continue;
                    if (cfg.exclude.test(u.href) || cfg.exclude.test(l.text)) continue;
                    // 尚未填入資料的前端綁定連結（如隱藏對話框內的 /api/Export/undefined）
                    if (/(^|[\/=])(undefined|null|NaN)(?=$|[\/?&#])/.test(u.pathname + u.search)) continue;
                    const n = normUrl(u.href);
                    if (!queue.includes(n)) queue.push(n);
                }
                log(`  爬取到 ${queue.length - 1} 個同網域連結（上限 ${cfg.maxPages} 頁）`);
            }

            log('  axe（桌機）');
            findings.push(...axeFindings(await runAxe(page, locale), '1366px').map(f => ({ page: url, ...f })));
            if (!axeCovered.size) {
                const tags = await page.evaluate(t => (window.axe ? window.axe.getRules(t).map(r => r.tags) : []), AXE_TAGS).catch(() => []);
                tags.forEach(ts => scList(ts).forEach(s => axeCovered.add(s)));
            }

            log('  表單與驗證碼');
            const form = await page.evaluate(checkForms);
            for (const a of form.autocomplete) {
                add({ sc: '1.3.5', status: a.strong ? 'fail' : 'review', check: 'autocomplete', viewport: '1366px',
                    message: a.strong ? '密碼欄位未以 autocomplete 標示用途' : '疑似個人資料欄位未以 autocomplete 標示用途',
                    count: 1, nodes: [a] });
            }
            const authPage = form.hasPassword || /login|signin|sign-in|password|passwd|登入|密碼|驗證/i.test(rec.finalUrl + ' ' + rec.title);
            if (form.captcha.length) {
                add({ sc: '3.3.8', status: 'review', check: 'captcha', viewport: '1366px',
                    message: authPage
                        ? '驗證流程中偵測到驗證碼：若需抄寫文字（語音驗證碼也是抄寫）且未提供不需認知測試的替代方式，即不符合 3.3.8'
                        : '偵測到驗證碼：若屬登入或找回帳號流程，需確認是否提供不需認知測試的替代方式',
                    count: form.captcha.length, nodes: form.captcha });
            }
            if (form.pasteBlock.length) {
                add({ sc: '3.3.8', status: authPage ? 'fail' : 'review', check: 'paste-block', viewport: '1366px',
                    message: '輸入欄位阻擋貼上，妨礙使用密碼管理器或貼上驗證碼', count: form.pasteBlock.length, nodes: form.pasteBlock });
            }

            log('  滑鼠限定元素');
            const po = await page.evaluate(checkPointerOnly);
            if (po.length) {
                add({ sc: '2.1.1', status: 'review', check: 'pointer-only', viewport: '1366px',
                    message: '游標為手指但無法以鍵盤聚焦的元素（疑似以 click 事件模擬按鈕或連結，鍵盤無法操作）',
                    count: po.length, nodes: po });
            }

            log('  鍵盤走訪');
            const kb = await keyboardWalk(page);
            rec.keyboard = { focusable: kb.count };
            const kn = list => list.slice(0, 15).map(i => ({ selector: i.selector, detail: `「${i.text}」${i.w}×${i.h}${i.obscured ? '；' + i.obscured.detail : ''}` }));
            if (kb.count === 0) {
                add({ sc: '2.1.1', status: 'review', check: 'keyboard-none', viewport: '1366px',
                    message: '按 Tab 無法聚焦到任何元素', count: 1, nodes: [] });
            }
            if (kb.noIndicator.length) {
                add({ sc: '2.4.7', status: 'fail', check: 'focus-visible', viewport: '1366px',
                    message: '取得鍵盤焦點時沒有任何可見樣式變化（outline 為 none 且無其他聚焦樣式）',
                    count: kb.noIndicator.length, nodes: kn(kb.noIndicator) });
            }
            if (kb.tinyNoIndicator.length) {
                add({ sc: '2.4.7', status: 'review', check: 'focus-visible-hidden-element', viewport: '1366px',
                    message: '取得焦點的元素本身幾乎不可見（如自訂核取方塊的原生 input），需確認相鄰元素是否顯示焦點',
                    count: kb.tinyNoIndicator.length, nodes: kn(kb.tinyNoIndicator) });
            }
            if (kb.obscured.length) {
                add({ sc: '2.4.11', status: 'fail', check: 'focus-obscured', viewport: '1366px',
                    message: '取得焦點的元素被固定頁首、浮動元件等完全遮蔽', count: kb.obscured.length, nodes: kn(kb.obscured) });
            }
            if (kb.offscreen.length) {
                add({ sc: '2.4.7', status: 'review', check: 'focus-offscreen', viewport: '1366px',
                    message: '取得焦點後元素仍在可視範圍外，使用者看不到焦點位置', count: kb.offscreen.length, nodes: kn(kb.offscreen) });
            }
            if (kb.trap) {
                add({ sc: '2.1.2', status: 'fail', check: 'keyboard-trap', viewport: '1366px',
                    message: '連續按 Tab 焦點停留在同一元素，疑似鍵盤陷阱', count: 1, nodes: kn([kb.trap]) });
            }

            log('  文字間距');
            await gotoPage(page, url);
            const before = new Set((await page.evaluate(collectClipped)).map(x => x.selector));
            await page.addStyleTag({ content: '*{line-height:1.5!important;letter-spacing:.12em!important;word-spacing:.16em!important}p{margin-bottom:2em!important}' });
            await sleep(500);
            const clipped = (await page.evaluate(collectClipped)).filter(x => !before.has(x.selector));
            if (clipped.length) {
                add({ sc: '1.4.12', status: 'review', check: 'text-spacing', viewport: '1366px',
                    message: '套用 WCAG 1.4.12 文字間距後新增被裁切的內容（overflow: hidden）', count: clipped.length, nodes: clipped.slice(0, 15) });
            }

            // 窄版 320px
            log('  重排（320px）');
            await page.setViewport({ width: 320, height: 640 });
            await gotoPage(page, url);
            const rf = await page.evaluate(checkReflow);
            rec.reflow = { scrollWidth: rf.sw, clientWidth: rf.W };
            if (rf.overflow) {
                const nonTable = rf.sources.filter(s => !s.table);
                if (nonTable.length || !rf.sources.length) {
                    add({ sc: '1.4.10', status: nonTable.length ? 'fail' : 'review', check: 'reflow', viewport: '320px',
                        message: `320px 寬時頁面出現水平捲動（內容寬 ${rf.sw}px）${rf.sources.length ? '' : '，但無法定位溢出來源'}`,
                        count: nonTable.length || 1, nodes: nonTable });
                }
                const tables = rf.sources.filter(s => s.table);
                if (tables.length) {
                    add({ sc: '1.4.10', status: 'review', check: 'reflow-table', viewport: '320px',
                        message: '資料表格造成水平捲動（資料表格可適用例外，建議外包可捲動容器避免整頁捲動）',
                        count: tables.length, nodes: tables });
                }
            }
            const toggler = await page.evaluate(findMenuToggler);
            let menuOpened = false;
            if (toggler) {
                const b4 = await page.evaluate(visibleLinkCount);
                const ex4 = await page.$eval(toggler, e => e.getAttribute('aria-expanded')).catch(() => null);
                await page.click(toggler).catch(() => {});
                await sleep(800);
                const af = await page.evaluate(visibleLinkCount);
                const exA = await page.$eval(toggler, e => e.getAttribute('aria-expanded')).catch(() => null);
                menuOpened = af > b4 || (exA === 'true' && ex4 !== 'true');
                rec.menu = { toggler, linksBefore: b4, linksAfter: af, ariaExpanded: [ex4, exA] };
                if (!menuOpened) {
                    add({ sc: '1.4.10', status: 'review', check: 'menu-toggle', viewport: '320px',
                        message: '窄版選單按鈕點擊後，可見連結數未增加且 aria-expanded 未變為 true，選單疑似無法展開（窄螢幕或放大時無法使用導覽）',
                        count: 1, nodes: [{ selector: toggler, detail: `可見連結 ${b4} → ${af}；aria-expanded ${ex4} → ${exA}` }] });
                }
            }
            log(`  axe（320px${menuOpened ? '，選單展開' : ''}）`);
            findings.push(...axeFindings(await runAxe(page, locale), menuOpened ? '320px（選單展開）' : '320px').map(f => ({ page: url, ...f })));
        } catch (e) {
            rec.error = String(e && e.message || e);
            log('  錯誤：' + rec.error);
        }
    }
    await browser.close();

    // ---- 彙整：同頁同檢查同準則合併（桌機與窄版重複者只留一筆）----
    const merged = new Map();
    for (const f of findings) {
        const k = [f.sc, f.status, f.check, f.page].join('|');
        if (!merged.has(k)) { merged.set(k, { ...f, viewports: [f.viewport] }); continue; }
        const m = merged.get(k);
        if (!m.viewports.includes(f.viewport)) m.viewports.push(f.viewport);
        const have = new Set(m.nodes.map(n => n.selector));
        const extra = f.nodes.filter(n => !have.has(n.selector));
        m.nodes.push(...extra);
        m.count += extra.length;
    }
    const all = [...merged.values()];
    const covered = new Set([...axeCovered, ...CUSTOM_COVER]);
    const bySc = new Map(SC.map(s => [s[0], []]));
    for (const f of all) if (bySc.has(f.sc)) bySc.get(f.sc).push(f);
    const statusOf = sc => {
        const l = bySc.get(sc);
        if (l.some(f => f.status === 'fail')) return 'fail';
        if (l.length) return 'review';
        return covered.has(sc) ? 'pass' : 'manual';
    };
    const summary = SC.map(([id, level, name, hint]) => ({ id, level, name, hint, status: statusOf(id), automated: covered.has(id) }));
    const cnt = s => summary.filter(x => x.status === s).length;
    const tested = pages.filter(p => !p.skipped && !p.error);

    const meta = {
        target: cfg.start, generatedAt: new Date().toISOString(), axeVersion, chrome: cfg.chrome,
        options: { maxPages: cfg.maxPages, crawl: cfg.crawl, bust: cfg.bust, tabs: cfg.tabs },
        counts: { fail: cnt('fail'), review: cnt('review'), pass: cnt('pass'), manual: cnt('manual') },
    };
    fs.writeFileSync(path.join(cfg.outDir, 'wcag-result.json'), JSON.stringify({ meta, summary, pages, findings: all }, null, 2));

    // ---- Markdown 報告 ----
    const esc = s => String(s == null ? '' : s).replace(/\|/g, '\\|').replace(/[\r\n]+/g, ' ');
    const code = s => '`' + String(s).replace(/`/g, "'") + '`';
    const LABEL = { fail: '❌ 不符合', review: '⚠️ 需人工確認', pass: '✅ 自動檢測未發現問題', manual: '📝 僅能人工檢核' };
    const L = [];
    const local = new Date().toLocaleString('zh-TW', { hour12: false });
    L.push('# WCAG 2.2 AA 自動化檢核報告', '');
    L.push(`- 目標網址：${cfg.start}`);
    L.push(`- 檢測時間：${local}`);
    L.push(`- 檢測頁數：${tested.length}（略過 ${pages.filter(p => p.skipped).length}、錯誤 ${pages.filter(p => p.error).length}）`);
    L.push(`- 工具：axe-core ${axeVersion}（WCAG 2.0/2.1/2.2 A、AA 規則）＋ 自訂鍵盤、重排、文字間距、表單檢查`);
    L.push(`- 檢視寬度：桌機 1366px、窄版 320px`, '');
    L.push('## 結論', '');
    if (meta.counts.fail) {
        L.push(`**未符合 WCAG 2.2 AA**：${meta.counts.fail} 項準則有不符合項目，另有 ${meta.counts.review} 項需人工確認。`);
    } else if (meta.counts.review) {
        L.push(`**自動化檢測未發現不符合項目**，但有 ${meta.counts.review} 項需人工確認，尚不能判定符合。`);
    } else {
        L.push('**自動化檢測未發現不符合或待確認項目。**');
    }
    L.push('', `> 自動化檢測約只能涵蓋三到四成的準則。「僅能人工檢核」的 ${meta.counts.manual} 項，以及「自動檢測未發現問題」的項目，仍需以鍵盤操作與螢幕報讀軟體（如 NVDA）實際確認，才能宣告符合。`, '');

    L.push('## 準則總表', '', '| 準則 | 等級 | 名稱 | 結果 | 不符合／待確認 |', '|:---|:---|:---|:---|:---|');
    for (const s of summary) {
        const l = bySc.get(s.id);
        const fails = l.filter(f => f.status === 'fail'), revs = l.filter(f => f.status === 'review');
        const pagesOf = arr => new Set(arr.map(f => f.page)).size;
        const note = [fails.length ? `不符合 ${fails.reduce((a, f) => a + f.count, 0)} 處／${pagesOf(fails)} 頁` : '',
            revs.length ? `待確認 ${revs.reduce((a, f) => a + f.count, 0)} 處／${pagesOf(revs)} 頁` : ''].filter(Boolean).join('；');
        L.push(`| ${s.id} | ${s.level} | ${esc(s.name)} | ${LABEL[s.status]} | ${esc(note)} |`);
    }
    L.push('');

    const detail = (status, title) => {
        const scs = summary.filter(s => bySc.get(s.id).some(f => f.status === status));
        if (!scs.length) return;
        L.push(`## ${title}`, '');
        for (const s of scs) {
            L.push(`### ${s.id} ${s.name}（${s.level}）`, '');
            const byCheck = new Map();
            for (const f of bySc.get(s.id).filter(f => f.status === status)) {
                if (!byCheck.has(f.check)) byCheck.set(f.check, []);
                byCheck.get(f.check).push(f);
            }
            for (const [check, list] of byCheck) {
                const f0 = list[0];
                L.push(`**${esc(f0.message)}**　${code(check)}${f0.helpUrl ? `　[說明](${f0.helpUrl})` : ''}`, '');
                for (const f of list) {
                    L.push(`- ${f.page}（${f.viewports.join('、')}）共 ${f.count} 處`);
                    for (const n of f.nodes.slice(0, 5)) {
                        L.push(`  - ${n.selector ? code(n.selector) : ''}${n.detail ? ' — ' + esc(n.detail) : ''}`);
                    }
                    if (f.nodes.length > 5) L.push(`  - …其餘 ${f.nodes.length - 5} 處見 wcag-result.json`);
                }
                L.push('');
            }
        }
    };
    detail('fail', '不符合項目');
    detail('review', '需人工確認項目');

    L.push('## 僅能人工檢核的準則', '', '| 準則 | 等級 | 名稱 | 檢核要點 |', '|:---|:---|:---|:---|');
    for (const s of summary.filter(s => s.status === 'manual')) L.push(`| ${s.id} | ${s.level} | ${esc(s.name)} | ${esc(s.hint)} |`);
    L.push('');
    L.push('## 自動檢測未發現問題、仍建議人工抽查的準則', '', '| 準則 | 等級 | 名稱 | 檢核要點 |', '|:---|:---|:---|:---|');
    for (const s of summary.filter(s => s.status === 'pass')) L.push(`| ${s.id} | ${s.level} | ${esc(s.name)} | ${esc(s.hint)} |`);
    L.push('');

    L.push('## 檢測頁面', '', '| # | 網址 | HTTP | 標題 | 可聚焦元素 | 320px 內容寬 | 備註 |', '|:---|:---|:---|:---|:---|:---|:---|');
    pages.forEach((p, i) => {
        L.push(`| ${i + 1} | ${esc(p.url)} | ${p.status ?? ''} | ${esc(p.title)} | ${p.keyboard ? p.keyboard.focusable : ''} | ${p.reflow ? p.reflow.scrollWidth + 'px' : ''} | ${esc(p.skipped || p.error || '')} |`);
    });
    L.push('', '---', '', '- 「不符合」為自動判定，仍建議逐項目視確認；「需人工確認」為工具無法判定或啟發式偵測的疑似問題。',
        '- 鍵盤走訪每頁最多 ' + cfg.tabs + ' 次 Tab，僅檢查焦點可見、遮蔽與陷阱；對話框、下拉選單等互動流程未自動操作。',
        '- 原始結果：wcag-result.json；HTML 版：wcag-report.html', '');
    const reportPath = path.join(cfg.outDir, 'wcag-report.md');
    fs.writeFileSync(reportPath, L.join('\n'));

    // ---- HTML 報告（單一檔案、無外部資源，報告本身亦依 WCAG 2.2 AA 設計）----
    const h = s => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    const safeUrl = u => /^https?:\/\//i.test(String(u || '')) ? h(u) : '';
    const HLABEL = { fail: '不符合', review: '需人工確認', pass: '自動檢測未發現問題', manual: '僅能人工檢核' };
    const HICON = { fail: '✕', review: '!', pass: '✓', manual: '✎' };
    const badge = st => `<span class="badge ${st}"><span aria-hidden="true">${HICON[st]}</span> ${HLABEL[st]}</span>`;
    const pagesOf = arr => new Set(arr.map(f => f.page)).size;
    const H = [];
    const verdict = meta.counts.fail
        ? `<p class="verdict fail"><strong>未符合 WCAG 2.2 AA</strong>：${meta.counts.fail} 項準則有不符合項目，另有 ${meta.counts.review} 項需人工確認。</p>`
        : meta.counts.review
            ? `<p class="verdict review"><strong>自動化檢測未發現不符合項目</strong>，但有 ${meta.counts.review} 項需人工確認，尚不能判定符合。</p>`
            : '<p class="verdict pass"><strong>自動化檢測未發現不符合或待確認項目。</strong></p>';
    H.push(`<!doctype html>
<html lang="zh-Hant-TW">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WCAG 2.2 AA 自動化檢核報告 - ${h(new URL(cfg.start).host)}</title>
<style>
:root{--bg:#fff;--fg:#1d2939;--muted:#475467;--line:#d0d5dd;--card:#f9fafb;--link:#0b57d0;
--fail-fg:#b42318;--fail-bg:#fef3f2;--review-fg:#8a4b00;--review-bg:#fffaeb;--pass-fg:#067647;--pass-bg:#ecfdf3;--manual-fg:#344054;--manual-bg:#f2f4f7}
@media (prefers-color-scheme:dark){:root{--bg:#101828;--fg:#f2f4f7;--muted:#c0c6d0;--line:#3b4556;--card:#182230;--link:#8ab4f8;
--fail-fg:#fda29b;--fail-bg:#3b1515;--review-fg:#fec84b;--review-bg:#332508;--pass-fg:#75e0a7;--pass-bg:#0b2e1f;--manual-fg:#d0d5dd;--manual-bg:#253041}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 system-ui,-apple-system,"Segoe UI","Noto Sans TC","Microsoft JhengHei",sans-serif}
main{max-width:1200px;margin:0 auto;padding:24px 16px 48px}
a{color:var(--link)} a:focus-visible,summary:focus-visible,button:focus-visible{outline:3px solid var(--link);outline-offset:2px}
.skip{position:absolute;left:-9999px;top:0;background:var(--bg);padding:8px 12px;z-index:9}.skip:focus{left:8px}
h1{font-size:1.75rem;margin:0 0 8px}h2{font-size:1.35rem;margin:40px 0 12px;padding-bottom:6px;border-bottom:2px solid var(--line)}
h3{font-size:1.1rem;margin:0}
dl.meta{display:grid;grid-template-columns:max-content 1fr;gap:4px 16px;margin:12px 0;color:var(--muted)}dl.meta dt{font-weight:600}dl.meta dd{margin:0;overflow-wrap:anywhere}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin:16px 0}
.card{border-radius:10px;padding:14px 16px;border:1px solid var(--line)}
.card .n{font-size:2rem;font-weight:700;line-height:1.2;display:block}
.card.fail{background:var(--fail-bg);color:var(--fail-fg)}.card.review{background:var(--review-bg);color:var(--review-fg)}
.card.pass{background:var(--pass-bg);color:var(--pass-fg)}.card.manual{background:var(--manual-bg);color:var(--manual-fg)}
.verdict{padding:12px 16px;border-radius:8px;border-left:6px solid}
.verdict.fail{background:var(--fail-bg);border-color:var(--fail-fg)}.verdict.review{background:var(--review-bg);border-color:var(--review-fg)}.verdict.pass{background:var(--pass-bg);border-color:var(--pass-fg)}
.note{color:var(--muted);font-size:.95rem}
.badge{display:inline-block;white-space:nowrap;border-radius:999px;padding:1px 10px;font-size:.875rem;font-weight:600}
.badge.fail{background:var(--fail-bg);color:var(--fail-fg)}.badge.review{background:var(--review-bg);color:var(--review-fg)}
.badge.pass{background:var(--pass-bg);color:var(--pass-fg)}.badge.manual{background:var(--manual-bg);color:var(--manual-fg)}
.tw{overflow-x:auto;border:1px solid var(--line);border-radius:8px}
table{border-collapse:collapse;width:100%;font-size:.95rem}
caption{text-align:left;padding:8px 12px;font-weight:600}
th,td{padding:8px 12px;border-top:1px solid var(--line);text-align:left;vertical-align:top}
thead th{background:var(--card);border-top:0;white-space:nowrap}
tbody tr.st-fail{background:color-mix(in srgb,var(--fail-bg) 60%,transparent)}
.filter{display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center;margin:8px 0 12px;border:1px solid var(--line);border-radius:8px;padding:8px 12px}
.filter label{display:inline-flex;gap:6px;align-items:center;min-height:24px;cursor:pointer}
.filter input{width:18px;height:18px}
details.sc{border:1px solid var(--line);border-radius:8px;margin:12px 0;background:var(--card)}
details.sc>summary{cursor:pointer;padding:12px 16px;display:flex;gap:12px;align-items:center;flex-wrap:wrap}
details.sc>summary h3{display:inline}
details.sc .body{padding:0 16px 12px}
.check{margin:12px 0;padding:12px;border-radius:6px;background:var(--bg);border:1px solid var(--line)}
.check p{margin:0 0 8px}
.check ul{margin:4px 0;padding-left:20px}.check li{margin:4px 0;overflow-wrap:anywhere}
code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:.875em;background:var(--manual-bg);padding:1px 5px;border-radius:4px;overflow-wrap:anywhere}
.tag{font-size:.8rem;color:var(--muted)}
footer{margin-top:40px;color:var(--muted);font-size:.9rem}
@media print{.filter,.skip{display:none}details.sc{break-inside:avoid}details.sc:not([open])>.body{display:block}}
</style>
</head>
<body>
<a class="skip" href="#main">跳至主要內容</a>
<main id="main">
<h1>WCAG 2.2 AA 自動化檢核報告</h1>
<dl class="meta">
<dt>目標網址</dt><dd><a href="${safeUrl(cfg.start)}">${h(cfg.start)}</a></dd>
<dt>檢測時間</dt><dd>${h(local)}</dd>
<dt>檢測頁數</dt><dd>${tested.length}（略過 ${pages.filter(p => p.skipped).length}、錯誤 ${pages.filter(p => p.error).length}）</dd>
<dt>工具</dt><dd>axe-core ${h(axeVersion)}（WCAG 2.0/2.1/2.2 A、AA 規則）＋ 自訂鍵盤、重排、文字間距、表單檢查</dd>
<dt>檢視寬度</dt><dd>桌機 1366px、窄版 320px</dd>
</dl>
<section aria-labelledby="h-sum">
<h2 id="h-sum">結論</h2>
${verdict}
<div class="cards">
${['fail', 'review', 'pass', 'manual'].map(st => `<div class="card ${st}"><span class="n">${meta.counts[st]}</span>${HLABEL[st]}</div>`).join('\n')}
</div>
<p class="note">自動化檢測約只能涵蓋三到四成的準則。「僅能人工檢核」的 ${meta.counts.manual} 項，以及「自動檢測未發現問題」的項目，仍需以鍵盤操作與螢幕報讀軟體（如 NVDA）實際確認，才能宣告符合。</p>
</section>`);

    // 準則總表
    H.push(`<section aria-labelledby="h-table">
<h2 id="h-table">準則總表</h2>
<fieldset class="filter" id="flt"><legend class="tag">顯示結果：</legend>
${['fail', 'review', 'pass', 'manual'].map(st => `<label><input type="checkbox" value="${st}" checked> ${HLABEL[st]}（${meta.counts[st]}）</label>`).join('\n')}
</fieldset>
<p class="note" id="flt-status" role="status" aria-live="polite"></p>
<div class="tw" tabindex="0" role="region" aria-label="準則總表"><table id="sc-table">
<caption>55 項 WCAG 2.2 A／AA 成功準則檢測結果</caption>
<thead><tr><th scope="col">準則</th><th scope="col">等級</th><th scope="col">名稱</th><th scope="col">結果</th><th scope="col">不符合／待確認</th></tr></thead>
<tbody>`);
    for (const s of summary) {
        const l = bySc.get(s.id);
        const fails = l.filter(f => f.status === 'fail'), revs = l.filter(f => f.status === 'review');
        const note = [fails.length ? `不符合 ${fails.reduce((a, f) => a + f.count, 0)} 處／${pagesOf(fails)} 頁` : '',
            revs.length ? `待確認 ${revs.reduce((a, f) => a + f.count, 0)} 處／${pagesOf(revs)} 頁` : ''].filter(Boolean).join('；');
        const idCell = l.length ? `<a href="#sc-${h(s.id)}">${h(s.id)}</a>` : h(s.id);
        H.push(`<tr class="st-${s.status}" data-status="${s.status}"><th scope="row">${idCell}</th><td>${h(s.level)}</td><td>${h(s.name)}</td><td>${badge(s.status)}</td><td>${h(note) || (s.status === 'manual' ? `<span class="tag">${h(s.hint)}</span>` : '')}</td></tr>`);
    }
    H.push('</tbody></table></div></section>');

    // 明細
    const hdetail = (status, title, hid) => {
        const scs = summary.filter(s => bySc.get(s.id).some(f => f.status === status));
        if (!scs.length) return;
        H.push(`<section aria-labelledby="${hid}"><h2 id="${hid}">${title}（${scs.length} 項準則）</h2>`);
        for (const s of scs) {
            const list = bySc.get(s.id).filter(f => f.status === status);
            const anchor = (status === 'fail' || s.status !== 'fail') ? ` id="sc-${h(s.id)}"` : '';
            H.push(`<details class="sc"${anchor}${status === 'fail' ? ' open' : ''}><summary><h3>${h(s.id)} ${h(s.name)}（${h(s.level)}）</h3>${badge(status)}<span class="tag">${list.reduce((a, f) => a + f.count, 0)} 處／${pagesOf(list)} 頁</span></summary><div class="body">`);
            const byCheck = new Map();
            for (const f of list) {
                if (!byCheck.has(f.check)) byCheck.set(f.check, []);
                byCheck.get(f.check).push(f);
            }
            for (const [check, fl] of byCheck) {
                const f0 = fl[0];
                H.push(`<div class="check"><p><strong>${h(f0.message)}</strong> <code>${h(check)}</code>${f0.helpUrl && safeUrl(f0.helpUrl) ? ` <a href="${safeUrl(f0.helpUrl)}" target="_blank" rel="noopener">規則說明<span class="tag">（另開視窗）</span></a>` : ''}</p><ul>`);
                for (const f of fl) {
                    H.push(`<li><a href="${safeUrl(f.page)}" target="_blank" rel="noopener">${h(f.page)}</a> <span class="tag">（${h(f.viewports.join('、'))}）共 ${f.count} 處</span><ul>`);
                    for (const n of f.nodes.slice(0, 20)) {
                        H.push(`<li>${n.selector ? `<code>${h(n.selector)}</code>` : ''}${n.detail ? ' — ' + h(n.detail) : ''}</li>`);
                    }
                    if (f.nodes.length > 20) H.push(`<li class="tag">…其餘 ${f.nodes.length - 20} 處見 wcag-result.json</li>`);
                    H.push('</ul></li>');
                }
                H.push('</ul></div>');
            }
            H.push('</div></details>');
        }
        H.push('</section>');
    };
    hdetail('fail', '不符合項目', 'h-fail');
    hdetail('review', '需人工確認項目', 'h-review');

    const hintTable = (st, title, hid) => {
        const rows = summary.filter(s => s.status === st);
        if (!rows.length) return;
        H.push(`<section aria-labelledby="${hid}"><h2 id="${hid}">${title}（${rows.length} 項）</h2><div class="tw" tabindex="0" role="region" aria-label="${title}"><table>
<thead><tr><th scope="col">準則</th><th scope="col">等級</th><th scope="col">名稱</th><th scope="col">檢核要點</th></tr></thead><tbody>`);
        for (const s of rows) H.push(`<tr><th scope="row">${h(s.id)}</th><td>${h(s.level)}</td><td>${h(s.name)}</td><td>${h(s.hint)}</td></tr>`);
        H.push('</tbody></table></div></section>');
    };
    hintTable('manual', '僅能人工檢核的準則', 'h-manual');
    hintTable('pass', '自動檢測未發現問題、仍建議人工抽查的準則', 'h-pass');

    H.push(`<section aria-labelledby="h-pages"><h2 id="h-pages">檢測頁面（${pages.length}）</h2><div class="tw" tabindex="0" role="region" aria-label="檢測頁面"><table>
<thead><tr><th scope="col">#</th><th scope="col">網址</th><th scope="col">HTTP</th><th scope="col">標題</th><th scope="col">可聚焦元素</th><th scope="col">320px 內容寬</th><th scope="col">備註</th></tr></thead><tbody>`);
    pages.forEach((p, i) => {
        H.push(`<tr><th scope="row">${i + 1}</th><td style="overflow-wrap:anywhere"><a href="${safeUrl(p.url)}" target="_blank" rel="noopener">${h(p.url)}</a></td><td>${h(p.status ?? '')}</td><td>${h(p.title)}</td><td>${p.keyboard ? p.keyboard.focusable : ''}</td><td>${p.reflow ? p.reflow.scrollWidth + 'px' : ''}</td><td>${h(p.skipped || p.error || '')}</td></tr>`);
    });
    H.push(`</tbody></table></div></section>
<footer>
<ul>
<li>「不符合」為自動判定，仍建議逐項目視確認；「需人工確認」為工具無法判定或啟發式偵測的疑似問題。</li>
<li>鍵盤走訪每頁最多 ${cfg.tabs} 次 Tab，僅檢查焦點可見、遮蔽與陷阱；對話框、下拉選單等互動流程未自動操作。</li>
<li>原始結果：wcag-result.json；Markdown 版：wcag-report.md</li>
</ul>
</footer>
</main>
<script>
(function () {
  var boxes = document.querySelectorAll('#flt input'), rows = document.querySelectorAll('#sc-table tbody tr'), out = document.getElementById('flt-status');
  function apply() {
    var on = {}, n = 0;
    boxes.forEach(function (b) { on[b.value] = b.checked; });
    rows.forEach(function (r) { var v = !!on[r.dataset.status]; r.hidden = !v; if (v) n++; });
    out.textContent = '顯示 ' + n + ' / ' + rows.length + ' 項準則';
  }
  boxes.forEach(function (b) { b.addEventListener('change', apply); });
  apply();
})();
</script>
</body>
</html>
`);
    const htmlPath = path.join(cfg.outDir, 'wcag-report.html');
    fs.writeFileSync(htmlPath, H.join('\n'));

    console.log('');
    console.log(`檢測完成：${tested.length} 頁`);
    console.log(`  ❌ 不符合        ${meta.counts.fail} 項準則`);
    console.log(`  ⚠️ 需人工確認    ${meta.counts.review} 項準則`);
    console.log(`  ✅ 未發現問題    ${meta.counts.pass} 項準則`);
    console.log(`  📝 僅能人工檢核  ${meta.counts.manual} 項準則`);
    console.log(`報告（HTML）：${htmlPath}`);
    console.log(`報告（Markdown）：${reportPath}`);
    console.log(`原始結果：${path.join(cfg.outDir, 'wcag-result.json')}`);
    process.exitCode = meta.counts.fail ? 2 : 0;
})().catch(e => { console.error('執行失敗：', e && e.stack || e); process.exit(1); });
JS

# ---- 執行 ----
EXTRA_LIST=""
if [[ ${#EXTRA[@]} -gt 0 ]]; then EXTRA_LIST="$(printf '%s\n' "${EXTRA[@]}")"; fi

set +e
WCAG_START="$URL" \
WCAG_EXTRA="$EXTRA_LIST" \
WCAG_MAX_PAGES="$MAX_PAGES" \
WCAG_CRAWL="$CRAWL" \
WCAG_BUST="$BUST" \
WCAG_TABS="$TABS" \
WCAG_TIMEOUT="$TIMEOUT" \
WCAG_INSECURE="$INSECURE" \
WCAG_EXCLUDE="$EXCLUDE" \
WCAG_OUT="$OUT" \
WCAG_CHROME="$CHROME" \
node "$RUNNER"
rc=$?
set -e
exit $rc
