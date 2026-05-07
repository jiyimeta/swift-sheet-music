# Grace Notes (装飾音符) — Design

Date: 2026-05-07

## Summary

MuseScore の `.mscx` に書かれている装飾音符 (`<acciaccatura/>` /
`<appoggiatura/>` / `<grace4/>` / `<grace16/>` / `<grace32/>` /
`<grace8after/>` / `<grace16after/>` / `<grace32after/>`) を
パーサ → Core モデル → MIDI レンダラ → レイアウト/UI で扱えるよう
にする。現在は装飾音符の `<Chord>` が通常 Chord と全く同じに
decode され、その視覚拍ぶんの時間がボイスから消費されてしまうため、
表示・再生の双方で後続の音がずれる。

スコープは前装飾 5 種・後装飾 3 種すべて。MIDI 時間奪取は MuseScore
の `CompatMidiRender::renderGraceNotesBefore/After` のセマンティクス
を踏襲する。レイアウトは「縮小表示 + 主音の前後に水平配置 +
acciaccatura のスラッシュ」までとし、grace 同士の連桁・装飾→主音の
スラーは後続作業 (out of scope)。

## Motivation

`~/Desktop/idea8.mscx` 等の実スコアで `<acciaccatura/>` を含む小節が
ずれて再生・描画される。原因は decoder と renderer に grace 概念が
皆無で、装飾音符 `<Chord>` がフル拍を消費してしまうこと。

MuseScore の純正出力 MIDI と比較すれば、装飾音符のあとに続く全イベント
の onset が `acciaccatura.duration` ぶん遅れるため、`MidiExportTests`
の semantic-equivalence 比較を通せば確実に検知できる。

## Non-goals

- **連桁**: 16th/32nd 装飾音符同士の beam (MuseScore の
  `Chord::layoutGraceNotes`)。装飾音符が複数並ぶケースは個別に
  符尾・旗を立てて表示する。後続 PR で `BeamRenderer` と統合。
- **装飾→主音のスラー (slur)**: MuseScore は装飾音符の慣例的な
  スラーをデフォルトで描く。これも後続。
- **アーティキュレーション付きの装飾音符**: 装飾音符自身に
  `<Articulation>` が付くケース。
- **`<noStem/>` などの装飾音符スタイル細部**: スコープ外。
- **装飾音符の編集 API**: 本パッケージはレンダリング/再生用途。

## 装飾音符の種別と既定値

MuseScore の `NoteType` 列挙との対応 (`engraving/dom/note.h`):

| MSCX タグ | NoteType | 位置 | 既定演奏拍 (主音拍を 1 とする比) | 時間奪取元 |
|---|---|---|---|---|
| `acciaccatura` | ACCIACCATURA | 前 | 短い固定 (1/32 拍) | **直前 Chord 末尾** |
| `appoggiatura` | APPOGGIATURA | 前 | 主音拍 × 1/2 | 主 Chord 先頭 |
| `grace4` | GRACE4 | 前 | 1/4 拍 | 主 Chord 先頭 |
| `grace16` | GRACE16 | 前 | 1/16 拍 | 主 Chord 先頭 |
| `grace32` | GRACE32 | 前 | 1/32 拍 | 主 Chord 先頭 |
| `grace8after` | GRACE8_AFTER | 後 | 1/8 拍 | 主 Chord 末尾 |
| `grace16after` | GRACE16_AFTER | 後 | 1/16 拍 | 主 Chord 末尾 |
| `grace32after` | GRACE32_AFTER | 後 | 1/32 拍 | 主 Chord 末尾 |

「拍」は `division` (PPQ) を 1 拍 = 1/4 拍として換算した tick。

## Reference points (MuseScore C++)

- `engraving/dom/note.h` ─ `NoteType` 列挙
- `engraving/dom/chord.h` ─ `Chord::graceNotes()` / `_graceNotes`
- `engraving/dom/measure/measureread.cpp` ─ `<Chord>` 子要素の grace
  タグ判定 (NoteType 設定後、`graceNotes` 配列に追加して次の主 Chord
  に attach)
- `engraving/compat/midi/compatmidirender.cpp` ─
  `CompatMidiRender::renderGraceNotesBefore/After`
- `engraving/dom/chord.cpp` ─ `Chord::layoutGraceNotes` (本仕様の
  レイアウトは MuseScore の幾何ではなく、自前の左右オフセット計算
  にする — Non-goals の連桁と同じ理由で簡略化)

## Core モデル

`Sources/SheetMusicCore/Score/Chord.swift` を拡張:

```swift
public struct Chord: Sendable, Equatable {
    public var duration: NoteDuration
    public var notes: ChordNotes
    public var arpeggio: Arpeggio?
    public var lyrics: [Lyric]
    /// 主音より前に演奏される装飾音符。MSCX 上で
    /// この主 Chord の直前に並ぶ <Chord><acciaccatura/>...
    /// などを左から右の順に保持。
    public var graceNotesBefore: [GraceChord]
    /// 主音より後に演奏される装飾音符。
    public var graceNotesAfter: [GraceChord]
    // ...
}
```

新規型:

```swift
/// 装飾音符の種別。MuseScore の `NoteType` のうち装飾系のみ。
public enum GraceType: Sendable, Equatable {
    case acciaccatura
    case appoggiatura
    case grace4
    case grace16
    case grace32
    case grace8after
    case grace16after
    case grace32after

    /// 後装飾なら true。
    public var isAfter: Bool { ... }
}

/// 装飾音符。Chord と同じく音符束だが、ボイス上の累積拍に
/// 寄与せず、親 Chord に attach する形で保持される。
/// C++: 装飾用 NoteType を持つ `mu::engraving::Chord`。
public struct GraceChord: Sendable, Equatable {
    public var graceType: GraceType
    /// 視覚上の拍 (ステム旗の数など)。実際の演奏拍は
    /// `MidiRenderer` 側で graceType と主音拍から決定する。
    public var duration: NoteDuration
    public var notes: ChordNotes
}
```

設計上の鍵:

- 装飾音符は `VoiceElement` には現れない。`Voice.elements` は親
  Chord/Rest だけを保持する → Tuplet の `startIndex/endIndex` の
  意味論が変わらず既存ロジックが無傷。
- `Chord` のメンバを増やすため、`Chord.init` のデフォルト引数で
  `graceNotesBefore: [] = []` / `graceNotesAfter: [] = []` を
  追加し、既存呼び出し元の互換を保つ。
- `Equatable` は値型ぞろえなので合成で動く。

## MSCX デコーダ

`Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift` の
`<Chord>` 分岐を変更:

1. `Chord.decode(child)` の戻りが「装飾 Chord」かどうかを
   `graceTagAndType(child)` ヘルパで判定。子要素に上の 8 タグの
   いずれかがあれば `GraceType` を返す。なければ nil = 通常 Chord。
2. ヘルパのシグネチャ変更を最小化するため、`Chord.decode` の戻り型
   を変えるのではなく、`MSCXDecoder+Voice.swift` 内に
   `decodeChordOrGrace(_ node:) throws -> ChordOrGrace` を新設。
   `enum ChordOrGrace { case main(Chord); case grace(GraceChord) }`。
3. `decode(_:)` のループで保持する状態:
   - `pendingGracesBefore: [GraceChord]` ── before 系を見たら追加。
4. `case "Chord":` 内のフロー:
   - `decodeChordOrGrace` の結果が:
     - `.grace(g)` で g.graceType.isAfter == false → `pendingGracesBefore` に追加。`elements` には何も追加しない。`tupletStack` にも触れない (装飾音符は tuplet 拍に寄与しない)。
     - `.grace(g)` で g.graceType.isAfter == true → `elements` の最後尾を辿って直近の `case .chord(var c)` を見つけ、`c.graceNotesAfter` に追加して書き戻す。直近に Chord が無い (= 小節頭の after grace は不正だが MuseScore も書かない) 場合は無視。
     - `.main(var chord)`:
       - `chord.graceNotesBefore = pendingGracesBefore`
       - `pendingGracesBefore.removeAll()`
       - 既存ロジック: tuplet 倍率を `chord.duration` に適用 → `elements.append(.chord(chord))`
5. ループを抜けた後に `pendingGracesBefore` が残っていたら無視
   (MuseScore も小節末尾の宙ぶらりんな before-grace は再生しない)。
6. `Chord.decode(_:)` 自体は装飾音符でも問題なく動く (Lyrics/
   Arpeggio が装飾に付くことは Non-goals)。装飾音符でこれらを無視
   するかは「Lyric は装飾に付かない/Arpeggio も無視」のシンプル方針。

注意: tuplet 内に装飾音符が居るケース。MuseScore は装飾音符を
`actualNotes/normalNotes` の倍率で拍長換算しない。本仕様も
`pendingGracesBefore` に積むときに `tupletFractions` を**適用しない**。

## MIDI レンダラ

`Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` の
`case let .chord(chord):` を拡張:

```
let mainTick = localTick
let mainTicks = chord.duration.ticks(division: division)

// 1. before-grace の総奪取拍を計算 (主から/前から)
let stealFromMain  = totalStealFromMainHead(chord.graceNotesBefore, mainTicks, division)
let stealFromPrev  = totalStealFromPrev(chord.graceNotesBefore, division)

// 2. 直前の chord の最後の note-off を stealFromPrev ぶん前にずらす。
//    実装案: TimedMidiEvent ベースなので、events 末尾を逆走して
//    直近の noteOff (= 直前 Chord 由来) を見つけて tick を縮める。
//    複数 noteOff があれば全て同量縮める (和音末尾を揃える)。
//    縮められなかった量 (直前無し / 縮めると負になる) は捨てる
//    = MuseScore も「直前の余裕」が無ければ短くしない。

// 3. 各 graceBefore を順に発音
var graceTick = mainTick - stealFromPrev
for g in chord.graceNotesBefore {
    let dur = playbackTicks(for: g, mainTicks: mainTicks, division: division)
    let onset: Int
    switch g.graceType {
    case .acciaccatura:
        onset = graceTick     // 拍前から
        graceTick += dur
    default:
        onset = mainTick + (累積 stealFromMain 内のオフセット)
    }
    emit grace notes at onset, length = dur
}

// 4. 主 Chord の発音タイミング・拍長
let mainOnset = mainTick + stealFromMain
let mainPlayedTicks = mainTicks - stealFromMain - stealFromAfterTotal

// 5. after-grace
var afterTick = mainOnset + mainPlayedTicks
for g in chord.graceNotesAfter {
    let dur = playbackTicks(for: g, mainTicks: mainTicks, division: division)
    emit at afterTick, length = dur
    afterTick += dur
}

// 6. ボイス上の cursor 進行は通常通り。装飾音符の拍は主の中に納まる。
localTick += mainTicks
```

新ヘルパ (`MidiRenderer+Grace.swift` として独立):

```swift
extension MidiRenderer {
    static func playbackTicks(for g: GraceChord, mainTicks: Int, division: Int) -> Int
    static func totalStealFromMainHead(_ before: [GraceChord], _ mainTicks: Int, _ division: Int) -> Int
    static func totalStealFromPrev(_ before: [GraceChord], _ division: Int) -> Int
    static func totalStealFromMainTail(_ after: [GraceChord], _ mainTicks: Int, _ division: Int) -> Int
}
```

`playbackTicks` は GraceType.既定値 × `division/4` で算出
(acciaccatura は 1/32 拍 = `division/8`、appoggiatura は
`mainTicks/2`、grace4 は `division`、grace16 は `division/4`、
grace32 は `division/8`、grace8after は `division/2`、…)。

主音拍を超える grace 列が積まれたケース: MuseScore は非対称に
スケール縮小する (`CompatMidiRender::handleOverflowsForGrace`) が、
本仕様では「主 Chord の半分まで」を上限に按分縮小する簡略版で十分。
これは現実のスコアでまず起きないが、防御として実装しておく。

ベロシティ: 主音と同じ `velocity` を使う。MuseScore は装飾音符に
やや弱めの既定があるが、本パッケージは現状ベロシティの細かい
ニュアンスを再現していないので踏襲しない。

`Mirrors CompatMidiRender::renderGraceNotesBefore` などの参照
コメントを各ヘルパに付ける (CLAUDE.md の規約)。

## レイアウト/UI

### LayoutElement / LayoutEngine

`Sources/SheetMusicLayout/Layout/LayoutElement.swift` は enum で、
chord は `case chord(notes:duration:stem:stemOrigin:hasArpeggio:
arpeggioRawType:isBeamed:voiceIndex:)` という associated values
直書きの形。装飾音符は親 Chord に「載っている」のではなく、
**enum に独立した case として追加し主 Chord の隣に並べる**形にする
(他の小型要素 — accidental など — も独立 case で扱われている)。

```swift
case graceChord(
    notes: [LayoutChordNote],
    duration: NoteDuration,
    stem: StemDirection,
    stemOrigin: CGPoint,
    /// 主音 notehead 中心 X からの相対 X。before は負、after は正。
    /// 同じ親 Chord に複数の grace がある場合は左から右の順で並ぶ。
    relativeX: CGFloat,
    /// 親 Chord に属する複数 grace のグループ識別子。
    /// 同じ親 Chord 配下の before / after を 1 グループにまとめる。
    parentChordKey: ChordOriginKey,
    /// acciaccatura のみ true。renderer が SMuFL slash glyph を
    /// 重ねる判定に使う。
    hasSlash: Bool,
    /// 描画スケール。主音の `graceNoteMag` (既定 0.6) 倍。
    mag: CGFloat,
    voiceIndex: Int
)
```

`ChordOriginKey` は既存 `LayoutDocument+ChordOrigin.swift` の
スキームに合わせる (測度 index + voice index + element index 等)。
詳細は実装時に既存型と擦り合わせる。

幾何:

- スケール: 主音の 0.6 倍 (MuseScore の `smallNoteMag` 既定)。
  `LayoutOptions` (もしくは `ScoreStyle`) に `graceNoteMag` を追加し
  既定 0.6。
- 水平配置: 主音 notehead の左端から左方向に
  `graceWidth × N` で並べる (after は右端から右方向)。
  `graceWidth` は装飾 notehead 1 つ分 + 旗ぶん、約 1 spatium。
- 垂直配置: 主音と同じ五線基準で、装飾自身の pitch から staff
  position を決める (既存 `PitchStaffPosition` に scale 引数を
  追加するか、装飾用の小さなコピーパスを作る)。
- 装飾音符は `EventColumn` の幅計算 (`LayoutEngine+Extents.swift`)
  に **before の合計幅を主音の左 padding として足し込み**、measure
  pack 時に隣接 chord と衝突しないようにする。これをやらないと
  装飾音符が前の Chord に被って描画される。

### 描画

`Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift` の
`LayoutElement` switch に `.graceChord` 分岐を追加。

- `NoteheadRenderer` / `StemRenderer` / `DotRenderer` /
  `AccidentalRenderer` を `mag` 倍スケールで呼ぶ薄いラッパ
  `GraceChordRenderer.swift` を新設 (UI モジュール)。
  既存 `ScoreLayerBuilder+Chord.swift` のロジックを部分的に再利用
  するため、共通計算は `+Helpers.swift` に括り出す。
- acciaccatura は `StemRenderer` が描いた stem の上に
  SMuFL `graceNoteSlashStemUp` (U+E564) /
  `graceNoteSlashStemDown` (U+E565) を重ねる。判定は
  `LayoutElement.graceChord` の `hasSlash` 関連値。
- 旗は既存の旗描画を流用 (装飾音符の duration から旗数決定)。
- 連桁は出さない (Non-goals)。

## テスト

### Test fixtures

1. **(P) `Tests/SheetMusicTests/Resources/grace-notes.mscx`**:
   後日ユーザに依頼して MuseScore で作成 ── 全 8 種の装飾音符が
   1〜2 小節に並び、対応する `grace-notes-ref.mid` も含む。
   実装中は (R) で代替し、(P) は実装完了後に追加して
   `MidiExportTests` の対象に組み込む。
2. **(R) ユニットテスト用ハンドメイド `.mscx` 文字列** ── 設計時点で
   実装可能。各種別を独立に検証する。

### テストファイル構成

新規テスト:

- `Tests/SheetMusicTests/GraceNoteParserTests.swift` ── 各 grace タグ
  が `Chord.graceNotesBefore` / `…After` に正しく載るか。
  - acciaccatura 単独
  - 複数 grace の順序
  - tuplet 内 grace
  - after-grace
  - 宙ぶらりん (主音なし) の grace は無視
- `Tests/SheetMusicTests/GraceNoteMidiTests.swift` ── Score を
  ハンドメイドで組み立てて MIDI レンダリング結果のイベント tick を
  直接 assert。
  - acciaccatura: 直前 Chord の noteOff が縮む / 装飾音符 noteOn が
    主音より前
  - appoggiatura: 主音 onset が後ろにずれる / 装飾音符 noteOn が
    主音 tick と同じ
  - grace8after: 主音 noteOff が早まり、装飾音符が後続
  - 直前 Chord が無いケースで acciaccatura は steal-from-prev を
    諦める
- `Tests/SheetMusicTests/GraceNoteLayoutTests.swift` ── レイアウト
  が grace ぶん主音 X を右にずらすか、acciaccatura に slash flag が
  立つか。
- 既存 `MidiExportTests` に `grace-notes` ケースを (P) 受領後追加。

## ファイル変更計画

新規:

- `Sources/SheetMusicCore/Score/GraceChord.swift`
- `Sources/SheetMusicCore/Score/GraceType.swift`
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift`
- `Sources/SheetMusicUI/Rendering/GraceChordRenderer.swift`
- `Tests/SheetMusicTests/GraceNoteParserTests.swift`
- `Tests/SheetMusicTests/GraceNoteMidiTests.swift`
- `Tests/SheetMusicTests/GraceNoteLayoutTests.swift`

変更:

- `Sources/SheetMusicCore/Score/Chord.swift` ── `graceNotesBefore` /
  `graceNotesAfter` 追加
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift` ──
  `pendingGracesBefore` 状態 + before/after 振り分け
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` ──
  `case let .chord(chord)` の onset/拍長計算を grace 込みに
- `Sources/SheetMusicLayout/Layout/LayoutElement.swift` ──
  `case graceChord(...)` を `LayoutElement` enum に追加
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Extents.swift` ──
  grace 幅を主音 X の左右 padding に
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Emit.swift` ──
  Score → Layout 変換時に grace を載せる
- `Sources/SheetMusicLayout/Options/LayoutOptions.swift` (or
  `ScoreStyle.swift`) ── `graceNoteMag = 0.6` 追加
- `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift` ──
  `.graceChord` 分岐追加 + `GraceChordRenderer` 呼び出し
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Beaming.swift` ──
  装飾音符を beam 候補から除外 (連桁は Non-goals)
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Glissando.swift` /
  `+Arpeggio.swift` ── 装飾音符は対象外であることを確認
  (現状の `chord.notes` ベースの判定で問題ない見込み、テストで担保)

## 実装順序 (writing-plans 用ヒント)

1. Core モデル (`GraceType`, `GraceChord`, `Chord` 拡張) + Equatable
   テスト
2. MSCX デコーダ (`MSCXDecoder+Voice.swift`) + `GraceNoteParserTests`
3. MIDI レンダラ (`MidiRenderer+Grace.swift` ヘルパ → Voice 統合) +
   `GraceNoteMidiTests`
4. レイアウト (`LayoutElement.graceChord` + Extents/Emit) + 描画
   (`GraceChordRenderer`) + `GraceNoteLayoutTests`
5. ユーザから `grace-notes.mscx` 受領 → `MidiExportTests` に追加 →
   `idea8.mscx` で目視確認 (Mac サンプルアプリ)

各段階で `swift build` / `swift test` / `swiftlint --quiet` が緑に
なることを区切りとする。
