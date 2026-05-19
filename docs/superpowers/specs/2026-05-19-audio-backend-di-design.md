# Audio backend DI — `SheetMusicAudio` 分割 (Android port Phase 3)

**Status:** draft (2026-05-19)
**Worktree:** `.claude/worktrees/audio-backend-di` (branch `feature/audio-backend-di`, off `main` HEAD `ed5b672`)
**Roadmap:** Phase 3 of 4 — see memory `project_android_port_roadmap`

## Goal

`SheetMusicAudio` の AVFoundation 依存を切り離し、Foundation-only 部分のみ Android の Swift 6.3 SDK でクロスコンパイルできる状態にする。Phase 2 (Font metrics DI) と同じ「Foundation-only umbrella + Apple-only conformance」パターンの Audio 版。

Apple ホストは既存の `import SheetMusicAudio` のままで `PlaybackEngine` を含む全 API が解決される。Android では `import SheetMusicAudio` から Foundation-only な型 (`PlaybackTimeline`, `MetronomeBeat`, `MixerChannel`, `LoopRange`, `PlaybackState`, `AudioFileFormat` など) のみが見え、`PlaybackEngine` は未定義シンボルになる。

## Non-goals

- **Android で実際に音を鳴らすバックエンドの実装**。AAudio / Oboe ブリッジや pure-Swift PCM レンダラは Phase 4 (Kotlin Compose Example) のスコープ。
- **`AudioBackend` 抽象 protocol の導入**。Phase 3 では「Apple は今までどおり、Android はビルドできるだけ」の最小スコープ。Phase 4 で Android 実装を加える際に protocol を切るかどうかを判断する。
- **`PlaybackEngine` の API 変更**。public 表面は据え置き。internal 構造のみ移動。
- **`@Observable` の cross-platform 化**。`@Observable` を使う `PlaybackEngine` は Apple-only に閉じ込めるので Phase 3 の射程外。
- **MS3/MS4 / MIDI / MSCX / Layout target の改修**。今回触るのは Audio 周りのみ。
- **新規テスト追加**。既存テストの移動・`#if !os(Android)` ゲートのみ。Android 上の挙動検証は Phase 4 で。
- **新規バンドル資源の移動**。Audio target には resources がない（SoundFont は host 供給）ので Phase 2 のような `Bravura.otf` 移動は発生しない。

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│ SheetMusicAudio (umbrella; Foundation-only as a module)        │
│                                                                │
│  役割: Apple では Apple 実装を、Android では Core 型を吸い上げる │
│  唯一の中身: SheetMusicAudio+Apple.swift                        │
│    #if canImport(AVFoundation)                                 │
│      @_exported import SheetMusicAudioApple                    │
│    #endif                                                       │
│    @_exported import SheetMusicAudioCore                       │
└────────────────────────────────────────────────────────────────┘
                ▲                            ▲
                │ Apple 時のみ依存          │ 常に依存
                │                            │
┌───────────────┴───────────────┐  ┌─────────┴───────────────────┐
│ SheetMusicAudioApple (NEW)    │  │ SheetMusicAudioCore (NEW)   │
│ Apple-only (AVFoundation)     │  │ Foundation-only             │
│                               │  │                             │
│  PlaybackEngine.swift         │  │  PlaybackTimeline.swift     │
│  PlaybackEngine+Export.swift  │  │  MetronomeBeat.swift        │
│  PlaybackEngine+Mixer.swift   │  │  GMInstrument.swift         │
│  MetronomeController.swift    │  │  MixerChannel.swift         │
│  MIDISynthBuilder.swift       │  │  SoundfontResolver.swift    │
│  Export/AudioExportWriter.swift│ │  LoopRange.swift (NEW 抽出) │
│  Export/AudioFileExporter.swift│ │  PlaybackState.swift (NEW   │
│                               │  │    抽出)                    │
│                               │  │  Export/AudioFileFormat.swift│
│                               │  │  Export/AudioExportError.swift│
│                               │  │  Export/AudioExportRange.swift│
└───────────────────────────────┘  └─────────────────────────────┘
   ↓ depends                          ↑
   SheetMusicAudioCore, Core, MIDI    (No deps on Apple / Audio)
```

### なぜこの形か

- **DI seam を target 境界で切る**。Phase 2 の `FontMetricsProvider` のような protocol を切らず、ファイルを物理的に Apple-only target に移すことで「Android 上で playback ができない」が型レベルで自明になる。Phase 4 で Android backend を追加する際に必要なら protocol を切る — 偽 interface を Phase 3 で作って Phase 4 で捨てるコストを避ける。

- **Apple consumer の import を 1 行も変えない**。`@_exported import SheetMusicAudioApple` を Apple 専用ファイル (`#if canImport(AVFoundation)` ガード) で行うので、Example / RenderPreviews / Tests / SheetMusicExampleMac は `import SheetMusicAudio` のままで PlaybackEngine が解決する。

- **umbrella target を作る理由**。SwiftPM は target に platform 条件付き dependency を渡せるが、target 自体の include/exclude は Swift コード (`isAndroid` フラグ) で行う必要がある。`SheetMusicAudio` を umbrella に変えれば、Apple ⇒ Apple+Core, Android ⇒ Core のみという切り替えが target dependency の `+ (isAndroid ? [] : ["SheetMusicAudioApple"])` で一行表現できる。

- **`SheetMusicAudioCore` を別 target に切る理由**。当初案では `SheetMusicAudio` 自体に Foundation-only 型を残し、`SheetMusicAudioApple` がそれに依存する形を検討した。しかし `SheetMusicAudio → SheetMusicAudioApple → SheetMusicAudio` の循環依存が発生する。`Core` を切り出すことで一方向の依存グラフ (`Core ← Apple ← Audio umbrella`) を維持できる。

### 既存 `SheetMusicAudio` 9 + 7 = 16 ファイルの分類

**Apple-only (`Sources/SheetMusicAudioApple/`) — 7 ファイル:**

| ファイル | 行数 | 移動先 |
|---|---|---|
| `PlaybackEngine.swift` | 841 (うち `LoopRange` / `PlaybackState` 計 ~20 行は Core へ抽出) | `SheetMusicAudioApple/` |
| `PlaybackEngine+Export.swift` | 354 | `SheetMusicAudioApple/` |
| `PlaybackEngine+Mixer.swift` | 126 | `SheetMusicAudioApple/` |
| `MetronomeController.swift` | 142 | `SheetMusicAudioApple/` |
| `MIDISynthBuilder.swift` | 164 | `SheetMusicAudioApple/` |
| `Export/AudioExportWriter.swift` | 338 | `SheetMusicAudioApple/Export/` |
| `Export/AudioFileExporter.swift` | 139 | `SheetMusicAudioApple/Export/` |

**Foundation-only (`Sources/SheetMusicAudioCore/`) — 8 既存 + 2 抽出:**

| ファイル | 行数 | 由来 |
|---|---|---|
| `PlaybackTimeline.swift` | 447 | 既存移動 |
| `MetronomeBeat.swift` | 104 | 既存移動 |
| `GMInstrument.swift` | 137 | 既存移動 |
| `MixerChannel.swift` | 44 | 既存移動 |
| `SoundfontResolver.swift` | 28 | 既存移動 |
| `Export/AudioFileFormat.swift` | 60 | 既存移動 |
| `Export/AudioExportError.swift` | 30 | 既存移動 |
| `Export/AudioExportRange.swift` | 17 | 既存移動 |
| `LoopRange.swift` (NEW) | ~10 | `PlaybackEngine.swift` 39-47 行から抽出 |
| `PlaybackState.swift` (NEW) | ~5 | `PlaybackEngine.swift` 29-31 行から抽出 |

**umbrella (`Sources/SheetMusicAudio/`) — 1 ファイルのみ:**

`SheetMusicAudio.swift`:
```swift
@_exported import SheetMusicAudioCore

#if canImport(AVFoundation)
@_exported import SheetMusicAudioApple
#endif
```

## Package.swift 変更

Phase 1 で確立した `isAndroid` フラグパターンに沿って、Apple 専用 target / product を条件付きで追加する。

```swift
let isAndroid = ProcessInfo.processInfo.environment["SWIFT_SHEET_MUSIC_ANDROID"] == "1"

let appleOnlyAudioTargets: [Target] = isAndroid ? [] : [
    .target(
        name: "SheetMusicAudioApple",
        dependencies: ["SheetMusicCore", "SheetMusicMIDI", "SheetMusicAudioCore"],
        path: "Sources/SheetMusicAudioApple"
    ),
]
let appleOnlyAudioProducts: [Product] = isAndroid ? [] : [
    .library(name: "SheetMusicAudioApple", targets: ["SheetMusicAudioApple"]),
]

// 既存 targets array に:
.target(
    name: "SheetMusicAudioCore",
    dependencies: ["SheetMusicCore", "SheetMusicMIDI"],
    path: "Sources/SheetMusicAudioCore"
),
.target(
    name: "SheetMusicAudio",
    dependencies: ["SheetMusicAudioCore"]
        + (isAndroid ? [] : ["SheetMusicAudioApple"]),
    path: "Sources/SheetMusicAudio"
),

// 既存 products array に:
.library(name: "SheetMusicAudioCore", targets: ["SheetMusicAudioCore"]),
```

`Sources/SheetMusicAudioApple/` の swiftlint file_length 上限超過は `// swiftlint:disable file_length` (既に PlaybackEngine.swift 1 行目にある) を維持。

## Data flow — import 経路

### Apple ホスト

```swift
import SheetMusicAudio
// → @_exported import SheetMusicAudioCore
// → @_exported import SheetMusicAudioApple (canImport(AVFoundation) で真)
// PlaybackEngine / AudioFileExporter / MIDISynthBuilder / 全 Foundation-only 型 が見える

let engine = PlaybackEngine(soundfontResolver: myResolver)
try engine.prepare(score: score)
engine.play(in: score)
```

`Example/SheetMusicExample` (iOS) と `Example/SheetMusicExampleMac` の dependency 行・import 行は **変更不要**。`SheetMusicAudio` を依存に持つだけで transitively Apple 実装が引き連れられる想定（検証は Plan で行う）。

### Android ホスト (Phase 4 で実装するが Phase 3 の compile boundary)

```swift
import SheetMusicAudio
// → @_exported import SheetMusicAudioCore のみ

let timeline = PlaybackTimeline(score: score)        // ✅
let beats    = PlaybackTimeline.metronomeBeats(score: score)  // ✅
let format   = AudioFileFormat.wav(PCMOptions())     // ✅
let engine   = PlaybackEngine(...)                   // ❌ 未定義シンボル (期待動作)
```

### Tests

- Foundation-only types を触るテスト (`MetronomeBeatTests`, `PlaybackTimelineTests` 等) は `@testable import SheetMusicAudio` のまま動く。Android でも実行される (新規)。
- Apple 固有テスト (`PlaybackEngineTests`, `AudioExportWriterTests`, etc.) は `#if !os(Android) ... #endif` でファイル全体をラップし、内部で `@testable import SheetMusicAudioApple` を追加 (`@_exported import` は `@testable` を transitive にしないため明示が必要 — CLAUDE.md "Recurring pitfalls" 参照)。

## Errors / Edge cases

1. **`@testable import` の transitivity 喪失**: PlaybackEngine の internal シンボル (`postProcessForMIDISynth(midi:)`, `setStateForExport(_:)`, `exportTimeline()` 等) を直接触るテストは `@testable import SheetMusicAudioApple` を併記。

2. **Sendable / `@MainActor`**: 抽出する `LoopRange` / `PlaybackState` は既に `Sendable, Equatable` で値型・isolation なし。Android でも `swift-corelibs-foundation` で問題なく利用可能。

3. **`@Observable`**: Apple-only `PlaybackEngine` に閉じ込められるので Android では一切露出しない。

4. **既存 `swiftlint:disable file_length`**: `PlaybackEngine.swift` 1 行目のマーカは移動後も維持。

5. **Mac/iOS xcodebuild 検証**: memory `feedback_example_app_outside_swiftpm` に従い、Example の Mac + iOS の両 xcodebuild を Plan の検証ステップで実行。

6. **visual verification は Mac で**: memory `feedback_visual_verify_mac` に従い `SheetMusicExampleMac` で実機再生確認。iOS シミュレータは使わない。

## CLAUDE.md / docs 更新

以下の文書更新が Plan のスコープ:

- **`CLAUDE.md`**: 「Library layout」セクションで `SheetMusicAudio` を `SheetMusicAudio` (umbrella) / `SheetMusicAudioCore` (Foundation-only) / `SheetMusicAudioApple` (Apple-only conformance) に書き換え。「Android build」セクションの「UI / PDF / Audio remain Apple-only pending Phase 3 audio DI」を「UI / PDF remain Apple-only pending Phase 4」に変更し、`SheetMusicAudioCore` が Android で利用可能と追記。
- **memory `project_android_port_roadmap`**: Phase 3 完了状態に更新。残: Phase 4 (Kotlin Compose example)。
- **`Sources/SheetMusicAudio/README.md`**: umbrella → Core / Apple の分割を反映。

## Testing strategy

Plan の検証ステップで以下を順に通す:

1. **macOS Apple build (非破壊)**
   - `swift build` / `swift test` (現在 1119 件 green) を全件維持
   - `swift test --filter MidiExportTests` の 12 件等価

2. **iOS Simulator (Example)**
   - `cd Example && xcodegen generate`
   - `xcodebuild ... -scheme SheetMusicExample ... build`

3. **Mac UI 動作確認** (memory `feedback_visual_verify_mac`)
   - SheetMusicExampleMac で: preview / play / loop / seek / pause / rate / mixer mute-solo / metronome on-off / audio export (WAV)

4. **Android cross-compile**
   - `TOOLCHAINS=org.swift.632202605101a SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28`
   - `--build-tests` 付きも green
   - `swift package describe` で SheetMusicAudioApple が graph に入っていないこと

5. **Android device test (推奨)**
   - `Scripts/android-test.sh aarch64`
   - Foundation-only テストが Android で green、Apple-gated テストはスキップ

6. **SwiftLint**
   - `swiftlint --quiet Sources Tests` で 0 warnings/errors

## Risks

- **SwiftPM 循環依存検出**: `SheetMusicAudio → SheetMusicAudioApple → SheetMusicAudioCore` の一方向グラフを維持できるかは Plan の最初の検証ステップで確認。circular になったら `SheetMusicAudio` umbrella target を廃止し、Apple consumer に `import SheetMusicAudioApple` を要求する Plan-B に切り替え (この場合 import 行の更新が Example / RenderPreviews / Tests で発生)。

- **`@_exported import` の動作確認**: Apple ビルドで `import SheetMusicAudio` 経由で PlaybackEngine が解決できることを `swift build` だけでなく Example の xcodebuild でも確認 (SwiftPM と xcodebuild で `@_exported` の挙動が稀にズレる前例があるため)。

- **テストの Android-gate 範囲推定**: Apple framework を触るテストファイル数を Plan の T1 で grep して数える。Phase 1 で 66 ファイルガード済みのため、Audio 関連の追加は数件想定。

## Branch / worktree layout

```
worktree:  .claude/worktrees/audio-backend-di  (new)
branch:    feature/audio-backend-di
base:      main @ ed5b672
```

Phase 3 はこの worktree で行う。完了後 main にマージし、memory `project_android_port_roadmap` を Phase 3 done に更新。Phase 4 は別 worktree で別途。
