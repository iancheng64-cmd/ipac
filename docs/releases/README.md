# iPac 版本紀錄

本機 IPA 的預設存放位置是 `~/Downloads/iPac-Releases/`，每個版本有獨立資料夾和 `README.md`。

| 版本 | 說明 | 狀態 |
| --- | --- | --- |
| [0.5.2 / Build 111](v0.5.2-build111.md) | 快照保留、關機同步錯誤、安裝完成判斷與下載續傳 | 本機測試版 |
| [0.5.1 / Build 110](v0.5.1-build110.md) | JIT 自測失敗狀態誤報、語言切換後選單標籤修正 | 測試版 |
| [0.5.0 / Build 109](v0.5.0-build109.md) | 中英文切換、記憶體控制、緊湊 JIT 中繼資料與安裝安全修正 | 測試版 |
| [0.4.1 / Build 108](v0.4.1-build108.md) | 自動檢查記憶體權限、Anisette 與操作流程修正 | 既有發布 |
| [0.4.0 / Build 107](v0.4.0-build107.md) | 內建 GetMoreRam、關機後調整 RAM 與 CPU | 既有發布 |
| [0.3.0 / Build 106](v0.3.0-build106.md) | 隨身外接 SSD、跨 iPad 設定與繁體中文介面 | 既有發布 |

## 後續打包

```sh
zsh ios/scripts/package_ipa.sh
```

腳本以 App 的版本及 Build 編號命名輸出，並將對應的版本說明複製到輸出資料夾。新版本請先更新 App 版本、增加 Build 編號，並新增 `docs/releases/v版本-build編號.md`。

可用 `HENGE_RELEASE_ROOT` 改變集中資料夾，或用 `HENGE_IPA_OUT` 指定單一輸出檔案。`--trollstore` 輸出獨立的 `.tipa`，不覆蓋 `.ipa`。

## 安裝與資料

- 維持相同 Bundle ID `com.henge.app` 及簽名 Team ID，以覆蓋安裝升級。
- 不要為了升級先刪除 iPad 上的舊 App，否則可能失去本機 VM 與設定。
- IPA 為 ad-hoc 簽名包，仍需適當的簽名及 JIT 啟用方式。
- 不包含 Apple macOS 安裝映像或 Boot ROM。
- Android 手機 SSD 的 Magisk 模組是獨立工具，不是 IPA，也不是已驗收的 iPhone SSD 驅動。
