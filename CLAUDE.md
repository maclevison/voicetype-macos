# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

VoiceType — native macOS menu-bar app for macOS 14+ (arm64) that captures voice via global shortcut, transcribes and refines on-device (WhisperKit + Apple FoundationModels, Groq as fallback), and pastes the result into the focused app. Also records meetings (detection, diarization, calendar invite) and writes summarized notes to an Obsidian vault. Single user (the author). PT-BR is the user-facing language; UI copy and validation messages are in Portuguese, code identifiers in English.

Status: **shipping**. Daily driver at `/Applications/VoiceType.app`. Native Swift 5.10 + SwiftUI + AppKit. The previous Electron 30 build has been removed.

## Commands

```bash
open macos/VoiceType.xcodeproj                                                   # dev — Cmd+R no Xcode
xcodebuild -project macos/VoiceType.xcodeproj -scheme VoiceType -configuration Debug build  # CLI build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test              # core tests (from macos/VoiceTypeCore)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <name>  # single suite/test
./macos/scripts/make-icons.sh [path/to/icon.svg|.png]                            # regenerate AppIcon set
./macos/scripts/install.sh                                                       # Release build → /Applications, signed with "VoiceType Local"
```

App target tests (XCUITest + XCTest) run via Xcode → Cmd+U or `xcodebuild test -scheme VoiceType -only-testing:VoiceTypeTests`.

**Toolchain quirk**: `xcode-select -p` may point at CommandLineTools (no XCTest/swift-testing). Always prefix CLI swift/xcodebuild calls with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` on this Mac.

There is no separate linter; the Swift compiler in strict-concurrency mode is the static gate.

## Architecture

Native macOS app, Swift 5.10 + SwiftUI + AppKit. Two-target layout (component diagram + file links: README → "Arquitetura"):

```
macos/
├── VoiceType.xcodeproj
├── VoiceType/                    App target (AppKit + SwiftUI shells)
│   ├── App/                      @main (VoiceTypeApp), AppDelegate, AppDependencies (composition root),
│   │                             RecordingOrchestrator, Adapters/ (Core use-case protocols → app services)
│   ├── Features/
│   │   ├── Recording/
│   │   │   ├── Shortcut/         ShortcutManager + custom CGEventTap HoldDetector (no third-party dep)
│   │   │   ├── Audio/            AVAudioEngine AudioRecorder, WavEncoder, AudioDeviceResolver
│   │   │   ├── Transcription/    LocalTranscriber (WhisperKit on-device) + WhisperModelManager
│   │   │   ├── Refinement/       LocalRefiner/LocalTranslator (FoundationModels), cursor context
│   │   │   ├── Output/           Paster (AX insert, else NSPasteboard + synthesized Cmd+V)
│   │   │   └── HUD/              recording indicator (notch / pill)
│   │   ├── Meeting/              detection, mic + system-audio capture, diarization, calendar, processing
│   │   ├── MenuBar/, Settings/, History/
│   ├── Platform/                 ActivationPolicy/, AutoStart/, Notifications/, Permissions/
│   └── Resources/                Assets.xcassets, Info.plist
├── VoiceTypeCore/                SwiftPM package (no AppKit; fully testable)
│   ├── Sources/Core/
│   │   ├── StateMachine/         AppStateMachine (actor)
│   │   ├── Config/               ConfigStore (actor) + AppConfig (Codable)
│   │   ├── History/              HistoryStore (actor)
│   │   ├── Pipeline/             Transcriber, Refiner, Translator, Pipeline (actor), fallbacks/guards
│   │   ├── UseCases/             Start/Stop recording, RunPipeline
│   │   ├── Meeting/              transcript, summary (claude CLI), note/daily/idea renderers, calendar match
│   │   ├── Learning/             edit alignment → vocabulary suggestions
│   │   ├── OpenKnowledge/        OpenKnowledge vault: proposal, approval session, transactional OKVaultWriter
│   │   └── GroqClient/           URLSession async/await
│   └── Tests/CoreTests/          swift-testing
├── build/                        entitlements.plist, exportOptions.plist
└── scripts/                      install.sh, make-icons.sh, release.sh
```

Dictation: shortcut → `RecordingOrchestrator` → `AudioRecorder` (AVAudioEngine, 16 kHz mono, WAV) → `RunPipelineUseCase` → `Pipeline.run` (on-device Whisper, Groq fallback → on-device refine/translate, Groq fallback, raw text if both fail) → `Paster` → `HistoryStore.add`.

Meetings: `MeetingDetector` notices a call → `MeetingRecorder` (mic + system audio) → `MeetingProcessor` (local transcription → `MeetingDiarizer` "Outro N" voices → `MeetingCalendar` invite → `ClaudeCLISummarizer`) → Markdown note + transcript in the Obsidian vault, or, in OpenKnowledge mode, a pending proposal approved step by step before anything is written to the vault (`docs/architecture.md`, ADR-012). Voice notes (`IdeaNote`) go to the daily note (`_inbox/` in OpenKnowledge mode).

Key rules:

- **`AppConfig` is `Codable` in `VoiceTypeCore`.** Single source of truth. Adding a field: edit `AppConfig.swift`, add a default in the init, add a ConfigStore round-trip test. `schemaVersion` is the migration hook (currently `2`; decoder migrates v1).
- **State machine** (`VoiceTypeCore/Sources/Core/StateMachine/AppStateMachine.swift`) is a Swift `actor`. Invalid transitions log + no-op, never throw.
- **`ConfigStore` is an actor**, atomic write (tmp + rename), subscribers notified inside `save(_:)` — array is copied before iteration to avoid reentrancy issues.
- **`HistoryStore` cap** is `cfg.history.retentionCount` (default cap 500). `cfg.history.enabled` gates whether `RecordingOrchestrator` records entries.
- **Menu-bar app**: `NSApp.setActivationPolicy(.accessory)` at boot + `LSUIElement = YES` in Info.plist. No Dock icon by default; `ActivationPolicyTracker` flips to `.regular` while Settings or History windows are open. **Always** use `MenuBarExtra` + `Window(id:)` scenes for accessory apps — never `Settings { }` scene (macOS 14+ silently no-ops `showSettingsWindow:`).
- **`HoldDetector`** uses `CGEventTap` with `.defaultTap` (not `.listenOnly`) so it can swallow the main key on registered shortcuts. **Drop `@MainActor` from the tap callback** — `MainActor.assumeIsolated` segfaults from `@convention(c) CGEventTapCallBack` on macOS 14+. Guard core mutations with `NSLock`. Modifier flag events (`.flagsChanged`) are forwarded but never swallowed.
- **TCC grants follow the designated requirement (DR)**. Install only via `macos/scripts/install.sh`: it signs with the self-signed identity `VoiceType Local` (`--identifier com.macsilva.VoiceType`), giving DR `identifier … and certificate leaf = H"…"`, stable across builds. Ad-hoc (`--sign -`) gives DR `cdhash H"…"`, which changes every build → Accessibility/Mic grants silently stop matching after each reinstall (G-002, G-033). Without the right identifier, `UNUserNotificationCenter.requestAuthorization` also returns `notificationsNotAllowed`.
- **No Accessibility at launch ≠ relaunch needed**: `HoldDetector` keeps the registrations and polls `AXIsProcessTrusted()` every 1 s (+ on app activation), installing the tap as soon as the grant lands.
- **`Notifier`** dedupes on `(level + title + body)` within 5 s window. Bootstrap requests UN auth at `applicationDidFinishLaunching` (foreground required for first prompt).

## Permanent docs

Tracked technical documentation in `docs/`:

- `docs/architecture.md` — full component/dataflow reference (Core actors, App target modules, runtime flow, permissions matrix, storage layout).
- `docs/decisions.md` — ADRs (macOS 14 floor, MenuBarExtra+Window, CGEventTap custom, NSPasteboard+CGEvent paste, actor model, Codable JSON, manual distribution, swift-testing primary, hardcoded history cap, single-user scope).
- `docs/gotchas.md` — non-obvious traps with workarounds (MainActor in CGEventTap callback, TCC per-binary-path codesign identifier, DEVELOPER_DIR prefix, NSPanel level ordering, JSONDecoder iso8601 mismatch, etc.).
- `docs/follow-ups.md` — open tech debt (historyRetentionCount cap-narrowing, signed distribution pipeline, manual smoke pending).

## Packaging notes

- Targets macOS 14+ arm64 only; output `dist/*.dmg`.
- Daily workflow: Xcode → Product → Archive → Copy App from Organizer → `create-dmg` manually. Local install: `./macos/scripts/install.sh` (build Release, quit app, copy, clear quarantine, sign with `VoiceType Local`, fail if DR is cdhash, reopen). Signing identity overridable via `VOICETYPE_SIGN_IDENTITY`.
- Microphone entitlement in `macos/build/entitlements.plist`. Hardened runtime enabled at project level, but the installed binary is re-signed **without** `--options runtime` (same as the old ad-hoc install; ADR-011). No sandbox (required for `CGEventTap` + arbitrary paste).
- Mic permission prompt copy in Info.plist `NSMicrophoneUsageDescription`.
- Signed + notarized build (Developer ID + `xcrun notarytool`) — not scripted in this repo; run via Xcode Organizer when there's an active Apple Developer Program enrollment.
