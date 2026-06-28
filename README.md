# klick-mobile-ios

Native iOS client for **Klic** — SwiftUI, talking to `klick-server` for auth, chat, and call
signaling, and to LiveKit for audio/video media.

## Requirements
- Xcode 16+ (Swift 5.9+), iOS 17 deployment target
- [XcodeGen](https://github.com/yonsm/XcodeGen): `brew install xcodegen`

## Generate & run

```bash
brew install xcodegen
xcodegen generate          # creates Klic.xcodeproj from project.yml (resolves SPM deps)
open Klic.xcodeproj
```

By default the app points at the **live server** `https://api.89.34.230.2.sslip.io` (TLS), with
LiveKit at `wss://lk.89.34.230.2.sslip.io`. To run against a local backend instead, change the
base URL in `Sources/Networking/APIClient.swift` and `SocketService.swift` to `http://localhost:3000`.

## Dependencies (SPM, declared in `project.yml`)
- **LiveKit** `client-sdk-swift` — audio/video rooms
- **Socket.IO** `socket.io-client-swift` — realtime messaging + call signaling

## Structure

```
Sources/
├── App/                # KlicApp entry + RootView (auth gate, incoming-call presenter)
├── DesignSystem/       # KlicColor, KlicFont, KlicIcon, KlicComponents (pill buttons, etc.)
├── Networking/         # Models, APIClient (async/await), TokenStore (Keychain)
├── Realtime/           # SocketService (mirrors server events)
├── Calling/            # CallService (LiveKit) + CallKitManager (native incoming UI)
├── Session/            # AppSession (auth state)
└── Features/           # Auth · Conversations · Chat · Call
Resources/
├── Fonts/              # curated TikTok Sans subset (registered in Info.plist)
├── Assets.xcassets/    # AppIcon, AccentColor, (generated) Icons
└── Info.plist          # camera/mic usage, VoIP background modes, UIAppFonts
design/icons/{Bold,Line}# brand SVG source of truth
scripts/generate-icons.sh # SVG → PDF template images in Assets.xcassets
```

## Design system
Dark-first. Background `#0E0F16`, primary **punch-red `#ED122B`**, TikTok Sans. Buttons are fully
rounded, flat — no shadows, strokes, or emoji (`KlicComponents.swift`).

## Icons
The brand set lives in `design/icons/`. For M0, `KlicIcon` maps to SF Symbols so the UI tints
cleanly. Run `scripts/generate-icons.sh` (needs `librsvg`) to produce tintable PDF template assets,
then point `KlicIcon`/`Icon` at the generated `ic_<variant>_<name>` images.

## Signing
Dev/Distribution certs live in `klic-assets/Apple/` (password in `klic-assets/Apple/password.txt`).
Set `DEVELOPMENT_TEAM` in `project.yml`, or import the `.p12` + `.mobileprovision` and sign manually.

## Calling & push (M3)
- **CallKit + PushKit (VoIP)** drive native incoming-call UI — this is what shows the call in the
  **Dynamic Island** and on the Lock Screen (`Sources/Calling/CallKitManager.swift`, `AppDelegate.swift`).
- **Live Activity** (`Widget/`, `Sources/Shared/CallActivityAttributes.swift`) renders the ongoing
  call in the Dynamic Island with a live timer.
- **LiveKit video** is rendered by `Sources/Calling/CallVideoView.swift`.

To make push actually fire you need (from the Apple Developer portal):
1. An **APNs Auth Key** (`.p8`) — put its `Key ID`, `Team ID`, and bundle id into `klick-server/.env`
   (`APNS_*`) and the `.p8` on the server.
2. Enable **Push Notifications** capability for the app's bundle id; `Resources/Klic.entitlements`
   already sets `aps-environment`. Set your Team in Xcode (the generated `.xcodeproj` is gitignored).

LiveKit track accessors in `CallService.swift` target SDK v2 — adjust if your installed version differs.

## Roadmap
Done: M1 auth/friends · M2 read receipts + push · M3 calling (CallKit + Dynamic Island + VoIP).
Next: call history, group calls, typing indicators, store builds.
