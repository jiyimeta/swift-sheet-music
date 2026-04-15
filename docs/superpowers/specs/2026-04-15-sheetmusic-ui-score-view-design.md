# SheetMusicUI — SwiftUI 譜面ビューア (macOS 15+) design

Status: proposed
Date: 2026-04-15
Target libraries: `SheetMusicUI` (new)
Related: `CLAUDE.md` "Library layout" — `SheetMusicUI` は planned but not yet
implemented として列挙されている

## Motivation

`swift-sheet-music` は現在、`Score` 型データモデル、`.mscx` / `.mscz` パース、
MusicXML 取り込み、MIDI 書き出しを備える。しかし視覚的な描画は一切持たず、
Example アプリはステータス文字列と `ShareLink` のみを表示する。パース済みの
`Score` を「見せる」ライブラリが抜けている。

本スペックは、新規ライブラリ `SheetMusicUI` として **read-only の SwiftUI
譜面ビューア** を立ち上げることを目的とする。最初のリリース (v1) のスコープは
「現在 `SheetMusicCore` が公開している `Score` データ構造のうち視覚に現れる
要素を一通り描画できる」こと。音符入力・編集・選択などのリッチなインタラクショ
ンは対象外。ターゲットは **macOS 15+ のみ**。

v1 の採用判断基準は「`Tests/SheetMusicTests/Resources/v4/midi01.mscx` および
他の手元フィクスチャを開いて、MuseScore 4 の描画と比較して『同じ曲と認識でき、
記載された指示 (反復・スラー・強弱・テンポ・アルペジオ等) が全て何らかの形で
可視化されている』レベルで見える」こと。個々のグリフは engraved-grade の完成度
までは求めない。

## Non-goals

- 編集・選択・カーソル・音符入力などのリッチなインタラクション (read-only に
  徹する)
- **Core データモデルに未収録の記譜情報** (連符・跨譜連桁・装飾音・コードネーム・
  歌詞・運指・ペダル細部など): 今の `VoiceElement` / `Note` / `Measure` に入って
  いない要素は描画しようがないため対象外。Core に追加されたら本ライブラリも
  追従する
- 複数ページレイアウト、印刷、PDF 出力
- 再生カーソル / 音声同期ハイライト (将来の `SheetMusicPlayback` 範疇)
- iOS / iPadOS / tvOS / watchOS 対応 (v1 では macOS 15+ のみ。アーキテクチャは
  プラットフォーム非依存だが、availability の汚染を抑えるため対象外)
- MuseScore C++ engraving エンジンの移植 (独自のレイアウトパスを Swift で書く。
  MuseScore サブモジュールは特定アルゴリズムの照合に限り参照し、コードは
  コピーしない)
- テーマ / カラーカスタマイズ (`foregroundStyle` と `staffSize` 程度に絞る)
- アクセシビリティ (VoiceOver での音楽説明) — post-v1 で別途設計
- ピクセル完全なゴールデンイメージテスト (レイアウトエンジンが安定するまで保留)
- `SheetMusic` umbrella への再エクスポート (後述)
- engraved-grade の完成度 (グリフ衝突回避・最適 spacing・ハンドクラフト的な
  微調整): v1 は「指示が読み取れる」ことを最優先し、engraving 品質は段階的に
  上げていく課題として切り分ける

## Architecture

```
Sources/SheetMusicUI/                            (new target, macOS 15+ gated)
├── ScoreView.swift                              public entry — SwiftUI View
├── Options/
│   └── ScoreViewOptions.swift                   staffSize, systemGap, wrap
├── Layout/
│   ├── LayoutEngine.swift                       Score + Options → LayoutDocument
│   ├── LayoutDocument.swift                     [LayoutSystem] + メタ情報
│   ├── LayoutSystem.swift                       1 行 (1 system) = 複数 measure
│   ├── LayoutMeasure.swift                      配置済み measure
│   ├── LayoutElement.swift                      配置済みグリフの enum
│   ├── StaffMetrics.swift                       sp / lineDistance / 各種定数
│   └── PitchStaffPosition.swift                 MIDI pitch + clef → staff step
├── Rendering/
│   ├── ScoreCanvas.swift                        SwiftUI Canvas view
│   ├── SMuFLGlyph.swift                         Bravura Unicode codepoint 定数
│   ├── GraphicsContext+Glyph.swift              draw(Text) ラッパ
│   ├── StaffRenderer.swift                      五線 + ブレース/ブラケット
│   ├── PartLabelRenderer.swift                  system 先頭のパート名 + 楽器名
│   ├── ClefRenderer.swift
│   ├── KeySignatureRenderer.swift
│   ├── TimeSignatureRenderer.swift
│   ├── NoteheadRenderer.swift
│   ├── StemRenderer.swift
│   ├── BeamRenderer.swift
│   ├── RestRenderer.swift
│   ├── BarLineRenderer.swift                    通常 / 二重 / 終止 / 反復
│   ├── AccidentalRenderer.swift
│   ├── ArpeggioRenderer.swift                   波線・上向き/下向き矢印
│   ├── MeasureRepeatRenderer.swift              小節反復記号 (1/2/4)
│   ├── TieRenderer.swift                        Note.tieForward/tieBack の橋
│   ├── GlissandoRenderer.swift                  Note.glissando の直線/波線
│   ├── FermataRenderer.swift                    Fermata グリフ
│   ├── MarkerRenderer.swift                     Segno/Coda/Fine/ToCoda
│   ├── JumpRenderer.swift                       D.C./D.S./al Coda テキスト
│   ├── SpannerRenderer.swift                    Volta/Slur/HairPin/Pedal/
│   │                                            Ottava/TextLine 共通ディスパッチ
│   └── TextMarkRenderer.swift                   Dynamic / Tempo テキスト
└── Fonts/
    ├── BravuraFont.swift                        一度限りの CTFont 登録
    └── Resources/
        ├── Bravura.otf                          SIL OFL, bundle resource
        └── Bravura.LICENSE.txt                  OFL 全文
```

### Dependency graph

```
SheetMusicUI  ──→  SheetMusicCore
```

`SheetMusicUI` は `SheetMusicCore` (Score 型) のみに依存。MSCX / MIDI /
MusicXML には依存しない — `Score` があればどこから来たかに関わらず描画できる。

### Package.swift 追加

```swift
.library(name: "SheetMusicUI", targets: ["SheetMusicUI"]),
…
.target(
    name: "SheetMusicUI",
    dependencies: ["SheetMusicCore"],
    resources: [.copy("Fonts/Resources")]
),
```

**プラットフォーム方針** — `Package.swift` の `platforms:` 指定 (`.macOS(.v13)`
など) は変更しない。他の consumer (Core のみ / MIDI のみ / iOS 16+ など) を壊さ
ないため。`SheetMusicUI` の公開 API 全てに `@available(macOS 15.0, *)` を付け、
型単位で macOS 15 以上を要求する。これは Apple SDK の SwiftUI 新 API 全般と同じ
パターン。`#if os(macOS)` で iOS / tvOS / watchOS ビルド時にソース全体を除外し、
macOS 以外のプラットフォームでは target が空として扱われる (resources のみ配布
となるが害なし)。

**umbrella への含め方** — `SheetMusic` (umbrella) には v1 では **含めない**。
理由:

1. `import SheetMusic` は現状 iOS 16 / macOS 13 / tvOS 16 / watchOS 9 で使えて
   いる。ここに `SheetMusicUI` を組み込むと availability ゲートが umbrella 経由
   の全消費者に伝染し、非 UI 用途の consumer にとって不便になる
2. UI だけ欲しい consumer は `import SheetMusicUI` + `import SheetMusic` で
   両方取れる。逆に UI が要らない consumer は影響なし

文書化方針:

```swift
import SheetMusic    // Core + MSCX + MusicXML + MIDI (既存)
import SheetMusicUI  // ScoreView を足す (macOS 15+ 専用)
```

README の library table に `SheetMusicUI` 行を追加する (Status: v1 — macOS 15+,
read-only viewer)。

## Rendering technique: SMuFL font + Canvas

**SwiftUI `Canvas`** (macOS 12+) 上で、**Bravura** SMuFL フォント (SIL OFL、
同梱) のグリフを `GraphicsContext.draw(Text)` で描画する。五線・符幹・連桁・
小節線は `Path` ストローク、音符頭・音部記号・休符・臨時記号・拍子数字は
フォントグリフ。

**SMuFL + Canvas を選ぶ理由:**

- SMuFL (Standard Music Font Layout) は MuseScore / Verovio / Dorico 共通の
  業界標準。Bravura は SMuFL リファレンス実装で SIL OFL 配布のため再配布容易
- `Canvas` は macOS 15 で GPU-backed、SwiftUI 宣言的ホスト内に小さな命令型の
  描画面を作れる。`GeometryReader` より予測可能で、`UIGraphicsImageRenderer`
  のような UIKit 依存もなし

**却下した代替:**

- **純ベクタ (Path のみ、フォント無し)** — 音符頭・音部記号を一から Path で
  描く工数が大きく、engraved 相当には到底見えない
- **SF Symbols** — 楽譜記号セットは極小 (`music.note` 等のみ)。記譜には足りない
- **UIKit `UIGraphicsImageRenderer` / AppKit `NSBezierPath`** — SwiftUI host の
  中では `Canvas` が自然。ラスタライズ済みの画像を `Image` で差し込む案は、
  ズーム時にボケるので非採用

### Font 登録

Bravura.otf を resource として同梱し、初回アクセス時に process スコープで
一度だけ登録する:

```swift
enum BravuraFont {
    static let familyName = "Bravura"
    static let register: Void = {
        guard let url = Bundle.module.url(
            forResource: "Bravura", withExtension: "otf"
        ) else { return }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }()
}
```

`.process` スコープはホストアプリのセッション中のみ有効で、システムフォント
コレクションには触らない。`ScoreView.init` から `_ = BravuraFont.register`
を呼び、登録コストを最初の描画前に払う。

## Layout engine

純粋関数のパイプライン (値型のみ、back-pointer 無し、CLAUDE.md の方針どおり):

Input: `Score` + `ScoreViewOptions` + `availableWidth`
Output: `LayoutDocument` = `[LayoutSystem]`

パス:

1. **Flatten** — 各 `StaffContent.measures` を per-measure の voice ストリーム
   列に展開。既にモデルがこの形なので実質パススルー
2. **Anchor resolution** — `Spanner` は開始 measure に現れ、`nextMeasuresOffset`
   で終端 measure を指す。ここで (startMeasureIndex, endMeasureIndex) と
   開始側の tick を解決し、後段で描画単位に分割できる前処理済み表現を作る
3. **Minimum measure width** — 各 measure の最低幅を計算。clef / key sig /
   time sig は固定幅、音符/休符は `spacePerQuarter × ticks/division` + 臨時
   記号追加幅 + arpeggio の左側余白 + measureRepeat の中央配置幅
4. **System packing** — 各 system に measure を貪欲に詰め込む。次の measure が
   入らなければ改行。最終 measure の後で残った幅を比例配分で伸ばす (MuseScore
   と同様の even stretch)。`options.wrapToViewWidth == false` のときは改行せず
   横スクロール前提で 1 system に全 measure を載せる
5. **Vertical stacking** — 1 `Part` 内の複数 staff を固定 gap で縦に並べ、
   複数 `Part` は bracket + 大きめ gap で縦に並べる。各 system 先頭に
   `Part.trackName` と `Instrument` の名前ラベルを配置 (2 段目以降の system は
   省略名。MuseScore 慣例)
6. **Glyph placement (per-measure)** — 各 voice element について、tick
   オフセット・pitch・現在の clef / key 文脈から (x, y) を算出して
   `LayoutElement` を生成
7. **Spanner segmentation** — anchor 解決済みの Spanner を、system 改行箇所で
   複数セグメントに切る。セグメントごとに左端・右端を持ち、改行をまたいだ
   スラー等は両端に継続マーカーを付ける

`LayoutDocument` は Sendable な値型。`ScoreCanvas` は受け取った document を
その場で描画するだけで、レイアウト中間状態は持たない。

**`PitchStaffPosition`** — MIDI pitch + TPC + 現在 clef から「五線上の step
(整数、線の位置)」と「アクティブな implicit accidental」を返す純関数。ユニット
テスト容易。

**符幹方向** — chord の重心が中心線より下なら stem up、上なら down。v1 は
median heuristic に限定する。複数 voice の場合は voice1=up, voice2=down 固定
(MuseScore 既定に倣う)。

**連桁 (beaming)** — 同一 voice 内で隣接する 8 分音符以下が、当該 time
signature のビート境界をまたがないとき連桁で繋ぐ。8 分は 1 本、16 分は 2 本、
32 分は 3 本。付点・混合パターン (例: 8 分 + 16 分 + 16 分) では該当音符のみ
部分連桁 (secondary beam stub) を描く。ビート境界の算出は
`TimeSignature.numerator/denominator` から導出する単純ルール (4/4 → 4 分単位、
6/8 → 付点 4 分単位) — 複雑拍子 (7/8, 5/8 等) はビート = 分子全体で 1 グループ
扱いにフォールバック。Post-v1 で必要に応じて beam group 指定を Core に足す。

**Spanner 種別ごとのレイアウト:**

- **Volta** — 直前 measure の上に水平線 + 左下げ鉤 + "1." / "2." 等の数字
  (`voltaEndings` から)
- **Slur** — 始点 chord と終点 chord を通る 2 点ベジェ曲線。chord 重心に
  対して符幹と反対側に出す (stem up → 下側)
- **HairPin** — 開き/閉じを `rawType` から判別し五線下に線分 2 本で描画
- **Pedal** — 五線下に "Ped." テキスト + 右端に "*" テキスト (標準記譜)
- **Ottava** — 五線上下に "8va" / "8vb" 等 (`rawType` から) + 点線の水平線
- **TextLine** — 水平線 + 任意のテキストラベル (v1 では line のみ、text は
  空でよい)
- **other** — silently skipped (警告ログも出さない、permissive 方針)

**MeasureRepeat** — `Measure.measureRepeatCount` が `1` の measure 内の
`VoiceElement.measureRepeat` で示される反復記号を、その measure の中央に
描く。`2` 以上の continuation measure は本体 voice 内容を描かず、反復記号
と小節番号だけを表示する (MuseScore 相当)。

**Arpeggio** — `Chord.arpeggio != nil` のとき、その chord の先頭に波線
グリフ + `Arpeggio` サブタイプ (up/down/bracket 等) に応じた矢印を描く。

**Tie** — `Note.tieForward == .some(n)` の note と、時間順で次に同じ pitch で
`tieBack == .some(n)` を持つ note をペアリングし、その間に弧を描く。同一
measure 内はその場で、system 改行をまたぐ場合は Slur と同じ segmentation を
適用。`n` (tie number) はポリフォニックタイ区別用で、描画位置選定 (符幹方向
反対) のみに使い、`n` 自体は描かない。

**Glissando** — `Note.glissando != nil` のとき、その note から次の chord の
対応する note (同 index) に向けて `visualType` に応じた直線 (.straight) /
波線 (.wavy) を描く。`text` (例: "gliss.") が非空ならラインに沿ってテキストを
添える。style (chromatic / diatonic / …) は描画に影響しない (演奏系のみ)。

**Fermata** — `VoiceElement.fermata` はその voice の前後関係で直前の chord /
rest に被さる。`subtype` の prefix ("fermataAbove" / "fermataBelow") で上下を
決め、該当 SMuFL グリフを描く。未知 subtype は base fermata でフォールバック。

**Marker / Jump** — `Measure.markers` は measure 左上に描画 (Segno / Coda /
Fine / To Coda のいずれか)、`Measure.jumps` は measure 右下に `text` ラベル
("D.C. al Fine" 等) を描画。`kind` に対応する SMuFL グリフが存在する場合
(segno / coda) はグリフを、無い場合 (fine / toCoda) は `label` テキストを
描く。

## Public API

```swift
@available(macOS 15.0, *)
public struct ScoreView: View {
    public init(score: Score, options: ScoreViewOptions = .init())
    public var body: some View { … }
}

@available(macOS 15.0, *)
public struct ScoreViewOptions: Sendable, Equatable {
    /// 五線の高さ (point)。MuseScore の "Staff space" (sp) の 4 倍。
    /// default 28 pt ≈ rastral 3 相当。
    public var staffSize: CGFloat
    /// 隣り合う system (改行後の次段) との間隔 (point)。
    public var systemGap: CGFloat
    /// true: view の幅に measure を折り返す。
    /// false: 折り返さず 1 行として配置 (呼び側が ScrollView でくるむ想定)。
    public var wrapToViewWidth: Bool

    public init(
        staffSize: CGFloat = 28,
        systemGap: CGFloat = 40,
        wrapToViewWidth: Bool = true
    )
}
```

Option を 1 型・3 パラメータに絞る。`ScrollView` / サイズ決定は呼び側の責任。
`ScoreView` 自身は与えられた幅に従って縦に伸びる。

## v1 feature coverage

Core データモデルが公開している視覚要素を全て描画する。非視覚要素
(`Fraction`, `NoteDuration`, `InstrumentChannel`, `InstrumentArticulation`)
は演奏系配線用のため描画対象外。

| Model 要素                       | v1 描画                                   |
|----------------------------------|-------------------------------------------|
| `Clef` (G / F / C)               | ✅ concertClefType ベース                 |
| `KeySignature` (±7)              | ✅                                        |
| `TimeSignature`                  | ✅ 数字 + C / ¢                           |
| `Chord` / `Note`                 | ✅ head + stem + flag + 連桁              |
| `Rest` (全 NoteDuration)         | ✅                                        |
| `BarLine` (全 subtype)           | ✅ normal / double / final / start-repeat / end-repeat |
| `Accidental`                     | ✅ 明示 + 拍子由来の暗黙                  |
| `Note.tieForward` / `tieBack`    | ✅ tie 弧 (ポリフォニック番号も対応)      |
| `Note.glissando`                 | ✅ 直線 / 波線 + 任意の "gliss." ラベル   |
| `Arpeggio`                       | ✅ 波線 + 上/下矢印                       |
| `Fermata`                        | ✅ subtype に応じた上下 SMuFL グリフ      |
| `Measure.markers` (Segno/Coda等) | ✅ measure 左上にグリフ or ラベル         |
| `Measure.jumps` (D.C./D.S.等)    | ✅ measure 右下にテキスト                 |
| `Spanner.volta`                  | ✅ 水平線 + 鉤 + `voltaEndings` 数字      |
| `Spanner.slur`                   | ✅ ベジェ曲線                             |
| `Spanner.hairpin`                | ✅ 開き/閉じ (rawType 判別)               |
| `Spanner.pedal`                  | ✅ "Ped." + "*"                           |
| `Spanner.ottava`                 | ✅ "8va" / "8vb" + 点線                   |
| `Spanner.textLine`               | ✅ 水平線 (テキスト無しで可)              |
| `Spanner.other`                  | silently skipped (permissive)             |
| `MeasureRepeat`                  | ✅ 反復記号 (1/2/4 小節)                  |
| `Dynamic`                        | ✅ subtype テキストで五線下               |
| `Tempo`                          | ✅ "♩ = <BPM>" 五線上                     |
| `Measure.startRepeat/endRepeat`  | ✅ 反復小節線                             |
| `Part.trackName` + `Instrument`  | ✅ system 先頭のパートラベル              |
| `StaffDeclaration.group=pitched` | ✅ 通常五線                               |
| `StaffDeclaration.group=その他`  | 通常五線で描画 (percussion 専用線は post-v1) |
| 複数 staff / 1 part              | ✅ brace で括る                           |
| 複数 part                        | ✅ bracket で括り縦に並べる               |

v1 = `SheetMusicUI` 初回マージ版。`silently skipped` 項は layout パスで無視する
(警告なし、permissive 方針)。これは既存 MSCX decoder の方針と揃える。

Core に存在しない記譜情報 (連符、コードネーム、歌詞、運指、`Spanner.other`
など) は描画しようがないため v1 スコープ外。Core 側で追加された時点で本
ライブラリの追従タスクとして切り出す。

## Example app 更新

`Example/SheetMusicExample` を macOS ターゲット追加で multi-platform に拡張。

- `Example/project.yml` に macOS target を足す (既存 iOS target は温存)
- macOS target のみ `SheetMusicUI` に依存し、`ScoreView` を
  `NavigationSplitView` サイドバーに配置して `test.mscx` を表示
- iOS target は既存のまま (UI は iOS 版では使えないため)
- 共通 View は `SheetMusicExample/Shared/`, プラットフォーム別は
  `SheetMusicExample/macOS/`, `SheetMusicExample/iOS/` に分離

`Example/SheetMusicExample.xcodeproj` は既存どおり gitignored。project.yml
更新後に `cd Example && xcodegen` で再生成。

## Testing

Swift Testing (`import Testing`)。`@testable import SheetMusicUI`。
Package.swift の `SheetMusicTests` dependencies に `SheetMusicUI` を追加する。

### レイアウトエンジンテスト (純粋 Swift、UI 不要)

- `LayoutEngineTests` — 以下のフィクスチャを `LayoutEngine.layout` に渡し、
  出力 `LayoutDocument` の measure 数・system 数・要素の (x, y) を期待値と
  比較:
  - empty score (0 measure)
  - 1 staff × 1 measure × 全音符 1 つ (最小ケース)
  - G 譜 1 段で C major scale 1 オクターブ
  - 2 staff の piano (右手 treble / 左手 bass) 4/4
  - 3 part (SATB 的な) スタッキング
  - Volta 1 番・2 番括弧付きの反復
  - Slur / HairPin / Pedal / Ottava を 1 つずつ含む小譜
  - Arpeggio 付き chord
  - Tie で繋がった 2 note、system 改行またぎの tie
  - Glissando (straight / wavy) 付き 2 note
  - Fermata が載った chord と rest
  - Marker (Segno / Coda / Fine) + Jump (D.C. / D.S.) 組み合わせ
  - MeasureRepeat 1 小節反復、2 小節反復
- `PitchStaffPositionTests` — MIDI 48–84 を G / F / C clef に通したときの
  staff step 値をテーブル駆動で確認
- `StemDirectionTests` — chord median の境界 (B4 / C5 など) を網羅
- `BeamingTests` — 4/4 の 8 分連桁、16 分連桁、混合 (8 + 16 + 16) の部分連桁、
  ビート境界またぎでの連桁切断
- `SpannerSegmentationTests` — system 改行をまたぐ Slur / Volta が 2 セグメント
  に正しく切れること

### 描画 smoke テスト (SwiftUI ホスト)

- `ScoreViewRenderTests` — 上記フィクスチャを `ScoreView` でくるみ、macOS 15+
  の `ImageRenderer(content:)` で固定 DPI に焼いて、
  - クラッシュせず完了する
  - `cgImage` が non-nil で bounds が期待レンジ
  を確認。ピクセル比較はしない (golden image 保留 — Open questions 参照)
- UI 依存の Suite は `#if os(macOS)` ガード + Suite/Test 全体に
  `@available(macOS 15.0, *)` を付ける。非 macOS / 旧 macOS では suite ごと
  コンパイル対象外となり、CI で `swift test` 全プラットフォーム緑が維持される

### プレビュー

各 Renderer ファイルに `#Preview` を付ける。`ScoreView` にはテストリソース
(`Tests/SheetMusicTests/Resources/v4/midi01.mscx`) をロードするプレビューを
1 つ、ただし `#if DEBUG` と `Bundle.module` 経由にしない (テストバンドルはリリース
ビルドに含まれないため)。代わりに、プレビュー用の極小な `Score` リテラルを
`Previews/SamplePreviewScore.swift` に用意する。

### フォント登録テスト

- `BravuraFontTests` — `BravuraFont.register` 実行後に
  `CTFontCreateWithName("Bravura" as CFString, 12, nil)` で取れた CTFont の
  `CTFontCopyFamilyName` が "Bravura" であること

## Licensing / NOTICE

Bravura は SIL Open Font License v1.1 (Copyright © Steinberg Media
Technologies GmbH)。次を対応する:

1. `Sources/SheetMusicUI/Fonts/Resources/Bravura.LICENSE.txt` に OFL 1.1 全文
   と著作権表示を収める (フォント配布要件)
2. リポジトリ直下 `NOTICE` に `SheetMusicUI` セクションを追加し、Bravura
   フォント同梱の旨と OFL ライセンス参照を記す
3. README にも同様の一行を UI ライブラリ説明に添える

`Sources/` は引き続き MIT (`LICENSE` 直下) のままで矛盾しない — OFL は MIT
と互換で、フォントファイル単体に OFL が適用されるのみ。

## Commit / 実装段階 (writing-plans への申し送り)

プラン側で分割する指針。1 段階ごとに全テスト緑を維持:

1. **Package wiring + empty stub.** `Package.swift` に `SheetMusicUI` 追加。
   空の `ScoreView`、`BravuraFont` 登録と `BravuraFontTests`。`NOTICE` 更新、
   Bravura.otf と `Bravura.LICENSE.txt` を `Fonts/Resources/` に投入
   (バイナリ資産を含むため `.gitignore` に衝突が無いこと、および Swift PM が
   `resources:` 指定で正しくバンドルすることを確認)
2. **Layout primitives.** `StaffMetrics`, `PitchStaffPosition`, `LayoutElement`
   型定義。`PitchStaffPositionTests` / `StemDirectionTests`
3. **Single-measure single-staff layout.** clef + key sig + time sig + 音符 +
   休符 + 小節線 (反復含む) 1 段。`LayoutEngineTests` の最小 2 ケース
   (empty / 全音符)
4. **Multi-measure system packing.** 折り返し + 比例伸ばし。scale フィクスチャ
5. **Multi-staff / multi-part stacking.** brace / bracket / パートラベル。
   piano / SATB フィクスチャ
6. **Rendering pipeline (基本要素).** layout → `ScoreCanvas` → SMuFL グリフ。
   段階 5 までの要素 (五線/clef/key/time/notes/rests/barlines/accidentals) の
   描画。`ScoreViewRenderTests` の `ImageRenderer` smoke
7. **Beaming + 連桁アルゴリズム.** 8 分 / 16 分 / 32 分 / 部分連桁。
   `BeamingTests`。描画確認
8. **Dynamics / Tempo / Arpeggio / MeasureRepeat.** テキスト系 + 音型系
   マーク。フィクスチャ追加
9. **Spanner 全種 + Tie + Glissando.** Volta / Slur / HairPin / Pedal / Ottava /
   TextLine の anchor 解決・system segmentation・描画。同系統の Tie
   (`Note.tieForward/tieBack` ペアリング) と Glissando (同 index 次 note へ) も
   この段階で処理。`SpannerSegmentationTests` / `TiePairingTests` +
   視認確認
10. **Fermata / Marker / Jump.** `VoiceElement.fermata` と `Measure.markers` /
    `Measure.jumps` を描画。`FermataLayoutTests`
11. **Example macOS ターゲット.** project.yml 更新、macOS ContentView、
    xcodebuild 両プラットフォームで緑。README の library table 更新

段階 6 までで「基本的に読める」段階、7-10 で Core データを漏れなく可視化する
v1 完成状態、段階 11 で可視化と回帰チェックのための example 更新。

## Open questions

- **Staff size / rastral の default 値** — 28 pt (rastral 3 相当) は仮。段階 6
  で `midi01.mscx` の MuseScore 標準出力と並べて視覚的に較正する。default が
  変わっても公開 API 形には影響しない
- **`SheetMusic` umbrella への含め方** — 上記どおり v1 は含めない。v2 で iOS
  対応を入れるなら合流させる余地あり (iOS 18 で `Canvas` も十分安定)
- **アクセシビリティ** — v1 では未対応。`ScoreView` に `.accessibilityLabel`
  (曲全体の一言概要) と、各 measure の `accessibilityElement` で `"measure N"`
  程度は低コストで後から足せる。post-v1 として切り出す
- **Golden image tests** — スナップショットは v1 では導入しない。レイアウト
  パラメータ調整期にピクセルが動くたびテストを更新することになり、回帰検知
  価値がノイズに埋もれるため。段階 9 完了後、レイアウトが安定したら
  `swift-snapshot-testing` 等を検討
- **Spanner の描画品質** — スラーは始終点 chord の重心 + 符幹反対方向の
  固定オフセットで 2 点ベジェを張る簡易ルールで v1 着地する。engraved 品質の
  3 次ベジェ / 衝突回避は post-v1。本 spec では「Slur があることが明確に分かる
  曲線が描かれる」ことを成果とする
- **複雑拍子 (7/8, 5/8 等) の連桁グルーピング** — v1 は「分子全体で 1 グループ」
  にフォールバック。MuseScore では `<beatGroups>` 等で細かく指定できるが、この
  情報は現在 Core に無い。必要になった段階で Core に足す

## References

- SMuFL 仕様: https://www.smufl.org/ (グリフ codepoint の参照のみ)
- Bravura フォント: https://github.com/steinbergmedia/bravura (SIL OFL 1.1)
- `MuseScore/src/engraving/layout/` (サブモジュール、参照のみ。CLAUDE.md 準拠
  で `Sources/` には一切コピーしない)
- `docs/superpowers/specs/2026-04-15-musescore-3-mscx-support-design.md` —
  スペック記述スタイルのテンプレート
- Apple SwiftUI `Canvas` / `ImageRenderer` (macOS 15 API リファレンス)
