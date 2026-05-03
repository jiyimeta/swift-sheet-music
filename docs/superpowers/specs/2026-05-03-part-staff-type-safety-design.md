# Part / Staff 型安全化リファクタ — 設計書

- 日付：2026-05-03
- 対象モジュール：`SheetMusicCore` / `SheetMusicMSCX` / `SheetMusicMusicXML`
  / `SheetMusicMIDI` / `SheetMusicLayout` / `SheetMusicAudio` /
  `SheetMusicUI` / `SheetMusicPDF`（importer 凍結中だが組み立て先のみ追従）
- 互換方針：private repo のため public API の破壊的変更を許容。互換 shim
  は導入しない。

## 背景

現状の `Score` は `parts: [Part]` と `staves: [StaffContent]` を **別配列で
並列保持**している。Part と top-level `<Staff>` の対応は MuseScore mscx の
ドキュメント順依存で、`MidiRenderer.staffOwnership(...)` が暗黙の
1:1 + 連続消費規則をランタイムで再構築している。

この構造には二つの欠点がある：

1. **型レベルで対応関係が保証されない**。実態は (Vln, Vln, Piano=2譜, Vc) の
   ような並びだが、型シグネチャだけでは「Part の宣言 staff 数の総和 ＝
   `score.staves.count`」も「並びが一致」も担保できない。
2. **既存バグの温床になっている**。`SheetMusicLayout` の複数箇所が
   「staff index = part index」と仮定しており、Part 内に複数 Staff を持つ
   構成（Piano 等）で part 名表示と clef がズレる。
   - `Sources/SheetMusicLayout/Layout/LayoutEngine+Contexts.swift:67`
   - `Sources/SheetMusicLayout/Layout/LayoutEngine+Packing.swift:319-320,362`
   - `Sources/SheetMusicLayout/Layout/LayoutEngine+SystemBuild.swift:102,401`

   ユーザ観測：(part1, part2, part3=Piano, part4) の構成で staff5 を引いた
   とき、期待値（part3 の 2 つ目の StaffDeclaration = F clef）ではなく
   part4 の `staffDeclarations.first`（G clef）が引かれ、part 名表示も
   1 譜ぶんずつズレて「(名なし)-staff5」が出ていた。

ネスト化（Part が自分の Staff を所有）して `score.staves` を廃止すれば、
こうしたコードを **書こうとしてもコンパイルが通らない**形になる。

## 非ゴール

- mscx 以外のフォーマット（MusicXML / PDF / MIDI import）の機能拡張。本
  リファクタの範囲は型シグネチャ変更に伴う追従のみ。
- `Editing/*`（`ReplaceVoiceElements`、`DurationChangeAlgorithm`）の API
  改善。アドレス型の置換に伴う最小書き換えのみ。
- `score.staves` の互換 shim 提供。private repo の breaking change を
  許容する前提。
- 既存 GPL test fixture の置き換え。多 Part 多 Staff の検証は test-only な
  自作 fixture を新設する。

---

## §1. 型レイアウト

```swift
// SheetMusicCore

public struct Score: Sendable, Equatable {
    public var division: Int
    public var parts: [Part]                // 単一の真実
    public var metaTags: [String: String]
    public var titleFrame: ScoreFrame?
    public var style: ScoreStyle
    // score.staves は廃止（互換 shim も入れない）
}

public struct Part: Sendable, Equatable {
    public var id: String
    public var trackName: String?
    public var instrument: Instrument
    public var staves: [Staff]              // ネスト。順序＝表示順
}

/// 旧 StaffDeclaration + StaffContent を統合した一型。
public struct Staff: Sendable, Equatable {
    public var staffType: String            // "stdNormal" 等
    public var group: String                // "pitched" 等
    public var defaultClefType: String?     // "G" / "F" / "PERC"
    public var measures: [Measure]
}
```

破棄するもの：

- `StaffContent`、`StaffDeclaration`（`Staff` に一本化）
- `Score.staves`、`StaffContent.id: Int`（位置で識別）
- `MidiRenderer.staffOwnership(...)`（自明になる）

---

## §2. アドレス型と resolve

```swift
// SheetMusicCore

public struct StaffAddress: Hashable, Sendable, Comparable {
    public let partIndex: Int
    public let staffIndexInPart: Int

    public static func < (l: Self, r: Self) -> Bool {
        (l.partIndex, l.staffIndexInPart) < (r.partIndex, r.staffIndexInPart)
    }
}

extension Score {
    /// 全 part の全 staff を表示順で列挙。enumerate で旧 staffIndex 相当が取れる。
    public var allStaves: [(address: StaffAddress, staff: Staff)] { ... }

    public subscript(address: StaffAddress) -> Staff? { ... }
    public func part(at address: StaffAddress) -> Part? { ... }
}
```

`NoteID` / `VoiceElementID` / `RestID` などは `staffIndex: Int` を
**`staff: StaffAddress`** に置換。

```swift
public struct NoteID: Hashable, Sendable {
    public let staff: StaffAddress
    public let measureIndex: Int
    public let voiceIndex: Int
    public let elementIndex: Int
    public let noteIndexInChord: Int
}
```

旧コードの「flat staff index」依存
（`PlaybackEngine`、`MetronomeBeat`、`PlaybackTimeline`、
`SelectionRenderState`、`PlaybackCursorView`、`LayoutEngine+Spanners` 等）
は `score.allStaves` のイテレーションに書き換える。`(address, staff)` ペア
が取れるので、part を引きたいときは `address.partIndex` で即引ける。

---

## §3. MSCX デコーダの再構築

現状の `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Score.swift` は
`<Part>` の宣言列と top-level `<Staff>` の measures 列を **別配列で並列
読み**している。後段が「順序が一致している」ことを暗黙に頼っている。

新方式：mscx の `<Staff id="N">` が持つ ID を一次キーとして突き合わせる。

```swift
// 1) <Part> ごとに <Staff> 宣言を読み、各宣言の id 属性を保持
//    Part 内 <Staff id="3"> → ("3", staffType, group, defaultClef)
struct DeclaredStaff {
    let mscxID: String
    let staffType: String
    let group: String
    let defaultClef: String?
}
struct DecodedPart {
    let id: String
    let trackName: String?
    let instrument: Instrument
    let declared: [DeclaredStaff]
}

// 2) top-level <Staff id="N"> を id でインデックス化
let measuresByID: [String: [Measure]] = ... // id → measures

// 3) DecodedPart × DeclaredStaff を Staff に組み立て
for dp in decodedParts {
    let staves = try dp.declared.map { decl -> Staff in
        guard let measures = measuresByID[decl.mscxID] else {
            throw SheetMusicError.malformedScore(
                reason: "Part '\(dp.id)' declares <Staff id=\"\(decl.mscxID)\"> but no top-level <Staff> with that id was found"
            )
        }
        return Staff(staffType: decl.staffType, group: decl.group,
                     defaultClefType: decl.defaultClef, measures: measures)
    }
    parts.append(Part(..., staves: staves))
}
```

要点：

- mscx の `<Part><Staff id="3">` と top-level `<Staff id="3">` を **id で
  一意紐付け**。順序依存を排除。
- **id 欠落時のフォールバック**：MuseScore は単一 Part / 単一 Staff の
  ケース（例：`midi01.mscx`）で inside-Part `<Staff>` の `id` 属性を省略
  する。この場合は「文書順で次に未消費の top-level `<Staff>` に紐付け」
  の挙動を残す（=「id を持つ宣言は id マッチ → 残った無印宣言は出現順で
  残った top-level Staff を消費」のハイブリッド）。混在しない一般ケース
  では純粋な id マッチになる。
- 余った top-level `<Staff>`（どの Part も宣言・消費していない id）は
  `SheetMusicError.malformedScore` で fail-fast。permissive 方針の例外
  （暗黙のフォールバックは過去のバグの温床）。
- `MSCXDecoder+StaffContent.swift` は `MSCXDecoder+Staff.swift` に統合し、
  measures デコード関数は `[Measure].decode(staffNode:)` 等に切り出す。
- `titleFrame` の VBox 探索は「最初の Part の最初の Staff の measures より
  前」の節として書き換える。

`Sources/SheetMusicMusicXML/Decoders/MusicXMLDecoder+Part.swift` と
`Sources/SheetMusicMIDI/Import/MidiImporter+Assemble.swift` も同じく Part
内で Staff を直接構築するよう揃える（こちらは元々 Part 内で staff を作って
いたので素直）。

---

## §4. 既存サブライブラリの移行

ネスト化に伴う書き換え範囲。すべて単一ブランチで行う（互換 shim なし）。

| モジュール | 主な変更 |
|---|---|
| **SheetMusicCore** | `Score`/`Part`/`Staff`/`StaffAddress` 再定義、`NoteID`/`VoiceElementID`/`RestID` 等のアドレス置換、`Editing/*`（`ReplaceVoiceElements`、`DurationChangeAlgorithm`）の subscript 書き換え、`Score+ActiveKey`/`+NextChord`/`+NoteRange`/`+TieTarget` の staff 反復書き換え |
| **SheetMusicMSCX** | §3 の通り。`MSCXDecoder+Score`/`+Part`/`+StaffDeclaration` を再構成、`StaffDeclaration` を `Staff` に統合 |
| **SheetMusicMusicXML** | `MusicXMLDecoder+Part` で Staff 直接構築 |
| **SheetMusicMIDI** | `staffOwnership(...)` を削除し `score.parts.flatMap { p in p.staves.map { (p, $0) } }` ベースに。`assignChannels`/`MidiRenderer+Channels` は part 起点なので軽微。`MidiImporter+Assemble` は組み立て先を Staff に変更 |
| **SheetMusicLayout** | **本リファクタの主バグ修正**：`LayoutEngine+Contexts.swift:67`、`+Packing.swift:319-320, 362`、`+SystemBuild.swift:102, 401` を `score.allStaves` の `(address, staff)` イテレーションに置換。`address.partIndex` で part を、`staffIndexInPart` で同 part 内の Staff（=正しい defaultClef）を引く |
| **SheetMusicAudio** | `PlaybackEngine`、`PlaybackTimeline`、`MetronomeBeat`、`PlaybackEngine+Mixer` の `score.staves` ループを `score.allStaves` に置換。flat staff index が必要な内部 ID は `StaffAddress` に置換 or `enumerated()` の offset を使用 |
| **SheetMusicUI** | `PlaybackCursorView`、`SelectionRenderState` の `score.staves[idx]` を `score[address]` に置換 |
| **SheetMusicPDF** | importer は内部凍結中だが、出力先 `Score` の組み立てを Staff ネストに合わせて更新（`MidiImporter+Assemble` と同形） |
| **RenderPreviews / Examples** | `score.staves.map` 等を `score.allStaves.map` に置換 |
| **Tests** | `@testable` 経由で内部 API も追従。既存の `MidiExportTests`（12ケース）と `MidiImportRoundTripTests` は **既存 reference を変えずに緑のまま**通ることが受け入れ基準 |

---

## §5. テスト戦略と受け入れ基準

### 回帰防止（既存テストを変えずに緑にする）

- `swift test` 全 48 ケース緑（特に `MidiExportTests` 12 ケース、
  `MidiImportRoundTripTests`、`SheetMusicFacadeTests`、`SMFReaderTests`、
  `LayoutCacheTests`）
- `MidiExportTests.midiMeasureRepeats`（Piano = 1 Part / 2 Staff）が
  引き続き semantic-equivalent
- `swiftlint --quiet Sources Tests` で 0 警告

### 新規テスト（Core）

- `StaffAddressTests`：`Comparable` 順序、`Hashable` の同一性、
  `(0,0) < (0,1) < (1,0)` 等
- `Score+AllStavesTests`：`allStaves` が parts の宣言順 × 各 Part 内
  staves 順を保つこと
- `Score[address]` / `part(at:)` の境界値（範囲外で `nil`）

### 新規テスト（MSCX）

新規 fixture `multiPartMixedStaves.mscx`（Vln + Vln + Piano + Vc を再現
する小さな手書き mscx — 自作・MIT、GPL 由来でない）：

- `parts.count == 4`
- `parts[2].staves.count == 2`、`parts[2].staves[0].defaultClefType == "G"`、
  `parts[2].staves[1].defaultClefType == "F"`
- `allStaves.count == 5` で順序は
  `(0,0)(1,0)(2,0)(2,1)(3,0)`

不整合ケース：top-level `<Staff id="9">` を Part が宣言していない mscx →
`SheetMusicError.malformedScore` を throw。

### Layout バグ回帰テスト（ユーザ報告の主訴）

上記 fixture を `LayoutEngine` に通し、各 staff slot の resolve 結果を
検証：

- staff slot 4（= `(3,0)` = part4 / Vc）の part 名表示が "(名なし)" に
  ならないこと
- staff slot 3（= `(2,1)` = Piano 下段）の defaultClef が `"F"` で
  あること
- 既存バグを再現する assertion を一度 red で書いてから、リファクタで
  green になることを確認（TDD）

### フィクスチャ方針

- 既存の GPL fixture（`testMeasureRepeats.mscx` 等）は触らない。
- 新規 `multiPartMixedStaves.mscx` は自作・MIT、test-only に限定（既存の
  `Tests/SheetMusicTests/Resources/LICENSE` 配下の方針を踏襲）。

---

## 受け入れ基準まとめ

1. `swift test` で **既存 48 ケース + 本リファクタ追加分** がすべて緑
   （既存 GPL fixture の `*-ref.mid` は触らない）
2. 新規 `multiPartMixedStaves.mscx` で Layout バグの再現テストが green
3. `swiftlint --quiet Sources Tests` で 0 警告
4. `Score.staves`、`StaffContent`、`StaffDeclaration`、
   `MidiRenderer.staffOwnership(...)` の参照がコードベースから消えている
5. README の library 表は触らない（library 構成は変えない）
