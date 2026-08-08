# All-in-One Codex

All-in-One Codex 是原生 macOS SwiftUI app，用來管理 Codex provider
profiles，安全地預覽、套用與復原設定。它也會投影 Codex model catalog，
讓 CLI 與相容的 Codex client 能認識 DeepSeek、Kimi、GLM 等 custom models。

目前提供：

- OpenCode Go 與 OpenRouter presets
- 依 preset + model 顯示 Responses route、Chat bridge 與 endpoint
- OpenCode Go 的 All-in-One model picker，以及 OpenRouter 自訂 model ID
- 只接受新值的 Keychain `SecureField`
- Preview、Apply、Undo、Menu Bar quick apply
- 可選的既有 Codex session 保留模式
- model catalog 摘要、restart-required 提示與 sanitized error

## Apply 會更新什麼

Apply 是一個 configuration + catalog transaction：

1. 更新 `~/.codex/config.toml`。
2. 建立或更新 `~/.codex/all-in-one-codex-model-catalog.json`。
3. 在 `config.toml` 的 managed active block 寫入：

   ```toml
   model_catalog_json = "all-in-one-codex-model-catalog.json"
   ```

4. 若選到 Chat-only model，Apply 會由 All-in-One Codex 自動啟動
   `127.0.0.1:14556` 的 local bridge；不需要另外手動啟動。
5. 若 profile 開啟「保留既有 Codex sessions」，Apply 會保留內建 `openai`
   provider namespace，以 `openai_base_url` 將請求導向同一個 local bridge；
   bridge 再從 Keychain 取得該 profile 的 API key 並轉送到實際 provider。

Apply 成功只代表檔案與 route 已安全寫入，**不代表 Codex Desktop 的
model picker 一定會立刻顯示 custom model**。App 不會自動 kill Codex，也不會
熱載入正在執行的 Codex task；請依「實際使用步驟」完全重啟。保留模式可在
重啟後重新開啟既有 task，但不會讓執行中的 task 原地熱切換。

## 保留既有 Codex sessions

Codex 會依 active provider identity 區分可見的 task/history。一般模式使用
All-in-One 的自訂 `model_provider`，因此原本位於內建 `openai` provider 下的
task 可能在切換後暫時看不到。開啟 profile 的「保留既有 Codex sessions」後：

- active provider 維持 Codex 內建的 `openai` namespace；
- `openai_base_url` 只導向 `http://127.0.0.1:14556/v1`；
- local proxy 不會把 Codex 傳入的官方 OAuth bearer 送到第三方 upstream；
- upstream Authorization 只使用該 profile 在 macOS Keychain 中的 API key；
- `~/.codex/auth.json`、session JSONL、history 與 state database 都不會被改寫。

此模式對 Responses route 使用透明 proxy，對 Chat-only route 沿用
Responses ↔ Chat Completions 轉換。All-in-One Codex 必須持續開啟；Apply 後
仍需完全退出並重啟 Codex，再從既有 task 清單重新開啟 session。

## Provider routing

### OpenCode Go

OpenCode Go 的預設 model 是 Chat-only 的 `glm-5.2`。原生 Responses model
`gpt-5.6-luna` 直接使用：

`https://opencode.ai/zen/go/v1`

下列 Chat-only models 透過本機 bridge 使用：

`grok-4.5`、`glm-5.2`、`glm-5.1`、`kimi-k3`、`kimi-k2.7-code`、
`kimi-k2.6`、`deepseek-v4-pro`、`deepseek-v4-flash`、`mimo-v2.5`、
`mimo-v2.5-pro`、`hy3`

Codex 仍使用 Responses contract；Chat-only request 送到只綁定
`127.0.0.1` 的 local bridge：

`http://127.0.0.1:14556/v1`

bridge 同時提供 OpenAI-compatible model list：

- `GET http://127.0.0.1:14556/models`
- `GET http://127.0.0.1:14556/v1/models`

它會把 Responses request 轉成上游 Chat Completions，再把 response 轉回
Responses event sequence。上游 endpoint 是：

`https://opencode.ai/zen/go/v1/chat/completions`

目前轉換是 buffered streaming：bridge 會先 buffer 完整上游 Chat response
（包括上游 SSE），再產生 Responses events，可能增加延遲與記憶體使用。
選用 Chat-only model 時，All-in-One Codex 必須保持開啟，讓 bridge 持續監聽。

Anthropic Messages models 目前不支援，也不會列在可選 model menu 中。若手動
輸入，Core 會 fail closed 並顯示不含 credential 的錯誤。

### OpenRouter

OpenRouter 使用直接的 Responses route，預設 model 是
`openai/gpt-5.3-codex`，仍允許在 editor 直接輸入自訂 model ID。其 catalog
只會包含目前選定的 custom model。

## 與 cc-switch 的 model catalog parity

本 app 依照 `/tmp/cc-switch-reference` 的 Codex native Responses template
採用相容的 catalog entry shape，並保留 `base_instructions`、
`supports_reasoning_summaries` 等目前 Codex parser 需要的欄位。主要 parity
包括：

- 以 `model_catalog_json` 指向外部 catalog，而不是把完整 JSON 塞入
  `config.toml`。
- 以 `all-in-one-codex-model-catalog.json` 儲存 app-owned catalog。
- Chat bridge 提供 `/models` 與 `/v1/models`，讓 OpenAI-compatible client
  能取得 model list。
- 變更 catalog 後要求完整重啟 Codex；執行中的 process 不保證 hot reload。

## Codex Desktop 何時會顯示 DeepSeek

Codex CLI 讀到 `config.toml` 與 model catalog，和 Codex Desktop 的 picker
不是同一個 gating layer。Desktop 會依目前的官方 ChatGPT/Codex login
identity 決定是否放行 custom models；因此可能出現：

- CLI 的 `/model` 已有 `deepseek-v4-flash` / `deepseek-v4-pro`；
- Desktop picker 仍只顯示官方 model，或 reasoning level 回落。

這是上游 Codex Desktop 的 model gating，不是「已套用」的反向保證，也不是
本 app 可以繞過的限制。若 Desktop 仍隱藏 custom models，請先在 Codex
Desktop 保持有效的官方 ChatGPT/Codex login，再完整退出並重開 Desktop。

All-in-One Codex **不會把第三方 API key 寫入 `~/.codex/auth.json`**。
API key 由 Keychain 管理：一般模式由 `config.toml` 的 command-backed
authentication 交給 Codex 取得；session 保留模式則由 local proxy 直接從
Keychain 取得，且不會把傳入的官方 OAuth bearer 送往第三方。這個安全邊界也
表示本 app 不會替 Desktop 偽造或補寫官方 login。上游 gating 仍可能拒絕在
沒有官方登入時顯示 custom models。

## 實際使用步驟

1. 開啟 All-in-One Codex，建立或選擇 profile，在 Credentials 輸入新的 API
   key；既有 key 不會讀回或顯示。
2. 確認 model picker 使用 All-in-One 的 model source list。DeepSeek 位於
   OpenCode Go 清單；可選 `deepseek-v4-flash` 或 `deepseek-v4-pro`。
3. 若要在切換後重新開啟原有 task，開啟「保留既有 Codex sessions」。可先按
   Preview 檢查 route 與 catalog count；Preview 不會修改檔案，也不會顯示
   credential。按 Apply 後保持 All-in-One Codex 開啟；需要 bridge 時它會
   自動啟動。
4. **完全退出 Codex/ChatGPT Desktop**，再重新開啟 Codex；All-in-One Codex
   不要在 Chat-only route 使用期間關閉。
5. 保留模式可重新開啟既有 task；一般模式則建立新 task。若 Desktop 要顯示
   DeepSeek，請同時確認上一步所述的官方 Codex login 仍有效；「Apply 成功」
   與「Desktop picker 可見」必須分開驗證。
6. 在 Codex CLI task 中輸入 `/model` 查看 catalog model，輸入
   `/status` 查看目前 route、provider 或 session 狀態。CLI 正常而 Desktop
   不顯示時，通常就是 Desktop login gating。

## 設定復原與 persistent Undo

- 每次 Apply 成功後，App 會把不含秘密的 switch receipt 寫入最多 20 筆的
  persistent Undo journal；重新開啟 App 後仍可從 Undo 使用最新一筆。Undo
  成功後會移除該筆 journal entry。
- Toolbar 的 **Restore Backup** 會列出 App 建立的 config backup inventory，
  只顯示時間與檔案大小，並在第二步確認後復原 `config.toml` 與
  app-owned model catalog。Restore 成功後會產生新的 receipt，也能再 Undo。
- Restore 不會遷移或重寫 Codex 的 sessions、history、auth 或 state database，
  也不會複製或刪除約 20GB 的 session data。完成 Apply、Undo 或 Restore 後，
  都必須完全退出並重新啟動 Codex。
- 開啟 profile 的 session 保留模式可維持內建 `openai` provider namespace；
  App 不會自動改寫任何 history metadata，也不會遷移 session data。
- config restore 已由 App 的 backup inventory 與安全確認流程提供，不再需要
  手動輸入指令。

## 安全模型

- API key 由 Core 的 `CredentialStoring` / `KeychainCredentialStore` 管理，
  不會寫入 profile JSON、README、log、catalog 或 UI state。
- 編輯既有 profile 時，API key 欄位永遠是空白；欄位只接受新的 key。
- 新 key 成功儲存後立即清空 `SecureField`，App 不會讀回或顯示既有 key。
- 一般模式由 `CodexClientAdapter` 在 `config.toml` 產生 `auth.command`，讓
  Codex 從 macOS Keychain 取出 credential；session 保留模式則由 loopback
  proxy 依 active profile 從 Keychain 取出。model catalog 只包含 descriptors。
- bridge 僅監聽 `127.0.0.1:14556`，不接受 LAN 或公開網路連線。credential
  只在 active route 的記憶體中使用，不會被 bridge 寫入檔案、永久保存或寫入 log；Preview、warning、Apply、Undo
  的 UI 訊息也不顯示 key。
- 設定切換不修改 `~/.codex/auth.json`。Chat-only route 與 session 保留模式的
  上游轉送是明確的 local bridge network path，不是假設 app 完全不會發生
  network call。

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

`Sources/App/AppState.swift` 是集中呼叫 Core 的 app 邊界，負責：

1. 啟動時透過 `ProfileRepository` 載入 profiles。
2. 啟動時呼叫 `ClientAdapter.prepareForUse()`；Core 只會在既有 active
   configuration 需要時啟動 local bridge。bridge 啟動失敗不會阻止 profile
   metadata 載入，但錯誤會顯示給使用者。
3. 將新增或編輯後的 profile 儲存回 repository。
4. 將新 API key 寫入 credential store，並在成功後清空輸入。
5. 透過 `CodexClientAdapter` 執行 preview、apply、undo，並將 receipt 的
   catalog transaction 狀態轉成 UI 摘要。
6. 將 `foreignModelCatalogPointer`、catalog validation/IO errors 轉成不含
   秘密的友善中文；既有 credential 與 bridge errors 維持原本 Core error
   boundary。

因此若 Core 的 async 或 argument label 最終不同，只需調整
`AppState.swift` 的整合點，不必讓 SwiftUI views 依賴 Core 的具體 signature。
