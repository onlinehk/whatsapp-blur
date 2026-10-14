# WhatsApp Blur

一個 macOS menu bar 小工具，幫 **WhatsApp Mac 桌面版** 加上私隱模糊效果：只 blur 訊息、名稱、頭像等內容，滑鼠 hover 上去就即刻清晰返。效果同 Chrome extension「Privacy Extension for WhatsApp Web」一樣，不過係用喺原生 WhatsApp app 上面。

適合喺咖啡店、辦公室、screen share 或者開會投影嘅時候用，唔使驚身邊人或者觀眾睇到你啲對話。

## 功能

㩒 menu bar 嘅眼睛 icon 會打開設定面板：

| 設定 | 作用 |
|---|---|
| Toggle | 總開關（全域快捷鍵 **⌃⌥B**） |
| All messages in chat | Blur 對話入面嘅文字訊息 |
| Last messages preview | Blur 對話列表每行嘅最後訊息預覽 |
| Media preview | Blur 對話入面嘅相、影片、貼圖、GIF |
| Media gallery | Blur「媒體」tab 嘅縮圖 |
| Text input | Blur 輸入框 |
| Profile pictures | Blur 列表頭像、對話 header 頭像、group 訊息旁邊嘅頭像 |
| Group/Users names | Blur 列表名稱同對話 header 名稱 |
| No transition delay | Hover 時即刻清晰（預設會用 0.2 秒淡出淡入） |
| Unblur all on app hover | 滑鼠喺 WhatsApp 視窗入面時，全部變清晰 |
| Blur WhatsApp on Idle | 一段時間冇郁鍵盤滑鼠，就 blur 成個 WhatsApp 視窗 |

有 ⚙ 嘅項目可以獨立調較 blur 強度；Idle 嗰項可以揀 15 秒、30 秒、1 分鐘或 5 分鐘。

## 系統要求

- macOS 14 或以上（喺 macOS 26 開發同測試）
- WhatsApp Mac 官方 app（Mac Catalyst 版，bundle ID `net.whatsapp.WhatsApp`），測試版本 26.38.74
- Xcode Command Line Tools（Swift 5.9+）

## 安裝同使用

1. Build：

   ```bash
   ./build.sh
   ```

   會產生 `build/WhatsAppBlur.app`。

2. 開啟：

   ```bash
   open build/WhatsAppBlur.app
   ```

   想開機自動啟動，可以將 app 放入「應用程式」，再喺「系統設定 → 一般 → 登入項目」加入。

3. 第一次開會彈出要求 **輔助使用（Accessibility）** 權限：去「系統設定 → 私隱與保安 → 輔助使用」，開啟 **WhatsApp Blur**。開咗之後唔使重開，幾秒內就會生效。

App 唔需要「螢幕錄影」權限。

### Code signing

`build.sh` 預設用 `Apple Development: Raymond Lau (89PBA7F683)` 簽名。用固定嘅簽名身份，重新 build 之後先唔使再批一次輔助使用權限。要用其他證書：

```bash
CODESIGN_IDENTITY="Apple Development: 你的名 (XXXXXXXXXX)" ./build.sh
```

如果搵唔到嗰個證書，會自動改用 ad-hoc 簽名，但每次 build 完都要重新批權限。

## 運作原理

WhatsApp Mac 版係原生 app，唔係網頁，所以唔可以好似 extension 咁注入 CSS。呢個 app 嘅做法係：

1. **讀位置**：用 macOS Accessibility API 讀 WhatsApp 嘅介面結構。WhatsApp 有穩定嘅識別碼（例如 `ChatListView_TableView`、`ChatMessagesTableView`、`MediaGalleryCollectionView`），每個對話列、訊息氣泡同縮圖都有自己嘅螢幕位置。每秒讀大約 15 次，只讀可見嘅部分。
2. **蓋 blur**：喺 WhatsApp 視窗上面放一個透明、滑鼠可以穿透嘅視窗，喺每個要 blur 嘅位置放一塊 Gaussian blur。Blur 係即時處理後面嘅畫面，所以文字更新都會即刻 blur 到。
3. **Hover**：滑鼠喺邊個項目上面，就隱藏嗰塊 blur。
4. **移動中**：Scroll、轉對話、拖視窗嗰陣，位置會慢少少，所以會暫時 blur 成個區域，停低之後再變返逐個項目 blur。
5. **視窗次序**：Blur 視窗會一直貼住喺 WhatsApp 視窗上面，其他 app 嘅視窗照樣可以蓋過佢。

## 限制

- **相片判斷靠關鍵字**：媒體訊息係靠 WhatsApp 讀屏描述入面嘅「相片 / 影片 / 貼圖 / GIF / Photo / Video…」等字判斷。WhatsApp 用其他語言或者改咗描述格式，相片可能會當成文字訊息處理。
- **部分位置靠版面推算**：對話列表每行入面嘅頭像、名稱、預覽，以及 group 訊息旁邊嘅頭像，WhatsApp 冇提供個別位置，係按現時版面計出嚟。WhatsApp 改版面或者改字體大小，可能會對唔準。
- **新訊息有極短空隙**：新訊息出現到被 blur，最多有大約 70 毫秒。
- **用咗 Apple private API**：Gaussian blur 用咗 Core Animation 嘅 private class（`CABackdropLayer`、`CAFilter`）。如果將來 macOS 拎走咗，會自動改用系統磨砂效果，內容唔會因此露出嚟。
- **WhatsApp 更新**：如果 WhatsApp 改咗介面識別碼，app 可能要跟住更新。
- **Group 發送者名稱**：Group 訊息入面嘅發送者名稱包喺訊息 blur 入面，冇獨立開關。

## 疑難排解

| 問題 | 解決方法 |
|---|---|
| 完全冇 blur | 檢查「輔助使用」入面 WhatsApp Blur 有冇開；面板底部顯示 "Needs Accessibility permission" 即係未批 |
| 重新 build 之後冇 blur | 簽名身份變咗：喺「輔助使用」移除 WhatsApp Blur，再重新加入 |
| Blur 位置對唔準 | 將 WhatsApp 字體大小設返預設；或者 WhatsApp 改咗版面，要調整 `AXScanner.swift` 入面嘅 `chatRowParts` / `groupAvatars` |
| 面板顯示 "WhatsApp window not visible" | WhatsApp 視窗縮細咗、喺其他桌面（Space），或者未開 |

## 專案結構

```
Package.swift                 Swift Package 設定
build.sh                      Build、打包成 .app、簽名
Resources/Info.plist          App 資料（menu bar app，冇 Dock icon）
Sources/WhatsAppBlur/
  main.swift                  程式入口
  AppDelegate.swift           Menu bar icon、設定面板、快捷鍵
  AXScanner.swift             讀取 WhatsApp 介面元素同位置
  OverlayController.swift     Blur 視窗、hover、scroll、idle 處理
  GaussianBlurView.swift      Gaussian blur view
  SettingsView.swift          SwiftUI 設定面板
  Settings.swift              設定（UserDefaults）
  HotKey.swift                全域快捷鍵 ⌃⌥B
```

## 備註

本 app 同 WhatsApp 或 Meta 冇任何關係。WhatsApp 係 Meta Platforms, Inc. 嘅商標。
