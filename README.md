# All-in-One Codex

All-in-One Codex 是一個原生 macOS SwiftUI app，用來管理 Codex provider
profiles，並在不同設定間安全地預覽、套用與復原。第一版提供：

- profile sidebar、空白狀態與 profile editor
- OpenCode Go 與 OpenRouter presets
- 名稱、provider、唯讀 endpoint、model 編輯
- 只接受新值的 Keychain `SecureField`
- Preview、Apply、Undo，以及 Menu Bar quick apply
- active profile、錯誤與 Core switch 狀態提示

## 安全模型

- API key 由 Core 的 `CredentialStoring` / `KeychainCredentialStore` 管理，
  不會寫入 profile JSON、README、log 或 UI 狀態。
- 編輯既有 profile 時，API key 欄位永遠是空白；欄位只接受新的 key。
- 新 key 成功儲存後立即清空 `SecureField`，App 不會讀回或顯示既有 key。
- 設定切換只透過 Core 的 `CodexClientAdapter`，不使用 network call 或 proxy。
- 切換設定會修改 `~/.codex/config.toml`，不會修改 `~/.codex/auth.json`。

## OpenCode Go MVP 限制

OpenCode Go 在 MVP 僅支援原生 Responses model。UI 不會假裝支援尚未由
Core 完成的 client 或 model；若 Core 拒絕某個設定，錯誤會回到 AppState
並顯示給使用者。

## Build

需要 macOS 14、Swift 6、XcodeGen 2.45.3。

```sh
xcodegen generate
xcodebuild \
  -project AllInOneCodex.xcodeproj \
  -scheme AllInOneCodex \
  -destination 'platform=macOS' \
  build
```

執行 unit tests：

```sh
xcodebuild \
  -project AllInOneCodex.xcodeproj \
  -scheme AllInOneCodex \
  -destination 'platform=macOS' \
  test
```

## Core 整合

`Sources/App/AppState.swift` 是唯一集中呼叫 Core 的 app 邊界，負責：

1. 啟動時透過 `ProfileRepository` 載入 profiles。
2. 將新增或編輯後的 profile 儲存回 repository。
3. 將新 API key 寫入 credential store，並在成功後清空輸入。
4. 透過 `CodexClientAdapter` 執行 preview、apply 與 undo。

因此若 Core 的 async 或 argument label 最終不同，只需調整
`AppState.swift` 的整合點，不必讓 SwiftUI views 依賴 Core 的具體 signature。

## 未來擴充

- 新增 provider preset 與各 provider 的 model capability
- 以 Core receipt 支援更完整的 switch history
- profile 匯入/匯出與 validation diagnostics
- 更細緻的 active-state 同步與設定 diff
- 在不暴露 credential 的前提下加入 audit metadata
