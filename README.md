# OMP Chat

Native AI chat client for macOS & iOS (SwiftUI), speaking OpenAI-compatible and Anthropic wire protocols against any relay (ccLoad / one-api / OpenAI / Anthropic / Ollama…).

## Layout

```
Apps/macOS            macOS shell (window, commands, settings scene)
Apps/iOS              iOS shell
Packages/OMPKit
  Sources/OMPCore     domain, transport (SSE, providers), persistence, secrets, media
  Sources/OMPDesign   design tokens (Theme, colors, marks)
  Sources/OMPChatUI   the whole UI (shared by both platforms)
  Tests/              unit tests (SSE, builders, stores, streaming model)
Scripts/mock-relay.py local OpenAI-compatible relay for smoke tests (port 18791)
project.yml           XcodeGen manifest — run `xcodegen generate` after edits
```

## Build & run

```bash
xcodegen generate
xcodebuild -project OMPChat.xcodeproj -scheme OMPChat -destination 'platform=macOS' build
xcodebuild -project OMPChat.xcodeproj -scheme OMPChatiOS -destination 'generic/platform=iOS Simulator' build
open .artifacts/DerivedData/Build/Products/Debug/OMPChat.app   # after building with -derivedDataPath .artifacts/DerivedData
```

Package-only workflow: `cd Packages/OMPKit && swift build && swift test`.

## Provider setup

Settings → 添加供应商 → preset or manual. API keys go to the Keychain
(data-protection keychain); if Keychain is unavailable (ad-hoc dev builds) they
fall back to a `0600` `secrets.json` in the store directory.

To use the omp/ccLoad gateway directly: base URL `https://ai-oops.com:8992`,
key in `~/.omp/agent/.env` (`CCLOAD_API_KEY`), model id as shown by `/v1/models`
(e.g. `deepseek-v4.1-flash`).

## Workspace storage

One atomic JSON document per workspace: conversations, provider profiles,
model catalog and settings. Default location is the app container's
`Application Support/OMPChat`. Set `OMPCHAT_STORE_DIR` to redirect store +
secrets + media (used by headless probes and UI runs sharing one workspace).

## Features

- Streaming chat (SSE) with stop / regenerate / edit-and-resend / delete / branch
- Markdown + fenced code blocks, thinking disclosure, token usage per message
- Image & file attachments (vision), image generation via `/v1/images/generations`
- Conversations: search, pin, rename, delete, export Markdown, quick switcher (⌘K)
- Slash templates in the composer (`/翻译`…), Return-to-send (Shift+Return newline)
- Context-usage estimate per conversation against the model's context window
- Appearance (system/light/dark), system prompt, temperature, send-on-return

## Smoke test with the local relay

```bash
python3 Scripts/mock-relay.py 18791 &
# add provider base URL http://127.0.0.1:18791, key sk-local-test
```
