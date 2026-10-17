# Architecture Decision Records

Decisões principais do native macOS build. Cada ADR registra contexto, escolha, alternativas consideradas, e por quê.

---

## ADR-001 — macOS 14 (Sonoma) como mínimo

**Contexto:** Native rewrite (2026-05) precisa definir floor.

**Decisão:** `LSMinimumSystemVersion = 14.0`. Apple Silicon only.

**Por quê:** macOS 14 destrava:
- `Observation` framework (`@Observable` em SwiftUI).
- `MenuBarExtra` scene (estável; quirks de versões anteriores resolvidos).
- `SMAppService` (login item moderno, vs `SMLoginItemSetEnabled` deprecado).
- swift-testing toolchain via Xcode 15.4+.

**Alternativas consideradas:**
- macOS 11+ — perderia `@Observable`, forçaria `@StateObject`/`ObservableObject` boilerplate.
- Universal binary (arm64 + Intel) — single-user dev tem só Apple Silicon, custo de build/test não compensa.

---

## ADR-002 — `MenuBarExtra` + `Window(id:)` ao invés de `Settings { }` scene

**Contexto:** App é `LSUIElement` (sem dock). Precisa abrir a janela principal (Histórico + Configurações) do menu bar.

**Decisão:** `MenuBarExtra` (não `NSStatusItem` custom) + uma cena `Window("VoiceType", id: "main")` (Histórico e Configurações no mesmo sidebar desde 2026-10-15; antes eram duas janelas). Use `@Environment(\.openWindow)` pra abrir. `ActivationPolicyTracker` flipa `.accessory ↔ .regular` enquanto janelas abertas.

**Por quê:** macOS 14+ removeu `showSettingsWindow:` (loga `Please use SettingsLink for opening the Settings scene` e silenciosamente no-op). Pior: mesmo quando `Settings { }` scene abre via `SettingsLink`, ela parasita ownership do app focado em frontmost e fecha junto.

**Alternativas consideradas:**
- AppKit `NSStatusItem` + custom `NSMenu` — controle total mas duplica esforço pra renderizar `MenuBarContent` SwiftUI.
- `Settings { }` scene — quebrada em `LSUIElement` apps (testado, post-install fix `2e93993` reverteu).

**Aprendizado:** sempre `MenuBarExtra` + `Window` em accessory apps. Nunca `Settings { }`.

---

## ADR-003 — `CGEventTap` custom para hold detection (sem Sindre Sorhus's `KeyboardShortcuts`)

**Contexto:** Push-to-talk precisa hold/release semantics em atalho global. KeyboardShortcuts lib é estável mas só expõe "pressed" event, não hold/release.

**Decisão:** Single `CGEventTap` em `kCGSessionEventTap` com `.defaultTap` processa keyDown (match main key + modifier flags) e keyUp/flagsChanged (release tracking). Sem SPM dep.

**Por quê:**
- Eliminamos dependency externa.
- Mesmo tap pode swallow main key consumido em shortcut registrado (evita flood de espaços em terminal quando Cmd+Shift+Space é o atalho).
- Phase 6 pode revisitar KeyboardShortcuts SE Settings UI precisar do `NSView` shortcut recorder dele — mas Phase 6 acabou implementando `ShortcutRecorderField` custom via `NSEvent.addLocalMonitorForEvents`, então a dep nunca foi necessária.

**Alternativas consideradas:**
- `KeyboardShortcuts` lib — bom DX mas não dá hold/release nativo, ainda precisaria do event tap.
- `uiohook-napi` (rota Electron) — Node-bound, dead-end pra native.

**Gotchas relacionados:** `CGEventTap` callback `@convention(c)` NÃO pode usar `MainActor.assumeIsolated` em macOS 14+ — segfault. Ver `docs/gotchas.md` G-001.

---

## ADR-004 — `NSPasteboard` + sintetizar `Cmd+V` via `CGEvent` pra paste

**Contexto:** Output do pipeline precisa colar no app focado.

**Decisão:** `Paster` captura `FocusedApp.snapshot()` no início da gravação, copia texto pra `NSPasteboard.general`, depois sintetiza `CGEvent` Cmd+V. Restaura clipboard original com delay.

**Por quê:**
- `osascript "tell ⟨app⟩ to keystroke …"` é frágil (depende de Automation permission distinta).
- Direct CGEvent → mesma TCC permission (Accessibility) já necessária pro HoldDetector.

**Alternativas consideradas:**
- AppleScript via NSAppleScript — requer permission separada por app target.
- Type via Accessibility API direto — não funciona em apps sem AX hierarchy.

---

## ADR-005 — Actor model pro Core (StateMachine, ConfigStore, HistoryStore, Pipeline)

**Contexto:** Concurrency strict mode no Swift 5.10 + macOS 14. Precisa shared state thread-safe.

**Decisão:** Cada componente Core stateful é Swift `actor`. App-side singletons (`RecordingOrchestrator.shared`) são `@MainActor` final classes.

**Por quê:**
- Actor isolation elimina race conditions sem locks manuais.
- `AsyncStream` para subscribers (state changes, config updates, history snapshots).
- Cancellation propaga via `Task` natural.

**Subscriber pattern:** notify dentro de `save(_:)` / `add(_:)` itera sobre **cópia** do array de subscribers (`subscribers.values` snapshot) pra evitar reentrancy quando handler chama `save` de novo. Mesmo padrão do Electron FU-004 mitigation.

---

## ADR-006 — Codable JSON storage (atomic write) ao invés de SQLite / UserDefaults

**Contexto:** Persistência de `AppConfig` + `HistoryStore`.

**Decisão:** `~/Library/Application Support/VoiceType/{config,history}.json`. Atomic write: data → `file.tmp` → `rename`. `JSONEncoder` com `outputFormatting: [.prettyPrinted, .sortedKeys]`. Dates ISO8601.

**Por quê:**
- Single-user scale — dados < 1 MB sempre.
- Editável manualmente em emergência.
- `schemaVersion: Int` no AppConfig dá hook pra futuras migrations sem trocar storage.

**Alternativas consideradas:**
- SQLite — overkill, complica testing.
- UserDefaults — opaque, perde controle do path, sync com iCloud sem opt-in.
- Realm/SwiftData — dependency pesada pra benefício zero em single-user.

**Gotcha:** `HistoryStore` usa `.iso8601` dateEncoding/Decoding explicitamente. `ConfigStore` usa default (AppConfig não tem Date). Round-trip tests cobrem.

**Versão atual:** `schemaVersion: 2`. Shape v2 decompõe os 17 campos planos da v1 em 5 sub-structs (`groq`, `shortcuts`, `recording`, `translate`, `history`). A migração v1→v2 é silenciosa via custom `init(from:)`: ao detectar `schemaVersion < 2` (ou ausente), remapeia as chaves planas para os sub-structs. Nenhum framework de migração separado é necessário.

---

## ADR-007 — Distribuição: manual via Xcode Organizer + create-dmg

**Contexto:** Build de distribuição precisa de pipeline.

**Decisão:** Daily workflow é manual via Xcode Archive → Organizer → Copy App → `create-dmg`. Install local via `macos/scripts/install.sh` (ver ADR-011). Pipeline scriptado (signed + notarized) **não commited** ainda — pendente Apple Developer Program enrollment.

**Por quê:**
- Sem cert Developer ID ativa, signed pipeline seria placeholder.
- Single-user, distribuição zero pública.
- Scripts ad-hoc (no Notes app/local shell) suficientes pro use case atual.

**Quando re-visitar:** ao enrolar no Apple Developer Program ($99/ano). Aí `release.sh` env-gated faz sentido: signed quando `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`, `CSC_LINK`, `CSC_KEY_PASSWORD` setados; ad-hoc fallback senão. Esqueleto está documentado nos plans (deletados); refazer copiando o pattern do `electron-builder.cjs` antigo.

---

## ADR-008 — swift-testing primary (Core), XCTest legacy (App target)

**Contexto:** macOS 14 + Xcode 15.4 destrava swift-testing.

**Decisão:** `VoiceTypeCore/Tests/CoreTests/` usa swift-testing (`@Test`, `@Suite`, `#expect`). `macos/VoiceTypeTests/` é XCTest (mais maduro pra app-target + UI tests).

**Por quê:**
- swift-testing tem `@Test func` mais ergonômico, parallelism by default, parametrized tests nativos.
- XCTest é o que UI tests + `XCUIApplication` ainda exigem.
- Mixing nos dois bundles funciona; consistência por bundle simplifica setup.

---

## ADR-009 — `historyRetentionCount` estreita o cap real em `HistoryStore.add(_:cap:)`

**Contexto:** Settings → Histórico tem campo `retention count (1-500)` que persiste em `AppConfig.history.retentionCount` (v2).

**Decisão (atual):** `HistoryStore.add(_:cap:)` aceita `cap` como parâmetro (default 500). `RecordingOrchestrator` lê `cfg.history.retentionCount` e passa via `historyStore.add(entry, cap: historyCap)`. FU-N1 fechado em commit 320f5e1 (2026-05-21).

**Histórico:** phase 7 priorizou shipping e deixou o wiring aspiracional. Fase B (AppConfig decompose) completou o wiring junto com a migração dos campos aninhados.

---

## ADR-010 — Single-user, zero feature creep

**Contexto:** Múltiplos pedidos rondam (multi-language, auto-update, telemetry).

**Decisão:** Out of scope até alguém pedir. Single-user (autor). Manual updates via re-instalação. No telemetry. PT-BR única locale UI (Whisper hardcoded `lang: "pt"`).

**Quando re-visitar:** se app virar distribuído publicamente. Aí: auto-update via `Sparkle`, telemetry opt-in, i18n via `Localizable.strings`.

---

## ADR-011 — Assinatura local self-signed estável em vez de ad-hoc

**Contexto:** a cada reinstalação o macOS "esquecia" Accessibility/Microfone. Causa: re-sign ad-hoc gera designated requirement `cdhash H"…"`, que muda a cada build; TCC deixa de casar (G-002).

**Decisão:** instalar via `macos/scripts/install.sh`, que assina com o cert self-signed `VoiceType Local` da login keychain (override `VOICETYPE_SIGN_IDENTITY`). DR resultante: `identifier "com.macsilva.VoiceType" and certificate leaf = H"…"`, estável enquanto o cert existir. O script falha se a DR for cdhash.

**Hardened runtime:** o binário instalado **não** usa `--options runtime`, igual ao ad-hoc que sempre rodou (mic + CGEventTap OK). `--options runtime --entitlements macos/build/entitlements.plist` assina e verifica com o cert self-signed, mas não foi validado em uso real (mic sob runtime, library validation sem Team ID) — sem ganho pra single-user local, fica fora.

**Por quê não:**
- Ad-hoc — DR muda por build (o problema).
- Apple Development / Developer ID — exige conta paga (ADR-007); quando houver, `VOICETYPE_SIGN_IDENTITY` aponta pra ela sem mudar o script.

**Custo:** o cert não é trusted (Gatekeeper rejeita em `spctl`, irrelevante pra app local sem quarantine). Perder a chave = conceder permissões de novo uma vez. Backup da chave fica fora do repo.

---

## ADR-012 — Reuniões no OpenKnowledge via proposta + aprovação + escrita transacional direta no disco

**Contexto:** o vault é um projeto OpenKnowledge editado ao mesmo tempo pelo servidor do OK (CRDT, auto-save, auto-commit), por agentes e pelo usuário. A spec pede que nada entre sem o usuário ver (reunião vira pendência, aprovação passo a passo), que nada seja sobrescrito sem revisão, que uma gravação pela metade nunca deixe link quebrado (registro sem transcrição, ADR citando reunião inexistente) e que fechar a janela ou o app morrer no meio não perca nem estrague nada. Anti-objetivos: abrir a janela sozinha, notificação pedindo aprovação, dependência de servidor rodando.

**Decisão:** a reunião processada vira `ok-proposal.json`; a janela grava o progresso por geração; "Gravar" passa por `OKVaultWriter.commit`, que escreve os arquivos direto no disco do vault:
- intenção durável primeiro (journal com `F_FULLFSYNC` + staging em `.ok/local/voicetype-staging/`, ignorado pelo git do OK);
- troca atômica condicional: cada update confere o hash esperado e entra por `RENAME_SWAP`, a versão que saiu é conferida e guardada; create só onde não há arquivo;
- recibo (`OKCommitReceipt`) no journal até o estado local ser concluído (`OKApprovalFinalizer`), então qualquer crash é terminado ou desfeito pelo próximo launch a partir do disco.

O watcher do OK reconcilia a escrita externa no CRDT e o auto-commit a versiona (evidência: portão da Task 0, `macos/scripts/ok-write-probe.sh`, e o probe do planejamento: merge de 3 vias limpo do disco no Y.Doc, auto-commit em menos de 75 s, conteúdo intacto depois de restart). O app não usa `ok` CLI nem MCP.

**Consequências:**
- Sem dependência do servidor OK: grava com ele parado, e o próximo `ok start` reconcilia.
- Nenhuma versão concorrente é apagada sem cópia: rollback só desfaz o que ainda é exatamente nosso; uma versão de terceiro escrita depois da nossa força a conclusão (todas as ops já foram aprovadas) e é preservada em `.ok/local/voicetype-preserved/`.
- O `.okignore` não é usado (tira os arquivos também do git).
- Custo: o writer (journal, classificação por estado do disco, recuperação) é a parte mais complexa do app e tem testes de crash em cada ponto.

**Alternativas consideradas:**
- **Cliente MCP (`ok mcp`) dentro do app** — escreveria pelo CRDT, mas exige o servidor rodando e um cliente MCP no app. É o **plano B** se a escrita externa deixar de sobreviver ao OK com editor conectado (portão da Task 0).
- `ok` CLI por arquivo — sem transação entre arquivos, mesma dependência do servidor.
- Escrever direto sem journal — crash no meio deixa links quebrados.
