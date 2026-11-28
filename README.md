<p align="center">
  <img src="docs/icon.png" width="120" height="120" alt="iPac">
</p>

<h1 align="center">iPac</h1>

<p align="center">在 iPad 與 iPhone 上執行隨身 macOS（支援 USB-C 外接 SSD 隨插即用、跨機型硬體自動適配、完整繁體中文介面）</p>
<p align="center">Portable macOS on iPad &amp; iPhone with USB-C external SSD plug-and-play &amp; Traditional Chinese UI — based on <a href="https://github.com/Leviidev/Henge">Henge</a>.</p>

<p align="center">
  <a href="#安裝與下載">立即下載 / 安裝</a>
  ·
  <a href="#外接-usb-c-ssd-隨身-macos">隨身 SSD 教學</a>
  ·
  <a href="#從舊版-henge-覆蓋升級與-esign-簽名說明">覆蓋升級與 ESign 簽名</a>
  ·
  <a href="docs/architecture.md">架構原理</a>
  ·
  <a href="https://github.com/iancheng64-cmd/ipac/releases">Releases</a>
</p>

<p align="center">
  <a href="https://github.com/iancheng64-cmd/ipac/releases"><img src="https://img.shields.io/github/downloads/iancheng64-cmd/ipac/total?style=flat-square&color=2E6BFF&labelColor=111111" alt="Downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/iancheng64-cmd/ipac?style=flat-square&color=2E6BFF&labelColor=111111" alt="GPL-2.0-or-later"></a>
</p>

---

**iPac** 是基於開源專案 [`Leviidev/Henge`](https://github.com/Leviidev/Henge) 深度強化與繁體中文化的分支版本。除了保留免電腦直接從 Apple CDN 下載並還原安裝 macOS、Metal GPU 渲染加速、Magic Trackpad 觸控手勢與外接鍵盤滑鼠直通等核心功能外，更專為 **隨身外接 USB-C SSD**、**跨多台 iPad 隨插即用**、**安全退出與白名單清除 SSD** 及 **完整繁體中文體驗** 而打造。

---

## 核心特色

### 自動解鎖最大記憶體（整合 GetMoreRam / iRAM+）與單機 RAM／CPU 動態調整（v0.4.1 更新）

- **啟動時自動檢查與背景解鎖最大記憶體（免手動步驟）**：
  - 結合 `StosSign`、`GetMoreRam` 與 `iRAM+` 的 Apple Developer Services 能力寫入技術：若透過完整授權／支援大記憶體的憑證安裝，**一打開 iPac 即已具備最大可用記憶體**，不會彈出任何登入或設定視窗。
  - 若使用 SideStore／AltStore 免費簽名安裝導致 `INCREASED_MEMORY_LIMIT` 權限尚未寫入 Apple 帳號：只需在首頁提示（或「**設定 › 記憶體配額**」）登入一次 Apple ID 或匯入 SideStore 帳號 `.json`，iPac 就會**自動辨識目前 Bundle ID 並開啟權限**（付費開發者團隊會同時請求 `EXTENDED_VIRTUAL_ADDRESSING`，不支援則自動退回 `INCREASED_MEMORY_LIMIT`），完成後更可一鍵跳轉 **SideStore／AltStore** 重新 Refresh 一次永久生效；之後每次重裝或開啟 App 也會於背景自動檢查維持。
- **核心免計入上限與分配最佳化（No Footprint）**：
  - 當 JIT 除錯器附加後，虛擬 Mac 記憶體透過 iOS 核心 `mach_memory_entry_ownership(..., LEDGER_NO_FOOTPRINT)` 直接略過 App 記憶體配額計算；修正了記憶體預留量重複扣除 JIT 快取空間的問題，也不再因 iPad 本機剩餘磁碟空間而限制免計入上限的虛擬記憶體。
- **關機後隨時調整單機 RAM 與 CPU 核心數**：
  - 在任何一台 Mac 的「**設定**」頁面（即使是使用外接隨身 SSD 的 Mac），只要處於關機狀態皆可隨時調整 **記憶體容量**（例如從 4 GB 調升為 6 GB，提供快捷按鈕）與 **該台 Mac 專屬的 CPU 核心數（最高 8 核心）**，設定即時儲存，下次開機自動生效並自動清除過時的即時續玩快照以確保新規格正確載入。

### 外接 USB-C SSD 隨身 macOS

可將整套 macOS 虛擬機裝進一顆外接 USB-C SSD，帶著它插上另一台已安裝 iPac 的 iPad 就能直接開機使用（**無需搬移或複製 64 GB 映像檔到 iPad 本機**）。

iPac 在「**安裝**」分頁提供三種安裝儲存模式：

| 模式 | 安裝檔 / 暫存檔存放位置 | 完成後的 Mac 存放位置 | 適用情境 |
| --- | --- | --- | --- |
| **本機儲存（原始模式）** | 此 iPad / iPhone 本機 | 此 iPad / iPhone 本機 | 本機剩餘空間充足（≥ 43 GB） |
| **外接安裝 → 存回本機** | 外接 USB-C SSD（`HengeInstall/`，完成後自動清除） | 此 iPad / iPhone 本機 | 本機空間較緊（例如 64 GB iPad），裝完即可拔除硬碟使用 |
| **完整外接 SSD（隨身模式）** | 外接 USB-C SSD（`HengeInstall/`，完成後自動清除） | 外接 USB-C SSD（`HengeMachines/<UUID>/`） | **隨身帶著走**：幾乎不佔 iPad 本機空間，插到別台 iPad 透過「從外接硬碟開啟隨身 Mac…」即可開機 |

- **支援本機與外接雙向搬移**：在任何一台 Mac 的「設定」頁面中，可隨時「搬移至外接 SSD」或「搬回此 iPad 本機空間」（採用先複製到 `.moving` 暫存目錄並驗證 `disk.img` 後才切換的安全流程）。
- **檔案系統建議（APFS vs exFAT）**：
  - **推薦格式化為 APFS**：支援稀疏檔案（Sparse File），64 GB 虛擬磁碟實際僅佔已寫入大小（全新約 20–25 GB），建立磁碟瞬間完成。
  - **exFAT**：不支援稀疏檔案，會直接寫滿 64 GB 且建立時需數分鐘，同時與 APFS 皆可正常跨裝置讀寫（不支援唯讀 NTFS）。
- **本機緩衝保護**：虛擬機執行時需要的 `ram.tmp` 記憶體緩衝檔案固定建立於 iPad 內部高速 APFS（`Application Support/Machines/ram.tmp`），不會損耗或拖慢外接 USB-C 隨身碟。

### 跨裝置硬體自動適配

將外接 SSD 插上不同世代／不同記憶體大小的 iPad 時，開啟「**隨身 SSD 自動適配**」（外接隨身 Mac 預設開啟），iPac 會保留同一套 macOS 系統身分、ECID 與所有個人資料，並於啟動時自動依據目前這台 iPad 調整：

- **安全記憶體上限**：自動依照目前主機實體記憶體套用安全建議值（例如 16 GB 機型 → 8 GB、12 GB 機型 → 6 GB、8 GB 機型 → 4 GB、6 GB → 3 GB、4 GB → 2 GB），避免跨機造成 OOM 閃退。
- **安全 CPU 核心上限**：自動依主機核心數限制安全可用核心數。
- **螢幕比例與更新率**：自動配合當下這台 iPad 的螢幕長寬比（無黑邊）與 Retina 解析度設定，並於非 ProMotion（60 Hz）裝置自動鎖定最高 60 Hz 更新率。

### 安全退出與白名單安全清除 SSD

為保護外接 SSD 內的個人資料不被破壞，iPac 提供兩套獨立機制（於「**設定**」、「**安裝**」與個別 Mac 設定頁面皆可操作）：

1. **安全退出 SSD（保留所有資料）**
   - 先確認目前無執行中的 macOS 或磁碟搬移／匯出／安裝任務。
   - 自動解除 iPadOS `Security-Scoped Bookmark` 沙盒檔案存取權限並清理掛載紀錄。
   - **不會刪除** SSD 內的 macOS 映像與任何個人資料，之後插上同一台或別台 iPad 皆可隨時重新開啟。
   - 若同顆硬碟同時掛載多台 Mac，單台退出最後一台時會自動釋放整顆 SSD 的沙盒鎖定。
2. **清除 SSD 上的 iPac / Henge 資料（白名單機制）**
   - 清除前先統計將釋放的容量與包含的 Mac / `HengeInstall/` 暫存數量並二次確認。
   - 僅依固定白名單刪除已知虛擬機檔案（`disk.img`、`disk.img.hvsparse`、`AVPBooter.vmapple2.bin`、`auxiliary.bin`、`machine.json`、`installed`、`.installing`、`preview.jpg`、`resume.hsnap`、`resume.hsnap.part`、`restore/`）與 `HengeInstall/` 暫存目錄。
   - **絕不刪除磁碟區根目錄與 SSD 內的其他個人資料夾／私人檔案**。

### 完整繁體中文介面與其他亮點

- **全繁體中文介面與即時語言切換**：包含首頁、安裝流程、硬體與儲存設定、單機詳情、即時續玩（Instant Resume）、獨立執行 Mac App（實驗性）、JIT 精靈與本機配對（iOS / iPadOS 27）、以及系統相機／區域網路權限說明（`CFBundleDevelopmentRegion` = `zh-Hant`）。
- **Sill 觸控手勢與 Apple 風格視覺鍵盤（v0.5.7 更新）**：
  - 保留 Henge 原版頂部 6 鍵毛玻璃膠囊控制列與直覺顯示方式：點擊隱藏後顯示一次提示，隨時**四指同時輕點螢幕**即可重新呼出控制列（不會 5 秒自動隱藏，無多餘頂端橫條或切換按鈕）。
  - 內建 Apple iPadOS Magic Keyboard ＋ 毛玻璃質感 5 列完整 macOS QWERTY 視覺鍵盤，搭配 SF Symbols 功能／方向鍵、黏滯修飾鍵反白與 Caps Lock 綠燈，支援即時 `⌘C / ⌘V / ⌘Z / ⌘W / ⌘Q`、`Spotlight`、`Mission` 快捷列與 `中/英 IME` 切換。
  - 支援在設定中切換 **Sill 多指觸控板模式**（原生 Magic Trackpad 2 兩指捲動／縮放與三指切換桌面）與 **直接觸控指標模式**（單指相對游標＋兩指捲動）。
- **剪貼簿與共享資料夾**：在 Mac 終端機執行自動輸入的安裝指令（`curl -s http://10.0.2.4/.henge/install | sh`）並按 Return 後，「檔案 › iPac / Henge › Shared」即同步至 Mac 家目錄的 `Henge` 資料夾；Mac 複製文字自動同步至 iPad，iPad 複製文字後點選上方控制列第三顆貼上鈕即可貼入 Mac。
- **外接螢幕支援**：連接 USB-C / HDMI 顯示器會自動雙螢幕分工，外接螢幕顯示 macOS 畫面，iPad 保留觸控板與鍵盤控制。

---

## 安裝與下載

直接前往 [**Releases 頁面**](https://github.com/iancheng64-cmd/ipac/releases/latest) 下載最新的 `iPac-v0.5.7-build116.ipa`。

### 系統需求

- **系統版本**：iOS / iPadOS 17.0 或更新版本（內建 StikJIT 輔助程序與本機免電腦配對需 iOS / iPadOS 26 / 27 以上）。
- **處理器**：Apple A14、M1 或更新晶片。
- **JIT 權限（必備）**：支援 **內建 StikJIT**（iOS 26+ 搭配 LocalDevVPN）、**StikDebug**、**TrollStore**（iOS 14.0–17.0）或 **越獄環境（Dopamine）**。
- **儲存空間**：若安裝於本機，建議保留約 **43 GB**（以 macOS Sequoia 為例：約 16 GB 安裝映像檔下載後可自動刪除，成品約佔 24–26 GB）；改用「外接安裝 → 存回本機」或「完整外接 SSD」模式可大幅減少 iPad 本機空間需求。

---

## 從舊版 Henge 覆蓋升級與 ESign 簽名說明

為讓原本正在使用 Henge（包含官方原版與 Build 103 等舊版）的使用者**直接無痛升級而不遺失已安裝的 macOS 虛擬機**，iPac 刻意保留了相容的 Bundle ID（`com.henge.app`）、偏好設定鍵值（`UserDefaults`）與 `machines.json` 格式（所有新增欄位皆為選填且向下相容）。

### 1. 我可以直接覆蓋安裝替換嗎？舊 Mac 資料會不見嗎？

- **可以，只要滿足以下兩個條件，直接覆蓋安裝就不會遺失資料：**
  1. **絕對不要先刪除舊版 Henge App**：刪除 iOS App 會連帶清空沙盒 `Application Support/Machines` 與 `Documents/` 內所有本機虛擬機檔案（存放於外接 SSD 內的資料則不受刪 App 影響）。
  2. **必須使用與舊版相同的簽名方式／開發者憑證（相同 Team ID + `com.henge.app`）覆蓋安裝**。
- 若之前是用 AltStore / SideStore / 個人 Apple ID 簽名，請繼續用同一個 Apple ID 的同款工具直接覆蓋安裝（iPad 主畫面顯示名稱會更新為 **iPac**，所有 Mac、設定與快取完整保留）。

### 2. 我可以使用 ESign（輕鬆簽）來簽名嗎？會不會有不相容問題？

**可以使用 ESign 簽名並安裝**，但請務必注意以下四個相容性條件：

1. **憑證必須包含 `get-task-allow`（Development / 開發者憑證）**：
   - iOS / iPadOS 執行 macOS 模擬器需要透過除錯器啟用 **JIT（動態程式碼執行權限）**；一般企業簽名或僅有 Ad-Hoc Distribution（無 `get-task-allow`）的簽名檔**無法**被 StikDebug 或內建 StikJIT 附加除錯器，開啟 Mac 時會無法啟用 JIT。
   - **解法**：使用開發者 p12 / mobileprovision 憑證，並在 ESign 簽名設定確認保留或注入 `get-task-allow`。
2. **務必保留 App Extension（`PlugIns/HengeJITHelper.appex`）**：
   - 在 ESign 匯入並簽名時，**不要勾選「移除所有 PlugIns / Extensions」**，否則「內建 StikJIT 免電腦開啟 JIT」功能會失敗並要求改用外部 StikDebug App（`HengeJITHelper.appex` 已與主程式統一為 `v0.4.1` Build `108` 確保 ESign/iOS 驗證通過）。
3. **關於 Bundle ID 與舊資料覆蓋**：
   - 保持預設 Bundle ID `com.henge.app` 簽名，但若舊版 Henge 原先是由不同 Team ID（例如個人免費簽名 / SideStore）簽署、本次改用不同來源的 ESign 企業或個人憑證，**iOS 不允許不同 Team ID 直接覆蓋同一顆 App**，可能會安裝失敗或需要重新賦予同一個 Bundle ID / 先匯出 Mac 備份後重新安裝。
   - 若打算換新憑證或同時並存安裝：請先把原本的 Mac **「搬移至外接 SSD」** 或用 **「匯出打包」** 保存並移出 `Documents/Exports/`，安裝新簽名版後再從「＋ › 從外接硬碟開啟隨身 Mac…」或匯入資料夾無損載入。
4. **記憶體權限（`increased-memory-limit` / `extended-virtual-addressing`）差異**：
   - 個人或一般 ESign 憑證的描述檔（Provisioning Profile）若未授權 `com.apple.developer.kernel.increased-memory-limit` 與 `com.apple.developer.kernel.extended-virtual-addressing` 權限，ESign 簽名後這些權限會被自動剔除。
   - **影響**：App 本身**仍可正常啟動執行**，但無法突破系統單 App 記憶體上限；iPac 會自動偵測並在需要時改以本機 APFS 儲存空間檔案映射（`ram.tmp`）充當虛擬機記憶體緩衝（效能會略低於持有完整 Entitlements 的簽名版）。

---

## 常見使用教學

### 啟用 JIT 加速（無電腦或配合 StikDebug）

- **iOS / iPadOS 26 及以上（內建 StikJIT）**：進入「設定 JIT」精靈選擇本機配對（iOS 27+）或匯入電腦產生的 `pairingFile.plist`，從 App Store 安裝並開啟 **LocalDevVPN** 保持本機迴路連線，點選「檢查環境」→「啟用 JIT」即可。
- **使用 StikDebug**：若外部透過 StikDebug 啟動，請點 iPac 畫面上的「開啟 JIT」由 iPac 帶入專用腳本跳轉，避免從 StikDebug App 列表直接開啟。
- **TrollStore / Dopamine**：iOS 14–17.0 或已越獄環境可直接使用對應模式，免 VPN 啟用 JIT。

### 在 iPad 與虛擬 macOS 間共享剪貼簿與檔案

1. 啟動虛擬 Mac 後，在 Mac 內開啟「終端機（Terminal）」，確認 macOS 輸入法目前為 **英文（ABC）**。
2. 點選 iPac 控制列「**詳細資訊（i） › 剪貼簿與資料夾共享 › 自動輸入設定指令**」，回到 Mac 終端機按下 **Return** 執行並允許本地網路權限。
3. 完成後：
   - iPad 的「檔案 › iPac（或 Henge）› Shared」資料夾即對應 Mac 家目錄內的 `Henge` 資料夾。
   - 在 Mac 複製純文字會自動同步到 iPad 剪貼簿；在 iPad 複製純文字後，點選上方控制列第三顆 **貼上按鈕**，iPac 會直接將文字貼到 Mac 游標所在處（系統按鈕免跳權限詢問）。

---

## 從原始碼自行建置

需要安裝 **Xcode（iOS 27 SDK / Xcode 27 以上建議）** 與 `xcodegen`；引擎所需第三方相依套件（StikJIT、libslirp、glib、rppairing 等）來自 [Husk](https://github.com/Leviidev/Husk)（預設路徑 `~/Documents/Coding/Husk`，可透過 `HUSK=/path/to/Husk` 環境變數指定）：

```bash
ios/scripts/fetch_deps.sh
tools/build_ios_restore.sh
make ios-lib
HENGE_IPA_OUT=./iPac-v0.4.1-build108.ipa ios/scripts/package_ipa.sh
```

- 若使用免費個人 Apple Team 帳號簽名，建置時可加上 `HENGE_ENTITLEMENTS=Henge/Henge.personal.entitlements`。
- 本機開發測試 Mac 版引擎與單元測試可執行 `make` 與 `make test`。

---

## 已知限制

- 在虛擬 macOS 內登入 Apple Account 會出現驗證失敗錯誤。
- 虛擬 macOS 系統重開機或關機後，由於 iOS 行程只能預熱保留單次 JIT 記憶區，請從多工上滑完全關閉 iPac 再重新開啟後啟動下一台 Mac。
- iPadOS 會保留部分系統全域快捷鍵（例如 `⌘ + Tab`）。
- 因指令轉譯模擬架構限制，執行速度低於原生 Apple Silicon Mac。

---

## 授權條款與版權說明

本專案依據 **GNU General Public License v2.0 or later（[GPL-2.0-or-later](LICENSE)）** 開源授權釋出，衍生自 [`Leviidev/Henge`](https://github.com/Leviidev/Henge)。因編譯包含 `usbmuxd` 與來自 `Husk` 的 GPL 程式碼，發行執行檔亦屬 GPL 複合著作，請參閱 [docs/licensing.md](docs/licensing.md)。內建自動解鎖大記憶體的 Apple Developer Services 驗證與 App ID 更新流程參考 [`hugeBlack/GetMoreRam`](https://github.com/hugeBlack/GetMoreRam) 與 [`NexSideloading/iRAM-Plus`](https://github.com/NexSideloading/iRAM-Plus)，並採用 [`stossy11/StosSign`](https://github.com/stossy11/StosSign) SwiftPM 套件。

**Apple 版權聲明**：本儲存庫與釋出的 IPA 安裝檔**皆未包含**任何 Apple macOS 作業系統映像檔與開機韌體（`AVPBooter.vmapple2.bin`）；所有系統檔案皆於使用者實際安裝時由裝置直接向 Apple 官方 CDN 下載取得。
