# All-in-One Codex

All-in-One Codex 是一個原生 macOS SwiftUI app，用來管理 Codex provider
profiles，並在不同設定間安全地預覽、套用與復原。第一版提供：

- profile sidebar、空白狀態與 profile editor
- OpenCode Go 與 OpenRouter presets
- 依 preset + model 顯示實際 route、endpoint 與 bridge 需求
- OpenCode Go model picker，以及 OpenRouter 自訂 model text input
- 只接受新值的 Keychain `SecureField`
- Preview、Apply、Undo，以及 Menu Bar quick apply
- active profile、錯誤與 Core switch 狀態提示

## Provider routing

### OpenCode Go

OpenCode Go 的預設 model 是 Chat-only 的 `glm-5.2`，會透過 bridge 使用。
目前 catalog 的原生 Responses model 是 `gpt-5.6-luna`，會直接連到：

`https://opencode.ai/zen/go/v1`

下列 11 個 Chat-only model 透過 app 內的本機 bridge 使用：

`grok-4.5`、`glm-5.2`、`glm-5.1`、`kimi-k3`、`kimi-k2.7-code`、
`kimi-k2.6`、`deepseek-v4-pro`、`deepseek-v4-flash`、`mimo-v2.5`、
`mimo-v2.5-pro`、`hy3`

Codex 仍使用 Responses contract；Chat-only model 的請求會送到只綁定
`127.0.0.1` 的 local bridge：

`http://127.0.0.1:14556/v1`

bridge 將 Responses request 轉成上游 Chat Completions，再將回應轉回
Responses event sequence。上游 endpoint 是：

`https://opencode.ai/zen/go/v1/chat/completions`

這個轉換目前有 buffered streaming 限制：bridge 會先 buffer 完整的上游
Chat response（包括上游 SSE），再產生 Responses events，因此不提供真正的
token-by-token upstream streaming，且可能增加延遲與記憶體使用。選用
Chat-only model 時，app 必須保持執行，讓 local bridge 持續監聽。

Anthropic Messages model 目前尚未支援，也不會列在可選 model menu 中。
若手動輸入 Messages model，Core 會 fail closed 並將錯誤顯示在 UI。

### OpenRouter

OpenRouter 使用直接的 Responses route，預設 model 是
`openai/gpt-5.3-codex`，同時仍允許在 editor 直接輸入自訂 model ID。

## 安全模型

- API key 由 Core 的 `CredentialStoring` / `KeychainCredentialStore` 管理，
  不會寫入 profile JSON、README、log 或 UI 狀態。
- 編輯既有 profile 時，API key 欄位永遠是空白；欄位只接受新的 key。
- 新 key 成功儲存後立即清空 `SecureField`，App 不會讀回或顯示既有 key。
- `CodexClientAdapter` 在 `~/.codex/config.toml` 產生
  `auth.command`，由 Codex 從 macOS Keychain 取出 credential；bridge 只接收
  Codex 已取得的 bearer credential，並只將它轉送至上游 OpenCode Go request。
- bridge 僅監聽 `127.0.0.1:14556`，不接受 LAN 或公開網路連線。credential
  不會被 bridge 寫入檔案、保存或寫入 log；UI 的 Preview、warning 與錯誤也
  不會顯示 key。
- 設定切換本身只修改 `~/.codex/config.toml`，不修改
  `~/.codex/auth.json`。Chat-only route 的上游轉送是明確的 local bridge
  network path，不是假設 app 完全不會發生 network call。

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
2. 啟動時呼叫 `ClientAdapter.prepareForUse()`；Core 只會在既有 active
   configuration 需要時啟動 local bridge。bridge 啟動失敗不會阻止 profile
   metadata 載入，但錯誤會顯示給使用者。
3. 將新增或編輯後的 profile 儲存回 repository。
4. 將新 API key 寫入 credential store，並在成功後清空輸入。
5. 透過 `CodexClientAdapter` 執行 preview、apply 與 undo。

因此若 Core 的 async 或 argument label 最終不同，只需調整
`AppState.swift` 的整合點，不必讓 SwiftUI views 依賴 Core 的具體 signature。

## 未來擴充

- 新增 provider preset 與各 provider 的 model capability
- 以 Core receipt 支援更完整的 switch history
- profile 匯入/匯出與 validation diagnostics
- 更細緻的 active-state 同步與設定 diff
- 在不暴露 credential 的前提下加入 audit metadata
