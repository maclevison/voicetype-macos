# VoiceType — Arquitetura

App nativo macOS pra transcrever voz em texto refinado via Groq. Menu-bar app sem dock. Single user (autor). macOS 14+ (Sonoma) arm64 only.

## Stack

- Swift 5.10, SwiftUI + AppKit (cenas SwiftUI hospedadas em NSPanel/Window onde precisa).
- swift-testing (Core) + XCTest/XCUITest (App target).
- Xcode project + Swift Package Manager local pra `VoiceTypeCore`.
- `URLSession` async/await pra HTTP. `AVAudioEngine` pra captura. `CGEventTap` pra atalho global.

## Target layout

```
macos/
├── VoiceType.xcodeproj
├── VoiceType/                     App target — AppKit + SwiftUI shells
│   ├── App/                       @main, AppDelegate, RecordingOrchestrator, AppDependencies, snapshots, ErrorPresenter, Adapters/
│   ├── Features/
│   │   ├── Recording/
│   │   │   ├── Audio/             AudioRecorder, WavEncoder, AudioDeviceResolver
│   │   │   ├── Output/            Paster (NSPasteboard + synthesized Cmd+V), FocusedApp
│   │   │   ├── Shortcut/          HoldDetector (CGEventTap) + ShortcutManager
│   │   │   └── HUD/               HUDController + SwiftUI HUDView + waveform
│   │   ├── Settings/              7 SwiftUI sections + ShortcutRecorderField
│   │   ├── History/               SwiftUI Window scene + ViewModel + AppIconResolver
│   │   └── MenuBar/               MenuBarContent (SwiftUI MenuBarExtra)
│   ├── Platform/
│   │   ├── Notifications/         Notifier (UNUserNotificationCenter)
│   │   ├── Permissions/           PermissionsChecker actor
│   │   ├── AutoStart/             LoginItem (SMAppService facade)
│   │   └── ActivationPolicy/      ActivationPolicyTracker
│   └── Resources/                 Info.plist, Assets.xcassets/AppIcon.appiconset
├── VoiceTypeCore/                 SwiftPM package — zero AppKit
│   ├── Package.swift
│   └── Sources/Core/
│       ├── StateMachine/          AppStateMachine (actor)
│       ├── Config/                ConfigStore (actor) + AppConfig (Codable)
│       ├── History/               HistoryStore (actor)
│       ├── Pipeline/              Transcriber, Refiner, Translator, Pipeline (actor)
│       ├── GroqClient/            GroqClient + retry + multipart builder
│       └── Support/               Cancellable, Logger
├── build/                         entitlements.plist
└── scripts/                       make-icons.sh
```

## Componentes — Core (VoiceTypeCore)

| Módulo | Responsabilidade | Surface pública |
|---|---|---|
| `AppStateMachine` | Single source of truth: `idle \| recording \| processing`. Invalid transitions log + no-op, nunca throw. 5-min timeout auto-fire | `actor`, `send(_:) async`, `state`, `events: AsyncStream<StateChange>` |
| `ConfigStore` | Load/validate/persist `AppConfig`. Atomic write (tmp + rename). Lazy init. Subscribers notificados com array snapshot (copy-before-iterate) | `actor`, `load()`, `save(_:)`, `subscribe(_:)`, `resetForTests()` |
| `AppConfig` | Codable struct — schema v2. `schemaVersion: 2`. 5 sub-structs (`groq`, `shortcuts`, `recording`, `translate`, `history`) + 4 top-level booleans (`startAtLogin`, `showHud`, `errorNotifications`, `handsFreeEnabled`). Custom decoder migra silenciosamente payloads v1 (campos planos) para v2; o próximo `save()` persiste no formato v2. | Struct + `validate()` |
| `HistoryStore` | Append, cap em 500, list, delete by id, clear. JSON ISO8601 dates | `actor`, `add(_:)`, `list()`, `delete(id:)`, `clearAll()`, `subscribe(_:)` |
| `GroqClient` | URLSession wrapper. testKey + transcribe (multipart) + complete (chat). Retry exponencial (max 2). Cancellation-aware | `struct`, `testKey()`, `transcribe(audio:lang:)`, `complete(messages:model:)` |
| `Pipeline` | Orquestra transcribe → (refine \| translate \| raw). Cancelável via `Task` | `actor`, `run(audio:mode:lang:translateTarget:)` |
| `UseCases/UseCaseProtocols` | Protocolos Sendable abstraindo I/O (`AudioCapture`, `PasterDelivery`, `PipelineRunner`, `HistoryRecorder`, `StateMachineDriver`) usados pelos use cases — mantêm o Core AppKit-free | `protocol` (Sendable) |
| `UseCases/StartRecordingUseCase` | Guarda estado `.idle`, chama `AudioCapture.start`, emite `state.send(.start)`. Erros (`notIdle`, `permissionDenied`) propagados sem mutar estado | `struct`, `execute(deviceUID:) async throws` |
| `UseCases/StopRecordingUseCase` | Chama `AudioCapture.stop`, emite `state.send(.stop)`, valida bytes mínimos (default 16 044). Erros tipados: `notRecording`, `tooShort`, `capture` | `struct`, `execute() async throws -> Data` |
| `UseCases/RunPipelineUseCase` | Encadeia `PipelineRunner.run` → `PasterDelivery.paste` → `HistoryRecorder.record` em um fluxo linear; respeita `historyEnabled` | `struct`, `execute(audio:mode:lang:translateTarget:targetBundleId:historyEnabled:historyCap:) async throws` |

## Componentes — App target

| Módulo | Responsabilidade |
|---|---|
| `AppDelegate` | `applicationDidFinishLaunching` ordem: `setActivationPolicy(.accessory)` → `ConfigStore.load()` → `MenuBarController.start()` → `ShortcutManager.applyConfig()` → `Notifier.bootstrap()` (com `onAuthChanged` setado antes) → `RecordingOrchestrator.start()` |
| `RecordingOrchestrator` | `@MainActor` singleton. Compõe `StartRecordingUseCase` + `StopRecordingUseCase` + `RunPipelineUseCase` (Core) por trás dos handlers `handlePressed` / `handleReleased`. Mantém apenas lifecycle (tasks de shortcut, HUD, level meter) + UI side-effects (notifications, HUD show/hide). Cancela pipeline ativo se nova gravação inicia |
| `App/Adapters/*` | Bridges entre tipos AppKit-bound e os protocolos Sendable do Core: `AudioCaptureAdapter` (traduz `AudioRecorderError.permissionDenied` → `StartRecordingUseCase.Error.permissionDenied`), `StateMachineAdapter`, `PasterDeliveryAdapter` (resolve `targetBundleId` → `FrontmostAppSnapshot`), `PipelineRunnerAdapter`, `HistoryRecorderAdapter` |
| `MenuBarController` | `MenuBarExtra` scene (não NSStatusItem direto). Ícone por estado, items: Configurações…, Histórico…, Quit |
| `HUDController` | `NSPanel` flutuante non-activating, borderless, screen-bottom-center. Hospeda `HUDView` via `NSHostingView`. Level meter + timer. O visualizador é `AuroraWaveform`, dirigido pelo enum `WaveformColorPreset` resolvido de `AppConfig.waveformPreset` a cada `hud.show` |
| `ShortcutManager` | Wraps `HoldDetector`. Registra `refineShortcut` + `translateShortcut`. Emite `pressed(mode:)` / `released(mode:)`. Re-aplica config no save |
| `HoldDetector` | `CGEventTap` em `kCGSessionEventTap` com `.defaultTap` (consome main key). Acompanha modifier hold/release. Callback `@convention(c)` SEM `@MainActor` |
| `AudioRecorder` | `AVAudioEngine` tap. Permissão mic flow. 16 kHz mono PCM com header WAV. Seleção de device + USB-disconnect detection |
| `Paster` | Captura frontmost app no click, copia pra `NSPasteboard`, sintetiza Cmd+V via `CGEvent`. Restaura clipboard original com delay |
| `Notifier` | `UNUserNotificationCenter` wrapper. Dedupe `(level + title + body)` 5 s window, GC entries > 64. Bootstrap em `applicationDidFinishLaunching` |
| `LoginItem` | `SMAppService.mainApp` register/unregister. Facade com enum `.enabled / .notRegistered / .requiresApproval / .notFound` |
| `PermissionsChecker` | `@Observable` actor. Status live de Mic, Accessibility, Notifications + deep-links `x-apple.systempreferences:…` |
| `ActivationPolicyTracker` | Counter shared pra flips `.regular` ↔ `.accessory` enquanto a janela principal está aberta (mantém Dock icon visível enquanto uma delas tiver aberta) |

## Runtime flow

1. `VoiceTypeApp` (`@main`) → `NSApplicationDelegateAdaptor(AppDelegate.self)`.
2. `AppDelegate.applicationDidFinishLaunching` faz bootstrap (ver acima).
3. Usuário segura `refineShortcut`:
   - `HoldDetector` callback → `ShortcutManager.pressed(.refine)`.
   - `RecordingOrchestrator` → state machine `.idle → .recording`, abre HUD, `AudioRecorder.start()`.
   - HUD pulsa waveform, timer cresce. State machine arma 5-min timeout.
4. Usuário solta atalho (ou timeout fire):
   - `AudioRecorder.stop()` → WAV `Data`.
   - State machine `.recording → .processing`.
   - `Pipeline.run(audio:, mode: .refine, lang:, translateTarget:)` executa.
   - `Paster.paste(text:target: frontmostAppAtRecordingStart)`.
   - State machine `.processing → .idle`.
   - `HistoryStore.add(...)`.
5. Erro em qualquer stage: `Notifier.error(...)`, restore `.idle`, log via `os.Logger`.
6. Nota de voz (#79, modo 1): `voiceNoteShortcut` (default `Alt+N` = ⌥N, segurar; vazio = desligado) roda o mesmo fluxo com `Mode.voiceNote`, mas o `RunPipelineUseCase` recebe `DailyNoteDeliveryAdapter` no lugar do `Paster`: `DailyNote.append` grava `- HH:mm texto` sob `## Ideias` em `<meetingNotesFolder>/Daily/YYYY/YYYY-MM-DD.md` (cria a nota/seção se faltar; escrita atômica). Estilo de refino e histórico usam `md.obsidian`. Falha de escrita → texto vai pro clipboard + notificação de erro.

## Permissions matrix

| Permissão | API | Quando | Falha UX |
|---|---|---|---|
| Microphone | `AVCaptureDevice.requestAccess(for: .audio)` | Primeira gravação | Notif + HUD `.permissionDenied` overlay + link Settings |
| Accessibility | `AXIsProcessTrustedWithOptions` | Bootstrap (prompt: false) | Push-to-talk inerte; Settings → Inicialização → Permissões mostra status + deep-link |
| Notifications | `UNUserNotificationCenter.requestAuthorization` | Bootstrap | Fallback silencioso (state machine OK); status feeds back via `PermissionsChecker.setNotificationsAuthorized(_:)` |
| Login item | `SMAppService.mainApp.register()` | Settings toggle | `SMAppService` error surfaced via Notifier |

## Storage

`~/Library/Application Support/VoiceType/`:

- `config.json` — atomic write (tmp + rename). `JSONDecoder`. `schemaVersion: 2`. Arquivos v1 são migrados silenciosamente no load; re-escritos em v2 no próximo save.
- `history.json` — `[HistoryEntry]`, capped 500 (oldest evicted em `add`). Dates ISO8601.

`HistoryEntry`:
```swift
struct HistoryEntry: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    let mode: HistoryMode   // .refine | .translate | .raw
    let sourceApp: String   // bundle id ou ""
    let text: String
}
```

## Pipeline

```swift
public actor Pipeline {
    public enum Mode { case refine, translate, raw }

    public func run(
        audio: Data, mode: Mode, lang: String, translateTarget: String?
    ) async throws -> String {
        let raw = try await transcriber.transcribe(audio: audio, lang: lang)
        switch mode {
        case .refine:    return try await refiner.refine(text: raw, style: config.refineStyle)
        case .translate:
            guard let t = translateTarget else { throw PipelineError.missingTranslateTarget }
            return try await translator.translate(text: raw, target: t)
        case .raw:       return raw
        }
    }
}
```

Cada step tem seu `URLSession` com timeouts (connect 5 s, resource 60 s). Retries exponenciais, max 2, respeitam `Task.checkCancellation()` entre tentativas.

## Janela principal

Uma única cena `Window("VoiceType", id: "main")` (`MainWindowView`): `NavigationSplitView` com **Histórico** no topo do sidebar e o grupo **Configurações** abaixo (uma linha por `SettingsSection`: Geral, Atalhos, Áudio, Transcrição local, Refino on-device, Estilo por app, Vocabulário, Aparência, Armazenamento, Reuniões, Inicialização, Sobre).

`MainWindowRouter` (`@Observable`, criado em `VoiceTypeApp`, injetado via `.environment`) guarda a seleção. "Histórico…" / "Configurações…" do menu setam a seleção e chamam `openWindow(id: "main")`: janela já aberta troca de painel, janela nova nasce no destino.

- **Histórico:** tabela com busca; ações por entrada Recolar (`LivePaster` captura `FocusedApp.snapshot()` no click), Copiar, Apagar; toolbar com Apagar tudo.
- **Armazenamento:** liga/desliga histórico + retenção (1–500) + "Ver histórico" (só troca a seleção).

Autosalva em ~400 ms debounce. Indicador `Salvando…` / `Salvo` no canto.

## OpenKnowledge

Com **Reuniões → Vault = OpenKnowledge** (`AppConfig.meetingVaultKind = .openKnowledge`, raiz em `openKnowledgeVaultPath`, a pasta que tem `.ok/`), a reunião não vai direto para o vault: vira uma **pendência** que o usuário aprova passo a passo. Nada pede atenção sozinho: o menu mostra "N reuniões aguardando aprovação" e a janela só abre por "Revisar…". A lógica fica em `VoiceTypeCore/Sources/Core/OpenKnowledge/`; o app tem o ramo OK do `MeetingProcessor`, `PendingApprovals` (lista + recuperação), `ApprovalRouter` e a janela `Window(id: "approval")` (`ApprovalWindowView` + `ApprovalViewModel`).

Fluxo:

1. **Processamento** (`MeetingProcessor.propose`): transcrição + resumo como no modo Obsidian, depois `OKProposalBuilder.build` sugere o projeto (`OKAssistant.suggestProject`), fixa os caminhos do registro e destila o conhecimento contra os docs do projeto (`planDistillation` + `writeDistillation`, via `ClaudeCLISummarizer.complete`, sem tools, conteúdo não confiável só no stdin). Qualquer falha do modelo cai em `distillationError` e a pendência continua aprovável só com registro + transcrição. A proposta é gravada por `MeetingProposalStore.replaceFromReprocessing` (recusa com journal ou se uma aprovação terminou no meio).
2. **Aprovação** (`OKApprovalSession`, valor puro; o VM persiste cada mudança): passo Projeto (sugerido pré-selecionado, busca, "Novo projeto…"; trocar de projeto redestila, ou só `repath` sem resumo/sem modelo), passo Registro, um passo por item (novo, atualização ou conflito) com Preview (`OKMarkdownHTML.document` num `WKWebView` sem JavaScript e sem navegação; atualização mostra o diff) e Editor. Aprovar carimba o hash do Markdown e da base mostrada; edição, redestilação ou conflito que mude qualquer um anula o carimbo.
3. **Gravar** (`ApprovalViewModel.commit`): com item aprovado relê o catálogo e redestila se mudou ou passou de 24 h (`OKProposalBuilder.isStale`); realoca o registro se outra reunião tomou o nome (`relocateIfTaken`); então, dentro de `MeetingProposalStore.withLock`, confere a geração e chama `OKVaultWriter.commit` com um `precondition` que repete as checagens já com a intenção gravada. `.committed` → `OKApprovalFinalizer.finalize` + notificação de sucesso; `.partial` → `finalizePartial` (registro gravado, só os itens em conflito voltam); `.conflicts` → os itens voltam para revisão com a versão atual. A sessão e a proposta presas a uma geração (`generation`) nunca gravam sobre outra: reprocessar com a janela aberta recarrega a janela.
4. **Recuperação**: `PendingApprovals.bootstrap()` no launch e `recoverMeeting` ao abrir a reunião terminam ou desfazem um journal deixado por crash, sempre no vault gravado no journal (`OKVaultIdentity`: caminho canônico + device/inode), nunca no da config.

Arquivos no diretório da reunião (`~/Library/Application Support/VoiceType/Meetings/<AAAA-MM-DD_HHmmss>/`), todos lidos e escritos sob `MeetingProposalStore.withLock`:

| Arquivo | Conteúdo |
|---|---|
| `ok-proposal.json` | `MeetingProposal`: geração, vault de origem, nota, projeto sugerido/escolhido, caminhos (persistidos, nunca recalculados por baixo), hashes do que já existe, fingerprint do catálogo, `distilledAt`, itens destilados. Existe enquanto a reunião está pendente |
| `ok-progress.json` | `OKApprovalProgress` da janela: passo, projeto (ou projeto novo), carimbos de aprovação, edições. Progresso de outra geração é ignorado |
| `ok-commit/journal.json` | Intenção durável do `OKVaultWriter` (ops, hashes esperados, nomes no staging, fase). Some depois de `finish` |
| `pipeline.json` | Ganha `okVault`, `okProject`, `okRecordPath`, `okTranscriptPath` depois da primeira aprovação: re-aprovar a mesma reunião reusa os caminhos e trava o projeto |

Layout no vault:

```
<vault>/
├── README.md                         ## Projetos: um item por projeto (projeto novo entra aqui)
├── <projeto>/
│   ├── index.md                      type: indice; "## Conhecimento registrado" com links dos docs novos
│   ├── reunioes/AAAA-MM-DD-<slug>.md registro (frontmatter OK + "Conhecimento destilado")
│   ├── reunioes/transcricoes/…md     transcrição, mesmo nome do registro
│   └── decisoes/ regras-de-negocio/ arquitetura/ tutoriais/ gotchas/ glossario/ snippets/
│       (cada pasta com .ok/frontmatter.yml)
├── _inbox/diario/AAAA-MM-DD.md       notas de voz do dia (links relativos)
├── _inbox/ideias/…md
└── .ok/local/voicetype-staging/      temporários e cópias do writer (fora do git do OK)
```

A escrita é transacional: temporários e preimagens no staging, `RENAME_SWAP` condicional por hash, nenhuma versão de terceiro apagada sem cópia (`.ok/local/voicetype-preserved/`). Ver ADR-012.

## Build + distribuição

Targets macOS 14+ arm64 only. Output `dist/`.

Install local: `./macos/scripts/install.sh` (Release → `/Applications`, assinado com o cert self-signed `VoiceType Local` pra DR estável e TCC sobreviver a reinstalações; ADR-011, G-002). DMG pra terceiros: `macos/scripts/release.sh` (ad-hoc).

Pipeline signed + notarized (Developer ID + `xcrun notarytool`) **não automatizado** neste repo ainda — pendente de Apple Developer Program enrollment ativo. Quando rodar, ver `docs/decisions.md` ADR-007.

Entitlements em `macos/build/entitlements.plist`: `com.apple.security.device.audio-input`. Hardened runtime habilitado no project level. **No sandbox** — incompatível com `CGEventTap` + paste arbitrário.

Info.plist: `LSUIElement: YES`, `NSMicrophoneUsageDescription`, `LSMinimumSystemVersion: 14.0`.

## Toolchain

- Xcode 15.4+ na conta dev. `xcode-select -p` pode apontar pra CommandLineTools (sem XCTest/swift-testing) — workaround: prefix CLI calls com `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (ver `docs/gotchas.md`).
- Sem linter separado; Swift compiler em strict-concurrency é o gate.
