# QuickAsk

Menu-bar macOS app for quick AI answers — Spotlight-style panel, global hotkey, multiple providers.

**Site:** [rrer-ask.github.io/QuickAsk](https://rrer-ask.github.io/QuickAsk/) · **Download:** [latest release](https://github.com/rrer-ask/QuickAsk/releases/latest)

## Features

- Lives in the macOS menu bar (no Dock icon)
- Global hotkey (default **⌥Space**) opens a floating ask panel
- Providers: **OpenCode Go**, **DeepSeek**, or any OpenAI-compatible API
- API keys stored locally in Application Support (not Keychain)
- Optional web search + streamed answers; follow-ups in the same thread
- History in Settings (configurable limit)

## Requirements

- macOS 14+
- Your own API key (OpenCode Go / DeepSeek / OpenAI-compatible)

## Install (release build)

1. Download `QuickAsk-1.0.zip` from [Releases](https://github.com/rrer-ask/QuickAsk/releases/latest)
2. Drag `QuickAsk.app` to Applications
3. Right-click → **Open** (ad-hoc signature / Gatekeeper)
4. Settings → paste API key → Use as active
5. Press **⌥Space**

## Build from source

```bash
cd QuickAsk
xcodegen generate
xcodebuild -scheme QuickAsk -configuration Release -derivedDataPath build
open build/Build/Products/Release/QuickAsk.app
```

Or: `./scripts/make-zip.sh`

## License

MIT — see [LICENSE](LICENSE)
