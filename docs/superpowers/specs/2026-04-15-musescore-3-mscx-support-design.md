# MuseScore 3 系 mscx 読み込み対応 — design

Status: proposed
Date: 2026-04-15
Target libraries: `SheetMusicCore`, `SheetMusicMSCX`
Related: `docs/superpowers/specs/2026-04-14-mscz-reading-writing-design.md`
(parallel work; see "MSCZ v3 integration" below)

## Motivation

現在 `SheetMusicMSCX.MSCXParser` は `<museScore>` ルートの `version`
属性を参照せず、MuseScore 4 系 (手元フィクスチャは `4.60`) の構造を
決め打ちで読んでいる。実地ユーザは MuseScore 3 系 (2018–2023) で作ら
れた資産を依然として多く保有しており、これが読めないのは利用開始の
ハードルになる。

MuseScore 本家 (`MuseScore/src/engraving/rw/rwregister.cpp`) は整数
化された MSC バージョンで reader を切り替える:

```
version <= 114 → read114
version <= 207 → read206
version < 400  → read302    # MuseScore 3 系全域
version < 410  → read400
version < 460  → read410
otherwise      → read460
```

本スペックは MuseScore 3 系 (MSC `300–399`) を現行の v4 パーサと同じ
`Score` に落とせるようにする。構造テストで v3 と v4 の成果物が一致する
ことを担保する。

## Non-goals

- MuseScore 1.x / 2.x の読み込み (`SheetMusicError.unsupportedVersion`
  で明示的に拒否)
- MIDI セマンティック等価テスト (v3 向けには `-ref.mid` を用意しない)
- Score → mscx XML 方向のエンコーダ (既存スコープ外)
- v3/v4 の差分を公開 API で区別可能にすること (`Score` は版中立、版情報
  は診断用に 1 フィールドだけ公開)
- `MSCXParser.parse(url:)` などの URL オーバーロード追加 (MSCZ スペック
  の責務)
- MuseScore 2.x 以前のフィクスチャを一つでもリポジトリに入れること

## Architecture

```
Sources/SheetMusicCore/
├── MSCXVersion.swift              (new)
├── Score.swift                    (+ museScoreVersion)
└── SheetMusicError.swift          (+ .unsupportedVersion)

Sources/SheetMusicMSCX/
├── MSCXParser.swift               (+ 版検出・ディスパッチ)
├── MSCXParseContext.swift         (new)
├── Decoders/
│   ├── MSCXDecoder+<Type>.swift   (decode(_:context:) に改修、
│   │                               v3 分岐は判明した箇所のみ)
│   └── V3/                        (当面作らない。大差分が出た decoder
│                                    のみ切り出す際に生やす)
└── XML/                           (変更なし)

Tests/SheetMusicTests/Resources/
├── v3/{LICENSE, <fixture>.mscx, <fixture>.mscz}
├── v4/{LICENSE, <既存 midi01 等を移動>}
└── LICENSE                        (両サブを覆う NOTICE / 既存を流用)
```

依存方向は既存通り (`SheetMusicMSCX → SheetMusicCore`)。`MSCXVersion`
は `Score` が保持する必要があるため `SheetMusicCore` 配下。

`V3/` ディレクトリは **先行して空で切らない** (YAGNI)。差分が大きいと
判明した最初の decoder を切り出すときに作る。

## Types

### `MSCXVersion`

```swift
public struct MSCXVersion: RawRepresentable, Sendable, Hashable, Comparable {
    public let rawValue: Int
    public init(rawValue: Int)
    public static func < (lhs: Self, rhs: Self) -> Bool

    /// "3.01" → 301、"4.60" → 460、"4" → 400。
    /// 受理する書式:
    ///   - "<major>"            (minor 省略 = 0)
    ///   - "<major>.<minor>"    (minor は 0 詰め 2 桁。MuseScore の出力形式)
    /// minor が 1 桁・3 桁以上などは曖昧なので nil (MuseScore 自身が
    /// 2 桁 zero-pad しか出力しないため実データでは現れない)。
    public static func parse(_ string: String) -> MSCXVersion?

    public var isV3: Bool { (300..<400).contains(rawValue) }
    public var isV4: Bool { (400..<500).contains(rawValue) }
}
```

`Int` 表現は MuseScore 本家と同じ `major*100 + minor` 方式。`"4.60"`
→ `460`、`"3.01"` → `301`、`"2.07"` → `207`。これで本家の
`if (version < 400)` などが Swift 側で自然に比較できる。

### `MSCXParseContext`

```swift
public struct MSCXParseContext: Sendable {
    public let version: MSCXVersion
    public init(version: MSCXVersion)
}
```

将来の拡張想定: `strict: Bool` (未知タグで throw するか)、`warnings:
DiagnosticCollector`、MSCZ 由来のフィクスチャ base URL など。これらは
本スペックでは追加しない。追加時はデフォルト付きイニシャライザで後方
互換を保つ。

### エラー

```swift
public enum SheetMusicError: Error, Sendable {
    case invalidXML(...)                      // 既存
    case malformedScore(reason: String)       // 既存
    case unsupportedVersion(rawValue: Int)    // NEW
    // MSCZ スペックで追加される他ケースと並列
}
```

`rawValue` は整数化 MSC バージョン。消費側で
`if case .unsupportedVersion(let v) = err, v < 300 { ... }` のように
将来対応予定範囲と既に諦めた範囲を区別できる。

### `Score` への追加

```swift
public struct Score: Sendable {
    public let museScoreVersion: MSCXVersion   // NEW
    public let division: Int
    public let parts: [Part]
    public let staves: [StaffContent]
    public let metaTags: [String: String]
}
```

## Parser entry point

```swift
public enum MSCXParser {
    public static func parse(_ data: Data) throws -> Score {
        let root = try XMLTreeParser.parse(data)
        guard root.name == "museScore" else {
            throw SheetMusicError.malformedScore(
                reason: "root is <\(root.name)>, expected <museScore>")
        }
        guard let verStr = root.attributes["version"] else {
            throw SheetMusicError.malformedScore(
                reason: "<museScore> missing version attribute")
        }
        guard let version = MSCXVersion.parse(verStr) else {
            throw SheetMusicError.malformedScore(
                reason: "unparseable museScore version '\(verStr)'")
        }
        guard version.isV3 || version.isV4 else {
            throw SheetMusicError.unsupportedVersion(rawValue: version.rawValue)
        }
        return try Score.decode(root, context: MSCXParseContext(version: version))
    }
}
```

## Decoder signature migration

20 ファイルある `MSCXDecoder+<Type>.swift` を全て

```swift
static func decode(_ node: XMLNode, context: MSCXParseContext) throws -> Self
```

に改修する。子 decoder 呼び出しも `context` を伝搬。この改修時点では
v3/v4 分岐は **1 箇所も入れない**。差分が顕在化するのは「v3 フィクスチャ
で parity テストが失敗する」時点であり、失敗した decoder に最小の分岐
(`if context.version.isV3 { … } else { … }`) を入れる。

差分が大きくなった decoder のみ `Decoders/V3/MSCXDecoder+<Type>.swift`
として切り出す (CLAUDE.md の 300 行ルール / 一責務一ファイル準拠)。
それまでは単一ファイル内の分岐で収める。

既存の permissive 方針 — `Voice.decode` が未知タグを黙って捨てる仕様
— は MuseScore 3 に特有な追加タグ (例: `<LayerTag>`, `<Synthesizer>`)
の自動吸収として既に機能する想定。parity テストでこれが成立すること
を最初に確認する。

## Known v3/v4 differences (調査メモ、実装前の仮説)

下記は parity テストを走らせる前の仮説。最終的な差分リストは実装中に
テストが教えてくれる。

- `<museScore version>` 直下の `<programVersion>` `<programRevision>`
  タグ (v3 のみ): `Score.decode` は `<Score>` 配下のみ見ているため影響
  なし
- `<Score>` 配下の `<LayerTag>` `<currentLayer>` `<Synthesizer>` (v3 のみ):
  `Score.decode` は `first("Score")` で Score ノードを取り、その配下の
  `Part` / `Staff` / `metaTag` / `Division` しか見ないので無視される
- `<Style>` サブツリーのタグ名差 (`<Spatium>` vs `<spatium>` 等): 現
  decoder は Style を読まない。影響なし
- `<Spanner>` の終端マーカー表現: v3 は `<next>/<prev>` を使う場面が
  v4 より多い可能性あり。parity テストで確認
- `<Instrument>` 配下の `<Channel>` / `<Articulation>`: チャンネル数
  / 構造が異なる可能性あり。parity テストで確認

## MSCZ v3 integration (並行作業との調整)

MSCZ 読込/書出スペック (`2026-04-14-mscz-reading-writing-design.md`、
プラン `2026-04-15-mscz-reading-writing.md`) は現在別ウィンドウで進行中。
本スペックとの関係:

- MSCZ リーダは `.mscz` を解凍し内部 `.mscx` バイトを
  `MSCXParser.parse(_:)` に渡すだけ。本スペックが入れば v3 `.mscz` も
  自動的に読めるようになる。**MSCZ リーダ側に版フィルタを追加しない**
- MSCZ writer はバイト列を受け取るだけの版中立 API。影響なし
- 本スペックはテスト時に `Tests/SheetMusicTests/Resources/v3/<fixture>.mscz`
  を 1 ケース以上投入し、MSCZ リーダ着地後に parity テストで `.mscz`
  経路も確認する
- マージ順は問わない設計 (本スペックと MSCZ プランは独立に着地可能)

## Testing

### フィクスチャ

- ユーザが手動で作成: 小さな譜面 (数小節、1〜2 パート、主要音程とテンポ)
  を MuseScore 3 と MuseScore 4 の両方で同じ内容として作り、それぞれ
  `.mscx` として保存 (MSCZ 経路確認用に `.mscz` も 1 ペア)
- 配置: `Tests/SheetMusicTests/Resources/v3/<name>.mscx` /
  `.../v4/<name>.mscx`
- LICENSE: 既存 `Resources/LICENSE` (GPL notice) を `Resources/` 直下に
  残し、`v3/` `v4/` 両サブディレクトリを覆う旨を本文に追記 (ファイル
  重複を避ける)
- 既存 `midi01.mscx` 等は `Resources/v4/` へ移動。`MidiExportTests` が
  参照するパスも同時に更新 (振る舞い変化なし)

### 新規テスト

1. **`MSCXVersionParityTests`** (新規ファイル):
   同名フィクスチャの v3 / v4 をそれぞれパースし、
   `expectStructurallyEqual(_:_:)` ヘルパーで等価性を確認。
   ヘルパーは `museScoreVersion` と `metaTags` を除いた全フィールドの
   再帰的等価を検査。配置: `Tests/SheetMusicTests/Helpers/`

2. **`MSCXUnsupportedVersionTests`** (新規):
   合成 XML (`<museScore version="2.07"><Score>...</Score></museScore>`)
   を `MSCXParser.parse` に食わせ、
   `SheetMusicError.unsupportedVersion(rawValue: 207)` が投げられること
   を確認。`"1.14"` (114) と "5.00" (500, 未来版) も同様に拒否される

3. **`MSCXVersionParsingTests`** (新規):
   `MSCXVersion.parse("3.01") == MSCXVersion(rawValue: 301)` 等の
   純粋テスト。無効入力 (`""`, `"abc"`, `"3."`, `"3"` の扱い)

### 既存テスト

- `MidiExportTests` 他: フィクスチャパスのみ `Resources/` →
  `Resources/v4/` に追従。挙動は変化しない
- 既存テスト緑が段階 3 完了時点の受け入れ基準

## Commit / 実装段階

実装プランを書く際の分割指針 (writing-plans への申し送り):

1. **types only**: `MSCXVersion`, `MSCXParseContext`, `.unsupportedVersion`
   を追加。`MSCXParser` / decoder は未改修。`MSCXVersionParsingTests` 追加。
   既存テスト緑
2. **fixture migration**: 既存フィクスチャを `Resources/v4/` へ移動。
   既存テストのパス指定を追従。LICENSE 整備。既存テスト緑
3. **dispatch + signature**: `MSCXParser` で版検出・ディスパッチ、
   decoder 全 20 ファイルを `decode(_:context:)` に改修 (v3 分岐はまだ
   入れない)、`Score.museScoreVersion` 公開、`MSCXUnsupportedVersionTests`
   追加。既存テスト緑
4. **v3 parity**: v3 フィクスチャ投入、`MSCXVersionParityTests` 追加、
   失敗する decoder に最小分岐を足して緑化。差分が大きい decoder のみ
   `Decoders/V3/` に切り出す
5. **MSCZ v3 ケース**: MSCZ プラン着地後、v3 `.mscz` parity テスト追加
   (この段階は MSCZ プランの完了に依存)

## Open questions

- MuseScore 3.x を手動作成するには旧版バイナリが必要。ユーザ側で確保
  できる前提で進めるが、フィクスチャ提供タイミングが実装を律する
- MS3 の `<Style>` が MS4 より冗長な場合、現 decoder は Style を読まな
  いので影響はない。将来 Style 対応を足す時点で改めて版差分が問題化
  する可能性

## References

- `MuseScore/src/engraving/rw/rwregister.cpp` — 版ディスパッチの源泉
- `MuseScore/src/engraving/rw/read302/` — v3 reader 本家実装
  (参照のみ、コピーしない。CLAUDE.md 準拠で `Sources/` は MIT 維持)
- `MuseScore/vtest/scores/musejazz-2.mscx` — v3.01 フィクスチャ例
