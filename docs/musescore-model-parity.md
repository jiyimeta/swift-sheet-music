# MuseScore model parity洗い出し

MuseScoreがmodelとして持っていてswift-sheet-music（以下ssm）が持っていないものを、
MuseScoreの`ElementType` enumを背骨にして全件洗い出した記録。完全parityを目標に置いた
ときの残工事一覧であり、実装計画ではない。

- 調査日: 2026-09-03
- MuseScore側: `/Users/user/Developer/Personal/musescore`（後述のとおり未リリースの**MuseScore Studio 5.0 dev / MSC 5.00**。出荷版は4.7.x）
- ssm側: `main` @ `f03ffd98`
- 手法: `src/engraving/types/types.h:68`の`enum class ElementType`（147 entries）を5 sliceに分割し、
  Codex agentで並列に突合。MISSING判定は全件を独立にgrepで再確認した。

---

## 1. 結論

**出荷済みMuseScoreに対する穴が2層、未リリースのMuseScore 5に対する断層が1つ。**

1. **要素そのものが存在しない（MISSING）: 25件**（調査時点。`ORNAMENT`と`FINGERING`を
   model化したので2026-09-04時点では23件——§4.6・§4.2） — fret diagram、figured bass、capo、
   string tunings、harp pedal diagram、fingering、sticking、expression、symbol、image、
   HBox / TBox / FBox、spacer、staff type change、linked parts（excerpt）など。
   MSCX decoderは未知elementを黙って捨てる（`MSCXDecoder+Voice.swift:329`）ので、
   これらはread→writeで**fileから削除される**。詳細は §4。

   **この件数は目安として読むこと。** §4の表を数えると36行あり、この見出しの数と合わない
   （`ElementType` enumに無い`StringData` / `StaffTypeList` / `SynthesizerState` /
   `NoteEvent` / `Excerpt`などを含み、`FIGURED_BASS`+`FIGURED_BASS_ITEM`のように
   1行に複数まとめた箇所もある）。残工事を見るときは件数ではなく表を見ること。
   なお`DEAD_SLAPPED`は**MSCXに読み書きが存在しない**ため、round-trip lossという意味では
   最初からこの層に属していない（§4.6の訂正）。

2. **型はあるが情報が落ちる（PARTIAL）** — こちらのほうが件数も影響も大きい。特に
   横断的な4つのギャップ（text markup / element base property / style / 時間軸map）が、
   個別要素のPARTIAL判定の大半の原因になっている。詳細は §5・§7。

1と2はMuseScore 4.6 / 4.7に対して**今日すでに実害がある**。parity作業の本体はここ。

3. **MSC 5.00のformat断層（未リリース・今は着手しない）** — 手元のMuseScore checkoutは
   未リリースのMSC 5.00で、spannerを`<Score>`直下の`<SpannerMap>`へ移し、endpointを
   EID参照に変えた。ssmはこのnodeを見ず、version検出も`major >= 4`をすべて`.v4`に丸めるため、
   将来MuseScore 5のfileを読むとspanner全種が無警告で消える。ただし5.0はtagもbranchも無く、
   formatは現在も動いており、prerelease tagも当てにならない（§3.4・§3.5・§3.7）。**いま入れるべきは実装ではなくversion guardの数行だけ**。
   詳細は §3。

数字で言うと、MuseScoreの`Sid`（style id）は2050個に対しssmの`ScoreStyle`は10 property、
`TextStyleType`は76対21、element base propertyは376 `Pid`に対し`ElementProperties`は
`visible`と`color`の2つ。

---

## 2. 前提

### 2.1 比較対象のversionがずれている

これは結果の読み方を変える前提なので先に書く。

| | version | 根拠 |
|---|---|---|
| 手元のMuseScore checkout | **MuseScore Studio 5.0 dev / MSC 5.00（未リリース）** | `version.cmake:24`が`MUSE_APP_VERSION_MAJOR "5"`、`MUSE_APP_UNSTABLE ON`、`MUSE_APP_IS_PRERELEASE ON`。`types/constants.h:31`が`MSC_VERSION = 500` |
| MuseScoreの出荷版 | **4.7.x / MSC 4.70** | tagの最新は`v4.7.4`（2026-07-06）。`git show v4.7.4:…/constants.h`は`MSC_VERSION = 470` |
| ssmが読み書きする対象 | **MSC 4.60** | `MSCXEncoder+Score.swift:51`が`museScoreVersion = "4.60"`を出力。MSCX fixtureも`<museScore version="4.60">` |

ただし**MuseScore 5のfileは既にこのrepositoryに入っている**。
`Tests/SheetMusicTests/Resources/musicxml/*_ref.mscx`の7件はすべて
`<museScore version="5.00">`で`<eid>`を持つ。spannerを含まないため今日まで問題なく
読めていたが、MS5が「まだ関係ない将来の話」ではないことは意識しておく（§3.3）。

つまり本書のギャップは2種類が混ざっている。

- **既存ギャップ** — MuseScore 4.6 / 4.7時点で既に存在し、ssmが実装していないもの。大半はこれ。
- **前方ギャップ** — MSC 5.00で新規に入った、または移動したもの。`<SpannerMap>`、`SHARED_PART`、
  `STAVE_SHARING_LABEL`、`PLAY_COUNT_TEXT`、`TAPPING`系、page / system lock indicatorなど。
  MuseScore 5がstableになった時点で顕在化する。現時点では着手しない（§3.6）。

MuseScoreのreaderは`rw/read460/`と`rw/read500/`が別実装になっており、`"Spanner"` tagを
inlineで読むのは`read460`だけ、`SpannerMap`を読むのは`read500`だけ。この分離自体が
format変更の証拠になっている。

### 2.2 4.60を対象にしていることは、出荷版4.7に対して問題ない

`RWRegister::reader`（`rw/rwregister.cpp:52`）は**460以上500未満を`Read460`1つで読む**。
つまりMuseScore自身が4.60と4.70を同じreaderで扱っており、ssmが`version="4.60"`を宣言して
書いたfileは4.7でも正しく読まれる。

4.60→4.70の差分も`read460`内の`mscVersion() < 470`分岐10箇所に限られ、中身は
TextLineBase系spanner（hairpin / ottava / pedal / palm mute / vibrato / rasgueado /
chord text line / bend）のtext位置をalignから独立させた変換、`Dynamic`の`dynamicsSize`から
musical-symbols-scaleへの改名、pedalの`STAR_SYMBOL`終端をrosette hookに寄せる処理
（`read460/tread.cpp:793, 2835, 2938, 3122, 3470, 3527, 3647, 4283, 4484, 4624`）。
いずれもssmが元々modelしていないtext line属性の領域なので、**4.60→4.70の対応作業は不要**。

### 2.3 判定区分

| 区分 | 意味 |
|---|---|
| `MISSING` | model表現が一切ない。MSCX importで黙って捨てられ、writeで消える |
| `PARTIAL` | 型はあるが持てる情報が部分的。subtypeの一部だけ、raw stringだけ、など |
| `LAYOUT` | MuseScoreではelementだが、ssmは`SheetMusicLayout`で導出する設計。意図的な非parity |
| `EDITOR` | MuseScore appのruntime / editor構築物。immutable value modelに置き場所がない |

`ElementType` 147件のうち25件は`*_SEGMENT`（spannerのlayout断片）で、これは丸ごと`LAYOUT`。
`SELECTION` / `LASSO` / `SHADOW_NOTE` / `ACTION_ICON` / `ROOT_ITEM` / `DUMMY` /
`TIME_TICK_ANCHOR` / `BAGPIPE_EMBELLISHMENT`は`EDITOR`。ここは追いかける必要がない。

### 2.4 「MISSING = round-trip消失」が成り立つ理由

ssmのMSCX decoderは未知elementをそのまま無視し（`Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift:329`
「Unknown elements are silently ignored. Decoder is permissive on purpose」）、encoderは
modelが持っている情報だけを書く。生XMLのpassthrough保存は無い（`Sources/SheetMusicMSCX/`全体を
`passthrough` / `verbatim` / `rawXML`で検索して該当なし）。

したがってmodelに無いものは**開いて保存した時点でfileから消える**。`docs/development/mscx-idempotency.md`
の2-pass gateはpass 1とpass 2の一致を見るもので、元fileとの差分は見ないため、この消失は
既存testでは検出されない。

**［2026-09-04 追記］この節はもう成り立たない。** §8の優先順1（preserved markup）を実装した。
各decoderが消費した子tagを宣言し、残りを`PreservedXML`としてmodelが持ち帰り、encoderが書き戻す。
`<voice>`の子だけは`VoiceElement.preserved`としてstream中の位置ごと保持する。
検出手段も入った——`Tests/SheetMusicTests/MSCXPreservationGateTests.swift`が
**source fileとpass 1**を`parent/child`単位で比較する。設計は
`docs/superpowers/specs/2026-09-04-mscx-preserved-markup-design.md`、運用は
`docs/development/mscx-preserved-markup.md`。

したがって以降の§4・§5を読むときは、「MISSING = 消える」ではなく
**「MISSING = modelとして扱えないが、fileからは消えない」**と読み替えること。
消えるものは限定され、gateのallowlistに理由付きで列挙されている。

**［2026-09-06 訂正］直前に並べていた4件のうち2件はもう消えていない。**
`<Staff>` body直下のboxは§4.4の作業で解決済みで、allowlistに**entryが1つも無い**。
`<text>`のinline markupは§7.1で`"text/sym"`が外れ、残る`"text/b"` / `"text/font"` /
`"b/font"`は**Tempo markingの中にしか出現しない**（encoderが`<text>`を再生成するため）。
残っているのは`<eid>`（MS5 identity、bagに入る前に捨てる）と`<instrumentId>`
（Sound IDがattributeの`id`と畳まれている）。**このリストは§8のリストと同じ理由で腐る**ので、
読むときはallowlistを直接見ること。

**そしてこの判定区分が最初から当てはまらない領域がある。** §2.4は§4・§5の表を読むための
規則だが、**全節に適用できるわけではない**:

- **§7.3 style** —— 未modelの`<Style>`子はbagに入るので、`Sid` 2050対10は
  round-trip lossを一度も意味していない（§7.3.1）
- **§4.4の`SPACER`** —— 「model は無いが往復する」。§8から外した理由がこれ

どちらも「modelに無い」が「fileから消える」を含意しない例で、**その2つを同一視すると
残工事を過大に見積もる**。§4・§5の表を読むときの規則を、§7の横断節に持ち込まないこと。

---

## 3. MSC 5.00の`<SpannerMap>`断層

### 3.1 何が起きるか

MuseScore 5は`TWrite::writeScoreSpanners`（`src/engraving/rw/write/twrite.cpp:512`）で、
score中の非generated spannerを**すべて**`<Score>`直下の`<SpannerMap>`にまとめて書く。
呼び出し元はclipboardではなく通常の保存path（`src/engraving/rw/write/writer.cpp:265`）。

ssm側:

- `MSCXDecoder+Score.swift:52-63`は`<Score>`の子として`Part`と`Staff`しか集めない。
  `Sources/SheetMusicMSCX/`に`SpannerMap`という文字列は存在しない。
- `detectVersion`（`MSCXDecoder+Score.swift:236-256`）は`majorInt == 3 ? .v3 : .v4`、
  つまり**major 5も`.v4`として扱う**。version警告も出ない。
- 拒否されるのはmajor ≤ 1のみ（`rejectPreMuseScore2`, 同`:221`）。

対象はscoreのspanner mapに入る全種で、`Score::addElement`（`dom/score.cpp:1106-1118`）を見ると
**slurも含まれる**（`SLUR`が`addSpanner`へfall throughする）。hairpin、ottava、volta、pedal、
trill、vibrato、let ring、palm mute、text line、gradual tempo change、glissando、guitar bendも同様。
tieだけはnote添付なので影響を受けない。

結果として、MuseScore 5で保存されたfileをssmで開くと、これらが**diagnosticすら出ずに全消失**する。
voltaが消えるのでrepeat展開も変わり、MIDI出力が静かに間違う。

### 3.2 endpointの表現も変わっている

これが対処の重さを決める。MSC 5.00の`TWrite::writeProperties(const Spanner*)`
（`twrite.cpp:1663-1697`）はanchorで分岐する。

- `Anchor::SEGMENT`（hairpin、volta等）→ `<track2>` / `<startTick>` / `<ticks>`
- それ以外（slur、glissando、guitar bend等のchord / note anchor）→
  `<startElement>` / `<endElement>`に**EID文字列**を書く

4.60の`<next>` / `<prev>`＋`<location>`（measure / fraction相対offset）という表現は無い。
ssmのspanner endpoint解決はこの`<location>` cursorを前提に組まれており
（`MSCXEncoder+TieLocation.swift`、`MSCXEncoder+LocationNoteIndex.swift`ほか）、
5.00では**そもそも使う情報が違う**。

さらにssmは`<eid>`を明示的に無視している。decoderのdoc commentいわく「No decoder in this package
models it anywhere, it carries no user data (4.6 mints a fresh one on every save)」
（`MSCXDecoder+Chord.swift:78-81`、`MSCXDecoder+GuitarBend.swift:57-60`）。
4.60ではそのとおりだが、**5.00ではEIDがspannerの接続情報そのもの**になっている。

### 3.3 いま入れるべきもの: version guardだけ

**実装済み** — `MSCXDecoder+Score.swift`の`guardPostMuseScore4`。挙動は2段階。

| 入力 | 挙動 |
|---|---|
| MSC >= 5 かつ `<Score><SpannerMap>`あり | `SheetMusicError.malformedScore`をthrow。`ScoreFault.code` = `mscx.version.tooNew` |
| MSC >= 5 で`<SpannerMap>`なし | 従来どおり`.v4`として読み、`ScoreDiagnostic`（`mscx.version.newerThanSupported`）を出す |
| MSC <= 4 | 変化なし |

**versionだけで弾かないのが要点。** MuseScoreはspannerが1つも無いscoreには
`<SpannerMap>`を書かない（`writeScoreSpanners`が早期return）ので、spanner無しの5.00 fileは
今の4.x向けreaderで正しく読める。version一発で弾く実装にしたところ、
`Tests/SheetMusicTests/Resources/musicxml/*_ref.mscx`の**7件すべてが落ちた** —
このMusicXML reference corpusは既にMuseScore 5.00出力（`<eid>`入り）で、しかも
spannerを含まないため今日まで正しく読めていた。読めるfileを弾くのは過剰なので、
**確実に読み違える構造がある場合だけ**refuseする形にした。

`malformedScore`を再利用しているのは、既に`.malformedScore` + `fault.code`で分岐している
hostがそのまま動くため。codeを`mscx.version.unsupported`（MuseScore 1）と分けているのは、
利用者への案内が違うから — MuseScore 1は「保存し直してください」（利用者が直せる）、
MuseScore 5は「このpackageが対応するまで待ってください」（こちらが直す）。

test: `Tests/SheetMusicTests/ScoreLoaderTests.swift`に4件
（SpannerMapありをrefuse / SpannerMap無しは読める / 無しでもwarnする / codeがMS1と別）。

**やらない（`5.x` release branchが切られるまで）** — `<SpannerMap>`とEID解決の実装。
理由は§3.4・§3.5、triggerの選び方は§3.7。着手するとしたら順序はこうなる。

1. element側でEIDを保持できるようにする（`ElementProperties`に足すか、decode中だけの索引にするか）。
   5.00 readerを書くならここが土台。
2. `<Score><SpannerMap>`を読み、EIDまたは`startTick`/`ticks`から`Spanner` modelへ解決する
   decoder pathを足す。payload（`<HairPin>`の`<subtype>`等）自体は4.60と同形なので再利用できる。
3. 書き戻しは4.60形のままでよい（ssmは`version="4.60"`を宣言しており、
   MuseScore 5も`read460`経由で読める）。

### 3.4 5.00のformatはまだ固まっていない

「未リリースだから急がない」に加えて、**今実装すると作り直しになる**根拠がある。

| 事実 | 日付 | 根拠 |
|---|---|---|
| file versionを5.0へbump | 2026-03-11 | `add5eb7f6b Bump file version number to 5.0` |
| `Read500` module新設 | 2026-04-29 | `71579f7189 New Read500 module` |
| **spanner全体を`<SpannerMap>`へ移し、endpointをEID参照化** | **2026-07-03** | `dbec66e167 Use EIDs to locate spanner ends`。writer側もread500側もこの1 commitで入った |
| EIDなしで書くconfig optionを削除 | 2026-08-11 | `Engraving: remove config option to write without EIDs` |
| spanner start tickの表現変更 | 2026-08-18 | `Allow writing (0, 1) for spanner's start tick` |
| `TempoMap`を`TempoTimeline`へ置換 | 2026-08-18 | `3d47252305`（08-12, "will replace ... later"）→ 08-18に実施 |
| checkoutのHEAD | 2026-09-02 | 現行master |

file versionを5.0に上げてから**4か月後**にspannerの置き場所と接続方法が変わり、その**さらに
6週間後**にもEIDとspanner tickの書き方が変わっている。ssmが実装することになる当の2つ
（EIDとspanner endpoint）が、先月まだ動いていた。

`rw/write` + `read500`のcommit数も増加傾向で、収束していない。

| 月 | 2026-03 | 04 | 05 | 06 | 07 | 08 |
|---|---|---|---|---|---|---|
| commit数 | 11 | 8 | 15 | 15 | 16 | **20** |

リリース時期についての記載は**MuseScoreのrepository内には無い**。`.github/`はCI・issue
templateのみ、`docs/`はAPI docsのみで、changelogもmilestoneも入っていない。判断材料になるのは
tagと`version.cmake`だけで、5.0のtagはalpha / beta / RCを含めて1つも無い（最新は`v4.7.4`）。

### 3.5 churnは収まる。ただしmajorのときだけ

`src/engraving/rw`配下の月次commit数を、同じpathで3サイクル並べる。

| cycle | 種別 | 月次commit（release月を**太字**） | release |
|---|---|---|---|
| 4.0 | **major** | 05:25 / 06:30 / 07:9 / 08:13 / 09:1 / 10:5 / 11:1 / **12:2** | 2022-12-13 |
| 4.6 | minor（`Read460`新設） | 03:14 / 04:19 / 05:22 / 06:23 / 07:18 / 08:34 / **09:22** | 2025-09-30 |
| 5.0 | **major**（進行中） | 03:26 / 04:13 / 05:20 / 06:21 / 07:23 / **08:26** | — |

**4.6は収束しなかった。** 新readerを作ったminorだが、リリース月も22件で、中身も整理ではなく
`Add symbol size to tempo text, staff text and system text`（09-15、新しい永続fieldの追加）、
`Ignore dots from slur-style barrés when writing diagrams`（09-19）と、**リリース11日前まで
永続形式が変わっている**。

**4.0は収束した。** 2022-06の30件から07に9件へ落ち、以降は1〜5件で推移してリリースを迎えた。
落ち始めた07は`v4.0_alpha_2`（2022-07-29）と重なる。前回のmajorでは、**alpha前後でrw層が
実質凍った**。

したがって「churnの収束」はmajorに限れば有効な指標であり、しかもtagやbranchより**先に**動く
先行指標になる。§3.7のtriggerにこれを含める理由。

**そして5.0には、その兆候が今のところ無い。** 2026-03から26 / 13 / 20 / 21 / 23 / 26で、
直近の2026-08がむしろ最大。4.0が示した「収束→alpha」の入口にまだ入っていない。

### 3.6 着手タイミング

**Phase 0 — 今すぐ（MS5と無関係に4.x parityで必要なもの）**

1. `detectVersion`のmajor >= 5 guard（§3.3）。数時間。
2. **未modelのXMLをopaqueに保持してwriteで戻す機構**（§8-1）。4.x parityの最優先項目だが、
   同時に**最良のMS5準備**でもある。これが入っていれば未知の`<SpannerMap>`はread→writeで
   生き残るので、MS5対応の有無に関わらず**MS5 fileがデータ欠損しなくなる**。
   MS5専用の作業をゼロにしたまま、被害を「消失」から「未解釈」へ落とせる。

Phase 0はformat churnの影響を受けない。5.0がどう変わっても無駄にならない。

**Phase 1 — `origin`に`5.x` release branchが切られた時点**

EID保持とSpannerMap decoderの実装（§3.3の1〜3）。payload decoder（`<HairPin>`の
`<subtype>`等）は4.60用が再利用できるので、新規に要るのはendpoint解決だけ。§3.7の実績
（lead 7〜14週間）なら間に合う規模。

alpha build（またはnightly）が出た時点でfixture corpusを作ること。それ以前にnightlyで
fixtureを作っても、上記のchurnで陳腐化する。

**Phase 2 — リリース直後**

4.6の実績どおりリリース11日前まで形式が動くので、Phase 1は一度で決まらない前提で組む。
リリース版のfileで突き合わせ、最初のpatch release（4.6では`v4.6.1`）まで追従する。

**なお、ssmの出力側は影響を受けない。** MuseScore 5も`rw/read460/`を同梱しており
（`rwregister.cpp:52`）、ssmが書く`version="4.60"`のfileはMuseScore 5でも読める。
影響するのは**MS5で保存されたfileを読む方向だけ**。

### 3.7 Phase 1のtriggerに何を使うか

結論を先に書くと、**`origin`の`5.x` release branchの出現**を見る。

```
git -C <musescore> fetch --tags
git -C <musescore> branch -r --list 'origin/5*'    # ← これがPhase 1のtrigger
git -C <musescore> tag --list 'v5*'                 # 参考。出ないこともある
```

**prerelease tagは信頼できない。** 4.x以降で見ると、`v4.0`（前回のmajor）はalpha / beta / rcが
揃い、`v4.1.0`はbeta / rc、`v4.2.0`はbeta / beta.2。しかし`v4.3.x`・`v4.5`・**最新の`v4.7.0`は
prerelease tagが1つも無い**（`v4.4`系は`v4.4.1-rc`のみで`v4.4.0`には無い）。命名も
`v4.0_beta` / `v4.1.0-beta` / `v4.6.0-beta`と揺れ、3.0世代はtagではなくbranch
（`origin/3.0beta1`）だった。直近6リリース線のうちprerelease tagがあるのは2つだけ。

**release branchは全リリース線に存在する。** `origin/4.3.1`から`origin/4.6.5`、`origin/4.7`まで
欠けが無い。しかもtagより早い。

| branch | mainからの分岐 | release | lead |
|---|---|---|---|
| `origin/4.6.0` | 2025-08-13 | 2025-09-30 | 7週間 |
| `origin/4.7` | 2026-02-05 | 2026-05-13 | 14週間 |

4.6ではbranch cut（08-13）が`v4.6.0-alpha` tag（08-18）より5日早い。命名は`4.6.0`（patchごと）
から`4.7`（線ごと）へ変わっているので、`5.0`か`5.0.0`か決め打ちせずglobで見る。

**churnの収束は先行指標として併用する。** §3.5のとおり、前回のmajorではrw層のcommitが
30 → 9 → 1〜5へ落ち、その入口が`v4.0_alpha_2`と重なった。branchやtagより先に動くので、
月次で見ておくと身構える時間が増える。

```
git -C <musescore> log --format=%ad --date=format:%Y-%m --since=<6か月前> \
  -- src/engraving/rw | sort | uniq -c
```

20件超が続いているうちは遠い。1桁に落ちたらalpha / branchが近い。

**使えないと確認したもの**

- `version.cmake` — `v4.6.0-alpha`時点も`v4.6.0`リリースtag時点も
  `MUSE_APP_UNSTABLE ON` / `MUSE_APP_IS_PRERELEASE ON` / `MUSE_APP_VERSION_LABEL ""`で、
  今日のmasterと同一。リリース直前かどうかを区別できない。

**これも過去の運用からの推測であって保証ではない。** branchの根拠がtagより強いというだけ。
だからこそPhase 0を先に済ませておく意味がある。Phase 0が入っていればtriggerを外しても
失うのは「解釈」であって「データ」ではなく、triggerは"どれだけ早く解釈できるか"の
最適化に留まる。

遅い検知の保険として、`MSC_VERSION`が500を超える（5.0が出てdevが5.1へ移った）か
`rw/read510/`が現れたら、確実に出遅れているというalarmになる。

---

## 4. 表現が存在しない25件（MISSING）

全件、`Sources/SheetMusicCore`と`Sources/SheetMusicMSCX`をgrepして0 hitを確認済み。
（`Capo`は`Marker.daCapo`、`StringData`は「ここには来ない」という注釈の誤hitのみ）

### 4.1 ギター / TAB系

| MuseScore | 定義 | ssm | 影響 |
|---|---|---|---|
| `FRET_DIAGRAM` | `dom/fret.h:137` | なし | chord diagramが丸ごと消える。string / fret / dot / barre / marker / 埋め込みharmony |
| ~~`STRING_TUNINGS`~~ | `dom/stringtunings.h:49` | **`StringTunings`**（2026-09-06実装） | 下の追記を参照 |
| ~~`CAPO`~~ | `types/types.h:1368`（`CapoParams`） | **`Capo`**（2026-09-06実装） | 下の追記を参照 |
| ~~`StringData`（Instrument配下）~~ | `dom/stringdata.h:42` | **`StringData`**（2026-09-04実装） | 下の追記を参照 |
| `TAB_DURATION_SYMBOL` | `dom/tabdurationsymbol.h:40` | なし | TABのduration表示 |
| `TREMOLOBAR` | `dom/tremolobar.h:37` | なし | whammy barのpitch curve。ssmの`Tremolo`は別物（beam tremolo） |
| `GUITAR_BEND_TEXT` | `twrite.cpp:1609` | なし | bend labelのuser編集 |
| `HARP_DIAGRAM` | `dom/harppedaldiagram.h` | なし | harp pedal 7状態 |

TABをまともに扱うなら`StringData`が起点。これが無いと`FRET_DIAGRAM`も`STRING_TUNINGS`も
単体では意味を持ちにくい。

**［2026-09-04 追記］`StringData`はmodel化した。** `SheetMusicCore`の`StringData` /
`InstrumentString`と`Instrument.stringData`、decoder / encoderは`MSCXDecoder+StringData.swift` /
`MSCXEncoder+StringData.swift`、fixtureは`Tests/SheetMusicTests/Resources/own/string-data.mscx`。

形式は`<frets>`1つと`<string>`の列だけで、`<string>`のpitchはtext、`open` / `useFlat`は
attribute（readerは`read460/tread.cpp:4195`、writerは`write/twrite.cpp:3185`）。
MuseScore 2の綴りである`<Tablature>`もdecoderは受けるが、encoderは常に`<StringData>`を書く。
consumed setには両方を入れてある——preserved markupのlegacy綴りruleそのもの。

`<string>`は**位置が意味を持つ**。`Note.string`はこのlistへのindexなので、読めない
`<string>`は捨てずにpitch 0で枠を残す——1本落とすと以降の弦が全部繰り上がる。上流も同じで、
`tread.cpp:4203-4208`は`push_back`を無条件に行い、`readInt()`が0を返す。

意図的な乖離は3つある。`instrString::startFret`は上流でもserializeされず、
読み込み時に`configBanjo5thString()`が導出する値なので、fidelity modelには置き場所が無い。
`frets`はfileに書かれた値のまま保つ——上流のreaderは`isFiveStringBanjo()`が真になると
`frets`を24に上書きするが、ここでの仕事は読んだfileをそのまま返すことなので正規化しない。
fixtureにMuseScore自身の5弦banjo tuning（`share/instruments/instruments.xml`の
`<frets>19</frets>`＋67 / 50 / 55 / 59 / 62）を入れてあるのはそのためで、この判断はtestで固定されている。
`open` / `useFlat`はどちらもuserがstring propertiesで立てるflagなので、fixtureでは手で付けた。
3つ目は**空のtuningの扱い**。`TWrite`は`StringData::isNull()`（frets 0かつ弦0本、
`stringdata.cpp:74-77`）のとき`<StringData>`自体を書かないので、MuseScoreは`<StringData/>`を
読んで保存すると要素ごと消す。ssmは`StringData()`としてdecodeし、
`<StringData><frets>0</frets></StringData>`で書き戻す。MuseScoreは同じnull tuningとして
読み直すので実害は無く、逆に上流に合わせて省略すると preservation gate が
`Instrument/StringData`を本物のlossとして報告してしまう。要素が無い場合（`stringData == nil`）は
何も書かない。

`<Tablature>`の正規化は**preservation gate上はlossになる**。MuseScore自身のwriterが
`<StringData>`しか書かない（`twrite.cpp:3187`）ので正規化が正しいが、実在のMuseScore 2 scoreを
通すと`Instrument/Tablature`が`Instrument/StringData`に変わる。committed fixtureに
`<Tablature>`は1件も無いのでgateは緑で、opt-inのcorpus sweepで初めて出る。そのときの答えは
encoderを変えることではなく、この判断を書いた`allowedLosses` entryを足すこと。

出力位置は変わった。これまで`<StringData>`はpreserved markupとして`<Instrument>`の末尾
（`<Channel>`の後ろ）に出ていたが、model化でMuseScore自身のwriterと同じ位置——
`<Articulation>` / `<Channel>`の前——に移った。preservation gateは`parent/child`の
出現数だけを見るのでmoveはlossにならない。

**まだ「検証も再計算もできる」ようにはなっていない。** このsliceはtuningを保持するところまでで、
`Note.string` / `Note.fret`をtuningと突き合わせる処理は入っていない。それには
`StringData::convertPitch` / `getPitch`相当のport（5弦banjoの特例と`CapoParams`のpitch offsetを
含む）が要り、別sliceにした。`FRET_DIAGRAM` / `STRING_TUNINGS` / `CAPO`も未実装のままだが、
これらが乗る起点はこれで埋まった。

**［2026-09-06 追記］`CAPO`と`STRING_TUNINGS`もmodel化した。** `SheetMusicCore`の`Capo`と
`StringTunings`、`VoiceElement`の`.capo` / `.stringTunings`、decoder / encoderは
`MSCXDecoder+Capo.swift` / `MSCXEncoder+Capo.swift`（`StringTunings`も同名の対）、fixtureは
`Tests/SheetMusicTests/Resources/own/tab-annotations.mscx`。

**`SystemElement`ではなく`VoiceElement`に置いた。** どちらも`StaffTextBase`派生なので
`StaffText`（ssmではlift済み）に引きずられそうになるが、上流のflagは
`ElementFlag::MOVABLE | ElementFlag::ON_STAFF`だけで**system flagを持たない**
（`capo.cpp:37`、`stringtunings.cpp:47`）。`SystemElement`の存在理由は「staffを隠しても残る」
ことだが、guitar staffを隠したらそのcapoも一緒に消えるのが正しい。上流のflagとscopeの両方が
staff側を指している。

`<StringTunings>`は`<preset>`・`<visibleStrings>`（**カンマ区切りのint列**、
`typesconv.cpp:132`の`sl.join(u",")`）・省略可能な`<StringData>`。`<StringData>`は
上の`StringData`をそのまま再利用しており、**同じ型が`<Instrument>`配下とここの2箇所に出る**。
`<visibleStrings>`は空でも無条件に書かれるので、model側も常に出す。

`<Capo>`は`<active>` / `<fretPosition>` / `<generateText>`と、除外弦を表す
`<string no="N"><apply>0</apply></string>`の列。除外弦は上流が`std::unordered_set`で、
writerが`std::set`に移してから書くので昇順。modelも`Set<Int>`にして、encodeと
fingerprintの両方でsortする。

**`<transposeMode>`だけはMuseScore 4.7のpropertyで、4.60には存在しない。**
`v4.6.5`の`dom/property.h`にあるCAPO系Pidは`CAPO_FRET_POSITION` /
`CAPO_IGNORED_STRINGS` / `CAPO_GENERATE_TEXT`の3つだけで、`CAPO_TRANSPOSE_MODE`は無い
（`git log -S CAPO_TRANSPOSE_MODE`→`2ad8dd61a8`、`git tag --contains`の初出が`v4.7.0`）。
4.6のwriterは書かず、readerは`xml.unknown()`に落として捨てる。
だからmodelは`TransposeMode?`にして、**tagが無ければ書かない**——
`version="4.60"`を名乗るfileに4.7のtagを毎回混ぜないためで、
`ExpressionText.snapToDynamics`と同じ「nil = tagが無い」形。値は書かれるときは
**enumの序数（int）**（5.0-devの`property.cpp:489`が`P_TYPE::INT`）。

これは§4.6の`ChordBracket`が踏んだ罠と同じもので、**element単位ではなくproperty単位で
起きた**版。`rw/read460/`は4.60–4.99のreader moduleなので、そこに枝があることは
4.6にあることを意味しない。要素だけでなく**その要素のpropertyについても**
release tagで確認する必要がある。

`<Capo>` / `<StringTunings>`という要素自体の境界は**MuseScore 4.1**。
`rw/read400/tread.cpp`にはどちらのreaderも無く（"Capo"のhitは`FretDiagram`の
`setCapo(fretId)`という別物）、両方を持つ最初のreaderは`rw/read410/`。

#### 4.1.1 タグが無いときの意味は`propertyDefault`が決める

**この2件で一番危なかったのはここ。** `writeProperty`は「default値と異なるときだけ書く」
（`twrite.cpp:395-397`のコメントが契約を明記している）。その「default」は
`propertyDefault()`の戻り値であって、**C++のmember initializerではない**。`Capo`はこの2つが
食い違っている:

| property | `CapoParams`のfield initializer | `Capo::propertyDefault`（`capo.cpp:72`） |
|---|---|---|
| `active` | `false`（`types/types.h:1377`） | **`true`** |
| `fretPosition` | `0`（`types/types.h:1375`） | **`1`** |
| `generateText` | （structに無い。`capo.h:56`が`true`） | **`true`** |

つまり「**activeでfret 1のcapo**」——capoの最も普通の状態——が書かれたfileには
`<active>`も`<fretPosition>`も**存在しない**。ここでfield initializer側をdecodeのdefaultに
使うと、active な capo が inactive として読まれる。`CAPO`はplayback pitchに影響するので、
**診断も出さずに音が変わる**。

ssmは`propertyDefault`側（true / 1 / true）をdecodeのdefaultにしている。
encodeではこの3つを**default一致でも無条件に書く**——省略判定を再現すると同じ罠を
encoder側でも踏むし、readerはどちらでも読むので、書く方が安全でidempotentになる。

**tagが「無い」ときの挙動はtestで固定すること。** ここは一度落とし穴になった:
最初のtestは`<fretPosition>2</fretPosition>`を明示していて`isActive`しか見ていなかったので、
decoderの`?? 1`を`?? 0`に書き換えても全gateが緑のままだった。**この節が主張している当のものが
testで守られていなかった。** いまは子要素ゼロの`<Capo/>`をdecodeして全defaultを突き合わせ、
decode→encode→decodeのidempotencyまで見ている。

**absentとunparseableも区別する。** `<fretPosition>abc</fretPosition>`は上流の
`readInt()`が0を返し、`capo.cpp:150`が0を「capo無し」として扱う。tagが無いとき（=1）と
同じにしてはいけない。

**scalar propertyをmodel化するときは毎回この検算をすること。** `writeProperty`を通る
property全部に当てはまる。model側が`Bool?` / `Int?`で「タグが無い」を表現できるなら
（`ExpressionText.snapToDynamics`がそう）この問題は起きないが、非optionalで持つなら
`propertyDefault`を読みに行くしかない。

### 4.2 text annotation系

| MuseScore | 定義 | ssm | 影響 |
|---|---|---|---|
| ~~`EXPRESSION`~~ | `twrite.cpp:1343` | **`ExpressionText`**（2026-09-04実装） | 下の追記を参照 |
| ~~`FINGERING`~~ | `types/types.h:121` | **`Fingering`**（2026-09-04実装） | 下の追記を参照 |
| ~~`STICKING`~~ | `dom/sticking.h:34` | **`Sticking`**（2026-09-04実装） | 下の追記を参照 |
| ~~`FIGURED_BASS`＋`FIGURED_BASS_ITEM`~~ | `dom/figuredbass.h:91` | **`FiguredBass` / `FiguredBassItem`**（2026-09-06実装） | 下の追記を参照 |
| `PLAYTECH_ANNOTATION` | `dom/playtechannotation.h:35` | なし | 奏法指定（pizz.等）とplayback反映 |
| `SOUND_FLAG` | `twrite.cpp:3273` | なし | StaffTextの子。preset・奏法・全staff適用 |
| `PLAY_COUNT_TEXT` | `twrite.cpp:2743`（MSC 5.00） | なし | 反復回数表示 |
| `STAVE_SHARING_LABEL` | `dom/stavesharinglabel.h:27`（MSC 5.00） | なし | staff共有label |
| `TRIPLET_FEEL` | `dom/tripletfeel.h:28` | なし | ssmの`Swing`とは別概念。typed feel + 生成text |

**［2026-09-04 追記］`FINGERING`はmodel化した。** `SheetMusicCore`の`Fingering`と
`Note.fingerings`、decoder / encoderは`MSCXDecoder+Fingering.swift` /
`MSCXEncoder+Fingering.swift`、fixtureは`Tests/SheetMusicTests/Resources/own/fingerings.mscx`。
noteに複数付く（左手運指と弦番号の同居は普通のguitar記譜）ので配列。

判断が要ったのは`<style>`の扱い。上流ではこれは**text style**
（`fingering` / `guitar_fingering_lh` / `guitar_fingering_rh` / `string_number`）だが、
この要素に限っては「2」が指なのか手なのか弦なのかを決めるのがstyleなので、
ssmの`TextStyleType`に足すのではなく`Fingering.Role`として要素のroleにした。
`TextStyleType`の行はfontとplacementのdefaultを抱えており、そこは§7.3のstyle作業の領分。
familyの外のstyleは`.other`で verbatim に保持する。

残っている制約は2つ。`<placement>` / `<offset>` / font overrideはpreserved markup
（`ChordArticulation`・`ChordOrnament`と同じ扱い）。`<text>`の中のinline markup
（`<text><font size="8"/>2</text>`）はplain textに潰れる——§7.1の横断的なgapそのもので、
`StaffText`が既に持っている制約と同じ。testで固定してある。

`STICKING`と`EXPRESSION`は同じtext annotationだがnote添付ではなくvoice streamの
annotationなので、`VoiceElement`にcaseを足す作業になる。`FINGERING`より一段広い。

**［2026-09-04 追記］`STICKING`と`EXPRESSION`もmodel化した。** `SheetMusicCore`の
`Sticking`と`ExpressionText`、`VoiceElement`の`.sticking` / `.expression`、
decoder / encoderは`MSCXDecoder+Sticking.swift` / `MSCXEncoder+Sticking.swift` と
`MSCXDecoder+ExpressionText.swift` / `MSCXEncoder+ExpressionText.swift`（file名はtagではなく
model型に揃えてある）、fixtureは
`Tests/SheetMusicTests/Resources/own/voice-annotations.mscx`。

上流ではどちらもsegment annotationで、`<voice>`の中にそのtickのchord / restの**手前**に
書かれる（`twrite.cpp:3672`の`segment->annotations()`ループがelement本体より先）。
`Harmony`と同じ位置であり、note添付の`Fingering`と違って`VoiceElement`にcaseが要るのはこのため。

`Sticking`は裸の`TextBase`（`twrite.cpp:3175`、readerは`tread.cpp:906`で
`TRead::read(TextBase*)`に丸投げ）なのでmodeled payloadは`<text>`だけ。`Expression`は
それに`<snapToDynamics>`が1つ付く（`tread.cpp:804`）。これは**styled property**
（`expression.cpp:36`が`Sid::snapToDynamics`と対応付けている）なので、**UNSTYLEDかつ
style値と異なるときにしか書かれない**（`xmlwriter.cpp`が`val == def`をskipするので、
style値と同じ上書きは書かれず再読込でstyledに戻る）。だからmodelは`Bool?`で、
nilは「tagが無い = styleに従う」を意味する。

`<style>`はmodelしていない。`Fingering`ではstyleが「2」の意味（指 / 手 / 弦）を決めるので
roleとしてmodelしたが、この2つのstyleはただのtext styleなので§7.3の領分。preserved markup送り。
`<placement>` / `<offset>` / font override、および`Expression`が
`hasVoiceAssignmentProperties()`で書く`<voiceAssignment>` / `<direction>` /
`<centerBetweenStaves>`も同じ。`<text>`のinline markupがplain textに潰れる制約（§7.1）も
同じで、testで固定してある。

model側の型名が`Expression`ではなく**`ExpressionText`**なのは、`SheetMusicFoundation`が
`FoundationEssentials`（無ければ`Foundation`）を`@_exported import`しており、Predicate APIの
`Expression<each Input, Output>`とambiguousになるため。`SheetMusicFoundation`をimportする
portable target全部で起きる——**実際にbuildで踏んだ**。`StaffText` / `SystemText`の命名にも揃う。
MSCXのtag名は`<Expression>`のまま。

**engravingは入れていない。** `LayoutElement`にcaseを足していないので、layoutは幅も位置も
与えないし、MIDIは何も出さない。MSCXのround-tripだけが対象。

残る制約が2つある。どちらもtestでは赤にならないので、ここに書いておく。

- **`<Expression>`はMuseScore 4.1以降のtagで、v3 targetでencodeすると落ちる。**
  4.0と3.x全部はexpression markを`expression` text styleの`<StaffText>`として書いており、
  MuseScoreはMSC 410未満のfileを読み込み時に変換する（`rw/compat/compatutils.cpp:173`が
  threshold、変換本体は`:381` `replaceOldWithNewExpressions`）。**根拠はMuseScore 3.6.2側の
  readerに`<Expression>`分岐が無いこと**であって、ssm側の`rw/read302`ではない——
  `rw/read302`はmeasure readerを自前で持たず`read400`の`StaffRead::readStaff`に委譲するので、
  MuseScore 4 / 5は`version="3.02"`のfile中の`<Expression>`も読む（`read400` / `read410` /
  `read460`のいずれもtagを持つ）。
  ssmは**逆変換をしない**——`<StaffText>`に落とすと読み戻したときに`StaffText`になり、
  `ExpressionText`に戻らないので、preservation gateに嘘のlossが出る。§4.6の
  「MS3形式は変換しない」と同じ判断。v3で`<MeasureRepeat>`が黙って落ちる
  （3.6.2は`<RepeatMeasure>`しか読まない）のと同じ既知の穴。
  `<Sticking>`は**MuseScore 3.3以降**が読む（3.2以前はunknownとして落とす）ので、
  この encoder が出すどのtargetでも問題にならない。

  この2つのversion境界は**release tagを直接見て**確定させた（`git show v4.1.0:…` に
  `"Expression"` あり / `v4.0.2` に無し、`v3.3` の `libmscore/measure.cpp` に `"Sticking"`
  あり / `v3.2.3` に無し、`v4.6.5` の `read460/measureread.cpp` と `write/twrite.cpp` は
  両方を持つ）。**`rw/read460/` に枝があることを「4.6にある」の根拠にしてはいけない** ——
  read460は4.60–4.99のreader *module* で、4.7が足した要素の枝も含む。同様に`rw/read302`は
  measure readerを自前で持たず`read400`に委譲するので、そこに無いことも根拠にならない。
- **`<color>`はdecodeされるがencodeで書き戻されない。** `ElementProperties+MSCX.swift`が
  「colorはdecode専用」と明記しているとおりで、consumed setに`color`が入っている以上
  preserved markupにも回らない。`Fingering`・`ChordOrnament`と同じ挙動。
  consumed setのruleとしてはこれが正しく（decoderが読む以上preservedにも置くとedit後に
  stale copyが残る）、直すには§7.2の`ElementProperties`側の移行が要る。
  **committed fixtureに`<color>`を入れていないので、preservation gateはこのlossを測っていない。**
  そしてその移行をするときは順序に注意が要る: MuseScoreの`<style>`はresetで
  （`TextBase::setProperty(TEXT_STYLE)`→`initTextStyleType`がtext style属性を全部上書きする。
  MuseScore自身が4.6.0–4.6.2でこれを踏んでいる——`rw/read460/tread.cpp:625`）、
  `<color>`をpreservedな`<style>`より**前**に書くとMuseScore側で握り潰される。

### 4.2.1 voice streamに並ぶ要素の実測コスト

`VoiceElement`にcaseを足したときに実際に壊れたexhaustive switchは
**`Sources` 7箇所 + `Tests` 1箇所**（probe buildで列挙）。

**［2026-09-06］この数字は4スライスで実測して同一だった。** 「1回測った」と
「4回測って同じだった」は別の主張なので、測った対象を挙げておく:

| slice | 要素の性質 |
|---|---|
| `STICKING` / `EXPRESSION` | `TextBase` のtext annotation |
| `CAPO` / `STRING_TUNINGS` | `StaffTextBase`。後者は入れ子の`StringData`を持つ |
| `AMBITUS` | `EngravingItem`（`TextBase`ではない）。入れ子のaccidental 2つ |
| `FIGURED_BASS` | `TextBase`。入れ子のitem配列 + **data次第の排他分岐** |

基底classも payload の形も違うのに面が動かない。voice stream要素については
**推定ではなく実測値**として使ってよい。

| 場所 | 内容 |
|---|---|
| `SetElementVisible.swift`（`visibility(of:)`と`setting(_:visible:)`の2つ） | `visible`を持つので対応させた |
| `ScoreFingerprintHasher.swift` | `VoiceElement` case tag 12 / 13、`elementProperties`のoccupant tag 39–42。occupant tagが21始まりなのはcase tagと衝突させないため |
| `LayoutEngine+Placement.swift` | no-op arm |
| `LayoutEngine+Spacing.swift` | no-op arm（幅を取らない） |
| `MidiRenderer+Voice.swift` | no-op arm |
| `MSCXEncoder+Voice+Emit.swift` | encoder dispatch |
| `Tests/.../Helpers/ScoreSemanticComparison.swift` | 差分表示の`shortDesc` |

このうち**no-op armで済んだのは3つ**（Placement / Spacing / MidiRenderer）。残り5つは
実際の値を返す必要がある。判断が要ったのはfingerprintのtag割り当てと、
`SetElementVisible`をこの2要素に対応させるかどうかの2点。

**ただしこの数え方には見えない範囲がある。** compiler が壊すのは exhaustive switch だけで、
`if case`の連鎖と`default:`を持つswitchは**新しいcaseを黙って素通しする**。この slice で
review が見つけた実バグ3件は全部そちら側だった:

| 場所 | 形 | 症状 |
|---|---|---|
| `Score.swift`の`strippingPreservedMarkup(from: VoiceElement)` | `if case`連鎖 | 新caseのbagがclearされない |
| `AdjacentElementSlot.isAnnotation` | `default: false` | segment annotationとして扱われず、`SetDynamic`が既存のdynamicを置換せず二重に挿す |
| `MSCXPreservedMarkupTests.expectNoVoiceElementNameCollisions` | `if case`連鎖 | consumed set のdrift検出から新decoderが外れる |

**`VoiceElement`にcaseを足したら、compilerが黙っている箇所をgrepで別途洗うこと。**
`FIGURED_BASS`やvoice stream上の`SYMBOL`を見積もるときは、exhaustive switch 8箇所に
この3箇所を足した数が実際のコスト。

着手前の見積もりは「`.harmony`をgrepすると13箇所以上出る」だったが、その大半は
`LayoutElement.harmony`側（Placement / Spacing / Translate / YBounds / Skyline /
`ScoreCanvas` / `LayoutBridge`）で、**`LayoutElement`にcaseを足さない限りそこには届かない。**
engravingを別sliceに切るなら、voice stream要素のmodel化コストはnote添付要素の2倍程度で、
事前見積もりより小さい。逆に言うと、この層の本当のコストはmodelではなくengravingの側にある。

**［2026-09-06 追記］`FIGURED_BASS`と`FIGURED_BASS_ITEM`もmodel化した。**
`SheetMusicCore`の`FiguredBass` / `FiguredBassItem`、`VoiceElement`の`.figuredBass`、
decoder / encoderは`MSCXDecoder+FiguredBass.swift` / `MSCXEncoder+FiguredBass.swift`。

#### この要素は自分を2通りに書く——versionではなくdataで分岐する

`v4.6.5:twrite.cpp:1292`:

```cpp
if (item->items().size() < 1) {
    writeProperties(static_cast<const TextBase*>(item), xml, ctx, true);   // 生<text>
} else {
    for (FiguredBassItem* i : item->items()) write(i, xml, ctx);           // <FiguredBassItem>列
    for (const StyledProperty& spp : *item->styledProperties())
        writeProperty(item, xml, spp.pid);                                 // <size> / <align> …
    writeItemProperties(item, xml, ctx);
}
```

MuseScoreはtypedなtextをitemにparseし、**parseに失敗したときだけ生textを書く**。
`ChordOrnament`のMS3 `<Articulation>`形が**versionによる分岐**なのに対し、これは
**同一version内でdata次第の分岐**。model は両方持ち（`items`と`text`）、encoderは
`items.isEmpty`で分岐する。**入力がどちらの形かはfileの子要素で分かる**ので、
decode時に取り違えない（readerも`FiguredBassItem`を明示的に読み、それ以外は
`TextBase`のpropertiesに落ちる）。

**item形式では`<style>`も`<text>`も出ず、代わりにstyled propertyが直接の子として出る。**
だから`TextBase`系のtagをconsumed setに入れてはいけない——text styleを編集したスコアで
`<size>` / `<align>` / `<frameType>`が消える。consumeするのは`onNote` / `ticks` /
`FiguredBassItem` / `text` と共有基底の4つだけ。
副産物として、item形式には`<style>`が無いので§7.2の`<color>`順序制約はこの分岐では起きない。

#### `text`は`items`が空のときだけauthor intent

readerの末尾（`v4.6.5:read460/tread.cpp:1440`）:

```cpp
if (b->items().size() > 0) { b->setXmlText(normalizedText); }   // itemから再生成
```

item形式ではtextが**読み込み時に再生成され、fileの`<text>`は捨てられる**。§4.6.1で立てた
判定基準（readerが再計算するなら派生値）をそのまま当てると、**同じfieldがdata次第で
派生値にもauthor intentにもなる**。両方の言い方が「fieldはどちらか一方」を前提に
しているので、この要素は例外として明記しておく。

#### `<onNote>`は反転default——そして「`propertyDefault`を読め」は規則ではなかった

`v4.6.5:figuredbass.h:329`が`bool m_onNote = true;`、writerは`if (!item->onNote())`で
**falseのときだけ書く**。つまり**tagの不在が`true`を意味する**。`false` defaultで
modelすると、`<onNote>`を持たない大多数のfigured bassが全部「音符間」になり、
round-tripが黙って壊れる。`<ticks>`も同型（`isNotZero()`のときだけ出る）。

**ここで§4.1.1の書き方が一段浅かったことが分かった。** あそこには「タグが無いときの意味は
`propertyDefault`が決める」と書いたが:

| 要素 | C++ member initializer | 正解 |
|---|---|---|
| `Capo.active` | `false` | **`propertyDefault`の`true`** |
| `FiguredBass.onNote` | `true` | **member initializerの`true`** |

**片方ずつ当たって片方ずつ外れる。** 「member initializerを読め」も「`propertyDefault`を
読め」も規則にならない。

**正しくは「writerの省略条件を読め」。** `Capo`は`writeProperty`を使っていて、それは
`propertyDefault`と比較して省略する。`FiguredBass`は`if (!item->onNote())`と明示的に
書いてある。**どちらもwriterが「不在が何を意味するか」を言っていて、そこだけが常に
言っている場所**。`propertyDefault`を見に行くのは、writerが`writeProperty`を使っている
ときにその条件を解決する手段であって、規則そのものではない。

#### `FiguredBassItem`

`brackets`が**5つのintを属性**で持つ（`<offset x= y=>`と同じ形）。
`prefix` / `suffix` / `continuationLine`は**序数**で書かれる——§4.6.1の3階層目。
`Modifier`は none=0 / doubleFlat=1 / flat=2 / natural=3 / sharp=4 / doubleSharp=5 /
cross=6 / backslash=7 / slash=8、`Parenthesis`は none=0 / roundOpen=1 / roundClosed=2 /
squareOpen=3 / squareClosed=4、`ContLine`は none=0 / simple=1 / extended=2。
C++の`displayText` / `normalizedText`はread-onlyな派生propertyでreaderに枝が無いので、
その種の未知childは`FiguredBassItem.preservedMarkup`に残る。

`AdjacentElementSlot.isAnnotation`は**true**。`figuredbass.h:35`が`Segment`のannotationsに
格納されると明記していて、`measureread.cpp:490-513`も`Sticking`と同じannotation branchで
`segment->add(el)`する。**`AMBITUS`は逆**（独自の`SegmentType::Ambitus`）なので、
隣の要素の答えを写さずに毎回上流を見ること。

#### §7.1完了後に確認し直すこと

**`<FiguredBass>`のtext形式は、§7.1が入っても`<text>`内のinline markupを往復しない。**
§7.1が足すのは`preservedTextMarkup`——`<text>`の中身を保持するbag——だが、
`FiguredBass`はそれを持っていない。`MSCXEncoder+FiguredBass.swift`は
inlineで`<text>`を組み立てる箇所として残る。

**effectは狭い。** item形式は`<text>`をそもそも書かないので、影響を受けるのは
**MuseScoreがparseできなかったfigure**だけ。§7.1の`Text/style`と同じ扱いで、
「§7.1が終われば消える」ではなく「§7.1のscope外の別のgap」として残る。

§7.1が完了した時点でここを読み直し、`preservedTextMarkup`をこの要素にも足すか、
足さない理由を書くこと。

### 4.3 記号・画像

| MuseScore | 定義 | ssm | 影響 |
|---|---|---|---|
| `SYMBOL` | `dom/symbol.h:46` | なし | 任意のSMuFL記号添付。`SymId` / font / size / angle / anchor |
| `FSYMBOL` | `dom/symbol.h:93` | なし | 任意fontの1文字 |
| `IMAGE` | `dom/image.h:52` | なし | 埋め込みraster / SVG |

`SYMBOL`は「modelにない記譜をとりあえず貼る」というMuseScore側の逃げ道でもあるので、
実file中の出現頻度は低くない。ssmが`NoteParentheses`だけ特別扱いしている
（`MSCXDecoder+Note.swift:235`）のは、この一般機構が無いための個別対応。

**［2026-09-04 追記／2026-09-05 訂正］`<Symbol>`が付く場所は1箇所ではない。**
read460で`<Symbol>`を子として読む親は、`<Note>`（`tread.cpp:3359`）、
`<BarLine>`（`tread.cpp:2053`、`read(BarLine*)`は`:2032`）、
**box family（`HBox`/`VBox`/`TBox`/`FBox`、`tread.cpp:2203`、`readProperties(Box*)`は`:2166`）**、
`<MMRest>`（`tread.cpp:3236`）、segment直下のannotation（`measureread.cpp:465`）、
そして`BSymbol`の`readProperties`（`tread.cpp:2342`）経由で
`<Symbol>`自身の入れ子（`:2389`）・`<FSymbol>`の中・`<Image>`の中。
clipboard paste（`read460.cpp:689`）もここに来る。

§8が言う「単発で入る」のは**note添付のものだけ**で、annotation位置のものは
`VoiceElement`案件。`<Chord>`の子にはならない
（`readProperties(Chord*)` `:2458`にも`readProperties(ChordRest*)` `:2574`にも分岐が無い）。

*初出時にこの段落は`<BarLine>`を`tread.cpp:2203`と書き、box familyを落としていた。
`:2203`は`readProperties(Box*)`の側。2026-09-05のfableによる上流突合で判明。*

`<FSymbol>`はさらに狭く、**`<Note>`の子にはならない**。read460では`BSymbol`の
`readProperties`（`tread.cpp:2346`）経由、つまり`<Symbol>`・`<FSymbol>`・`<Image>`の
中にしか現れない。

**［2026-09-05 追記］`SYMBOL`のnote添付分はmodel化した。** `EngravingSymbol`
（`Note.symbols`）。`name`は**closed enumにしていない**——`SymId`は約2600個の
open-endedなSMuFL glyph名registryで、ssmは`SymId`型を持たないため。未知の名前をそのまま
往復させるので、**MuseScore自身の再保存より保持量が多い**（上流は`noSym`に潰して書き戻す。
`tread.cpp:2370`、`types/symnames.cpp:50`）。

encoderで1つ注意がある。`TWrite::writeProperties(const BSymbol*)`（`twrite.cpp:1930`）は
**leaf childrenを先に、base element propertyを後に**書く。`ChordBracket`の`Arpeggio`基底
（`twrite.cpp:764`）は逆順なので、**この2要素はencoderのtail順が意図的に違う**。

### 4.4 frame / layout container

| MuseScore | 定義 | ssm | 影響 |
|---|---|---|---|
| MuseScore | file上の親 | 定義 | ssm | 影響 |
|---|---|---|---|---|
| ~~`HBOX`~~ | `<Staff>` | `dom/box.h:35` | **`ScoreBlock.opaqueFrame`**（2026-09-06実装） | 下の追記を参照 |
| ~~`TBOX`~~ | `<Staff>` | `dom/box.h:245` | 同上 | 同上 |
| ~~`FBOX`~~ | `<Staff>` | `dom/box.h:182` | 同上 | 同上 |
| ~~`VBOX`（曲の途中）~~ | `<Staff>` | `dom/box.h` | **`ScoreBlock.verticalFrame`**（2026-09-06実装） | 同上 |
| `SPACER` | **`<Measure>`** | `dom/spacer.h:35` | **model は無いが往復する** | 下の追記を参照 |
| `SYSTEM_DIVIDER` | **`<Measure>`** | `dom/systemdivider.h:32` | 同上 | 同上 |

**［2026-09-06 追記］この節は3箇所間違っていた。**

**1. boxはper-staffではなくscore-levelだった。** 上流のstaff writerが
`if (m->isMeasure() || staffIdx == 0)`（`rw/write/staffwrite.cpp:42`）で、
**measureでないもの＝boxは staffIdx == 0 のときだけ書く**。fixtureでも観測できる——
`Tests/SheetMusicTests/Resources/musicxml/testCodaHBox_ref.mscx`はstaff 1が
`<VBox>`→measure×5→`<HBox>`→measure×3→`<HBox>`→measure×4で、**staff 2はmeasure×12のみ**。

したがってここに書いてあった「`Score.measureBases: [ScoreBlock]`のような並び替えが要る」は
**不要**だった。measureはper-staff、boxはscore-levelという上流の非対称をそのまま写せばよく、
`Score.parts[].staves[].measures`は無変更のまま、score直下に
`blocks: [PositionedScoreBlock]`（`beforeMeasureIndex` + block）という**疎な列**を1本足して済んだ。
`Score.systemMeasures`と同じ形なので、新しい構造原理も持ち込んでいない。
1つの配列に畳む案を採らなかったのは、「全staff共通のbox」と「このstaffだけのmeasure」を
同じ型に同居させることになるから。設計の全文は
`docs/superpowers/specs/2026-09-06-box-family-structure-design.md`。

**2. `SPACER` / `SYSTEM_DIVIDER`はboxと同じ塊ではない。** 両方`<Measure>`の子で
（`rw/read460/measureread.cpp:134-167`）、`MeasureBase`の兄弟ではない。しかもspacerは
`measure->mstaves()[staffIdx]->vspacerDown()`と**staffごとに**読まれる——boxがscore-levelなのと
ちょうど逆向き。そして`consumedMeasureChildren`（`MSCXDecoder+Measure.swift`）にこれらのtagは
1つも入っていないので、**`Measure.preservedMarkup`に入って既に往復している**。
構造変更とは無関係で、model化しても得るものが無い。

**そして`<Spacer>`というtagは存在しない。** 実際の綴りは`vspacer` / `vspacerDown` /
`vspacerFixed` / `vspacerUp`の4つ。この表の「MuseScore」列は`ElementType` enumから起こしてあり、
**file formatから起こしていない**——だから「enumに名前はあるが、その綴りのtagはfileに無い」行が
生まれる。§8の「親をread460で確認すること」はこの列の読み方そのものへの注意でもある。
（確認済みの誤りは4例: §4.6の4件、§4.3の`<Symbol>`の親、§4.1の`StringData`の親、ここ。）

**3. VBoxは「部分的に存在する」より狭かった。** decoderは最初の`<Staff>`を走査して
**`<Measure>`に当たった時点でbreak**していた（`MSCXDecoder+Score.swift`）ので、
曲の途中のVBoxは最初から見ていない。いまは`blocks`が全部拾う。

**実装の形。** `ScoreBlock`は2 case。`.verticalFrame(ScoreFrame)`は`<VBox>`——`LayoutEngine`が
title blockを描くのでtypedのまま。`.opaqueFrame(OpaqueFrame)`は`<HBox>` / `<TBox>` / `<FBox>`で、
kindと子要素まるごとのpreserved markupだけを持つ。4種に別々の型を与えなかったのは、
`readProperties(Box*)`（`rw/read460/tread.cpp:2166`）が`height` / `width` / gap 2種 /
margin 4種 / `boxAutoSize` / `Text` / `Symbol` / `Image` / `FretDiagram`を**4種で共有**していて、
固有なのはHBoxの`createSystemHeader`、FBoxのfret frame 6件、TBoxの単一`Text`だけだから。
そしてssm側ではVBox以外を描くものが無い——**型を付けても読む人がいない**。
layoutを教えるsliceが来たときに型を起こすのが順序として正しい。

`ScoreFrame`にも`preservedMarkup`を足した。title VBoxの`bottomGap`などが
「bagが無いせいで」落ちていたのはこれで直る。

`fingerprint`は無変更。`ScoreFingerprintHasher`は`titleFrame`も`ScoreFrame`も歩いていない
（両fileに0 hit）ので、`blocks`も同じ扱いにした。§8の3段構造でいえばframeも
「score構造の外側」側に落ちる——measure列に位置は持つが、`VoiceElement`にもstaffにも属さない。

**残っているもの。** engravingは別slice。modelには入ったが`LayoutEngine`はHBoxの水平空白も
TBoxのtextも置かない。ただし**現状はboxを丸ごと捨てている**ので、model化してlayoutが無視しても
今より悪くはならない。空の`<Text>`が`FrameText.decode`で`nil`になって落ちる既存経路も残っている
（§7.1のTextContent作業の領分）。

### 4.5 staff / part構造

**［2026-09-06 検算］この節は初出時、8行のうち7行の位置づけを間違えていた。**
**round-trip lossとして残っているのはexcerptの1行だけで、節名の「staff / part構造」自体が
誤誘導だった。** 以下は検算後の表。

| MuseScore | file上の親 | ssm | round-trip |
|---|---|---|---|
| ~~`STAFFTYPE_CHANGE`~~ | **`<Measure>`の子** | model無し | **保持される（実測）** |
| ~~`StaffTypeList`~~ | **file要素ではない** | — | 該当なし |
| ~~`STAFF_STATE`~~ | **voice stream annotation** | model無し | **保持される（実測）** |
| ~~`STAFF_LINES`~~ | **file要素ではない** | — | 該当なし |
| `SHARED_PART` / `Excerpt` / `LinkedObjects` | **`.mscz` container内の別file** | なし | **失われる**。下を参照 |
| ~~`SCOREORDER`~~ | `<Score>`直下の`<Order>` | model無し | **保持される（実測）** |
| ~~`SynthesizerState`~~ | `<Score>`直下の`<Synthesizer>` | model無し | **保持される（実測）** |
| ~~`NoteEvent` / `NoteEventList`~~ | `<Note>`配下の`<Events>` | model無し | **保持される（実測）** |

#### 何を間違えていたか

**1. `STAFFTYPE_CHANGE`は`<Staff>`の兄弟ではなく`<Measure>`の子。**
`readProperties(MeasureBase*)`（`rw/read460/tread.cpp:2291`）で読まれ、`<Measure>` readerの
`measureread.cpp:189`——`readProperties(static_cast<MeasureBase*>(measure), …)`——から到達する。
`consumedMeasureChildren`に無いので`Measure.preservedMarkup`に入る。
**「曲の途中でstaff typeを切り替えられない」のは表現の話であって、保存の話ではない。**

**2. `STAFF_STATE`はvoice streamのannotation。** `measureread.cpp:501`で
`Sticking` / `Capo` / `StringTunings` / `RehearsalMark` / `InstrumentChange` / `FiguredBass`と
**同じ分岐**で読まれ、tickのsegmentに載る。`VoiceElement.preserved`として位置ごと保持される。

**3. `StaffTypeList`と`STAFF_LINES`はfile要素ですらない。** `"StaffTypeList"`も`"StaffLines"`も
`rw/read460/`とrw/write/`に0 hit。前者はstaffが持つstaff typeのC++ container（file上の対応物は
`<Staff>`内の`<StaffType>`で、ssmは既にconsumeしている）、後者は
`Factory::createStaffLines(measure)`が作るlayout objectで、書き出されるtagが無い。
**§4.4の`SPACER`とまったく同じ**——enumに名前はあるが、その綴りのtagはfileに存在しない。

**4. 行番号が2つ入れ替わっていた。** `types/types.h:81`は**`STAFF_LINES`**、`:180`が
**`STAFF_STATE`**（`:135`が`STAFFTYPE_CHANGE`）。この表は逆に引いていた。

この4点目が、§4の表の作られ方についての一番強い証拠になる。**`ElementType` enumから起こしたのに、
そのenumの行番号すら照合されていない。** 要素の実体を1つも見ずに名前を並べ、後から行番号を
当てた形が見える。同種の誤りはこれで**6例目**——§4.6の4件、§4.3の`<Symbol>`の親、
§4.1の`StringData`の親、§4.4の`SPACER`、§4.4の「boxはper-staff」、そしてここ。
**6例出た時点で、これは個別の誤りではなく表の作られ方の問題**として扱うべき。

#### 実測の根拠

`Order`（fixture 7件）・`Synthesizer`（4件）・`Events`（1件）は元々committed fixtureが
持っていて、preservation gateを通っている。`StaffTypeChange`と`StaffState`は**fixtureが1件も
無かった**ので、この検算までは演繹でしかなかった。`own/staff-elements.mscx`と
`StaffStructureRoundTripTests`を足して実測に変えてある——gateはparseできないfixtureを黙って
`continue`するので、fixtureを足すだけでは根拠にならない点も含めて、そのtestで固定した。

#### excerptだけは本物。ただしfidelityとsemanticsで桁が違う

**4.6のexcerptはfile内の要素ではない。** `"Excerpt"`というtagが読まれるのは
`rw/read114/`（MuseScore 1.x）だけ。4.6では`.mscz` container内の**独立した`.mscx` file**で、
`rw/mscloader.cpp:156-205`が1件ずつ完全な`Score`として読み、**link graphは読み込み後に
`Excerpt::linkMeasures`が導出する**。file上にlink graphも安定element IDも無い
（後者はMS5の`<eid>`の話で、§3.6のとおり対象外）。

ssm側は`MSCZReader`がmain `.mscx`だけを読み（同fileのdoc commentに
「thumbnails, pictures, excerpts, … are ignored」と明記）、`MSCZWriter`は
`META-INF/container.xml`とmain `.mscx`の**2 entryしか書かない**。

したがって:

- **round-trip fidelityはcontainer層の作業。** source containerの他のentryをread→writeで
  運ぶだけで、model変更もlink graphも安定IDも要らない。しかも**excerpt以外も同時に直る**
  ——thumbnails / images / audiosettings / excerptのstyle fileが全部同じ理由で落ちている
- **document wrapperが要るのはsemanticsの方。** masterを編集してpart譜が追従する、
  partを第一級で扱う、という話。ここで初めて`ARCHITECTURE.md`の
  「back-pointerを持たない」と交渉になる

初出時のこの節は後者のコストで前者を見積もっていた。**§8優先順4の3項目が全部この形だった**
（§8を参照）。なおcontainer層のpass-throughにも、preserved markupと同じstaleness
（masterを編集するとexcerptが古くなる）が付く。`emitPreservedMarkup = false` /
`strippingPreservedMarkup()`に相当する逃げ道が要る。**そして「運べばMuseScoreが受け取る」は
まだ実測していない。**

### 4.6 note / chord周辺

| MuseScore | 定義 | ssm | 影響 |
|---|---|---|---|
| ~~`ORNAMENT`~~ | `dom/ornament.h:29` | **`ChordOrnament`**（2026-09-04実装） | 下の追記を参照 |
| ~~`AMBITUS`~~ | `dom/ambitus.h:38` | **`Ambitus`**（2026-09-06実装） | 下の追記を参照。**この節の他と違いvoice stream要素** |
| `MMREST_RANGE` | `dom/mmrestrange.h:34` | なし | 多小節休符の範囲label。**measure直下**（下の訂正を参照） |
| ~~`DEAD_SLAPPED`~~ | `dom/deadslapped.h:34` | — | **MSCXに存在しない。parity対象外**（下の訂正を参照） |
| `CHORD_BRACKET` | `dom/chordbracket.h:29` | なし | chord bracket。`<Chord>`の直接の子 |

**［2026-09-04 訂正］この表の4件は「note / chord周辺」で一括りにできない。**
`CHORD_BRACKET`の実装に入る前にread460を読み直して分かったことで、
作業量の見積りが3件とも変わる:

- **`DEAD_SLAPPED`はそもそもMSCXに読み書きされない。** `TRead` / `TWrite`のどちらにも
  `DEAD_SLAPPED`のcaseが無く（`rw/`全体に0 hit）、生成しているのはGuitar Pro importerの
  `gpconverter.cpp:572`だけ。つまり`.mscx`にこの要素は出現しえず、**round-trip lossは起きない**。
  §2.4の「MISSING = fileから消える」がこの行だけ成り立たない。ssmがGuitar Proを
  読むようになれば model gap として復活するが、それはMSCX parityの話ではない。
- **`AMBITUS`はvoice streamの要素。** `measureread.cpp:583`が`readVoice`の中で読み、
  `SegmentType::Ambitus`のsegmentに置く——つまり`<Chord>` / `<Rest>`と並ぶ位置に現れる。
  したがって§8の言う「単独で追加できる」側ではなく、**`VoiceElement`にcaseを足す側**。
  `STICKING` / `EXPRESSION`と同じ棚。
- **`MMREST_RANGE`はmeasure直下**（`measureread.cpp:184`、`MeasureNumber`と同じ列の
  `MeasureNumberBase` = TextBase）。`VoiceElement`は要らないが、ssmは`MeasureNumber`自体を
  modelしていない（`Score+MeasureNumber.swift`は表示番号を計算するだけ）ので、
  measure添付のtext elementを置く場所から作ることになる。`MEASURE_NUMBER`とセットの別slice。

**この節で本当に「単発」なのは`CHORD_BRACKET`だけ**（`tread.cpp:2518`、
`<Chord>`の子として`<Arpeggio>`の隣で読まれる）。

**［2026-09-05 追記］`read460/`は「4.6のreader」ではない。4.60–4.99のreaderで、4.7の追加を含む。**
`CHORD_BRACKET`で実際に踏んだ。upstreamがこの型を作ったのは2025-12-10（`67b083e753`）で、
初出tagは**`v4.7.0`**。`v4.6.5`の`rw/read460/tread.cpp`には`ChordBracket`が**0 hit**、
`v4.7.0`の同じfileには4 hitある。つまり4.7が`read460`モジュールに枝を足した。
そのモジュールが4.60–4.99のfileを全部読む（`rw/rwregister.cpp:52`、§2.2）ので、
**「`read460`にあるから4.6にある」は成り立たない。**

**［2026-09-06 追記］`AMBITUS`はmodel化した。** `SheetMusicCore`の`Ambitus`、
`VoiceElement`の`.ambitus`、decoder / encoderは`MSCXDecoder+Ambitus.swift` /
`MSCXEncoder+Ambitus.swift`、fixtureは`Tests/SheetMusicTests/Resources/own/ambitus.mscx`。
`EngravingItem`派生で`TextBase`ではないので、§7.2の`<style>` reset順序制約は無関係。

### 4.6.1 version罠の3階層目——値の形式は要素ごとに違う

`read460`の罠（要素が4.6にあるか）と`<transposeMode>`の罠（propertyが4.6にあるか）に続く
3つ目で、**これは version だけでは決まらない**。

`v4.6.5:twrite.cpp`を読むと、同じPidが要素によって違う形式で書かれている:

```cpp
// :572-574 — Ambitus
xml.tagProperty(Pid::HEAD_GROUP, int(item->noteHeadGroup()), ...);   // ← 序数
// :2358 — Note
for (Pid id : { ..., Pid::HEAD_GROUP, ..., Pid::HEAD_TYPE, ... }) {
    writeProperty(item, xml, id);                                     // ← 名前
}
```

`HEAD_GROUP` / `HEAD_TYPE` / `MIRROR_HEAD`の3つとも、**`Note`では名前・`Ambitus`では序数**。
同じfile versionの中で、である。加えて5.0-devでは`Ambitus`側の`int(...)`キャストが外れて
名前になるので、**要素差とversion差が両方乗っている**。

読み戻しは両方通る——`TConv::fromXml`に`tag.toInt()`のfallbackがある
（`v4.6.5:typesconv.cpp:2293-2297`、コメントが`// compatibility`）。
なのでssmは**decodeで序数と名前の両方を受け、encodeでは序数を書く**（4.60を名乗る以上、
4.6自身と同じ形にする）。

**`<head>`のdecode / encodeを`Note`と共有するhelperにしてはいけない。** 片方が必ず壊れる。
`MSCXDecoder+Note.swift`が`<head>`をtoken文字列で読んでいるのは、`Note`が名前を書くから
正しい。同じPidだから統一しよう、とやると`Ambitus`が壊れる。

| 階層 | 確認手段 |
|---|---|
| 要素が4.6にあるか | `git show v4.6.5:.../read460/tread.cpp \| grep '"Element"'` |
| propertyが4.6にあるか | `git show v4.6.5:dom/property.h \| grep PID_NAME` |
| **値の形式** | **その要素のwriter関数を読む。grep一発では出ず、要素ごとに読む** |

#### `Ambitus`の設計判断

- **`noteHeadGroup`は`String?`でtagのtextをそのまま持つ。** 上流の`NoteHeadGroup`は約30値の
  **閉じたenum**だが、ssmはnoteheadをenumでmodel化しておらず（`Note.headType`は`String?`）、
  揃える先が無い。序数と名前のどちらが来ても素通しで往復するので、fidelityは保たれる。
  **semantic mappingは保留**であって、原理的にenum化できないという意味ではない。
  保持している序数は**4.6のenum順序に紐づいた値**なので、後でmappingする人は現代のenumに
  素直にindexしてはいけない。
- `noteHeadType`（5値）と`mirror`（3値）は小さいので closed enum + `.other(rawValue:)`。
- **`topPitch` / `topTpc` / `bottomPitch` / `bottomTpc`はfileの値が正。** `Ambitus::setTopPitch`
  （`dom/ambitus.cpp:154`）は`applyLogic == false`のとき`m_topPitch = val; return;`で
  tpc導出も`normalize()`も飛ばし、readerは`setTopPitch(e.readInt(), false)`を呼ぶ——
  **MuseScoreが読み込み時に自分の導出ロジックを明示的に切っている**。
  一般則として、**readerが渡すrecomputeフラグを見れば「派生値かauthor intentか」が分かる**。
  `false`ならfileが勝つのでmodelが持つ。readerが再計算するなら持ってはいけない
  （`ChordOrnament`のcue note `<Chord>`がその逆側の例）。
- `<topAccidental>` / `<bottomAccidental>`はwrapperごとconsumeし、入れ子の`<subtype>`だけを
  modelする。**入れ子の残り（`<role>` / `<small>`等）は落ちる**——`ChordOrnament`が既に
  出荷している同じtradeoffで、現行の機構はsubtreeを半分だけconsumeできない。

**命名の注意。** ssmの`Note.headType`は名前と中身がずれていて、上流の**`HEAD_GROUP`**
（noteheadの形）を保持している（`<head>`を読んでいる）。上流の`HEAD_TYPE`
（whole / half / quarter / breve）はssmに無い。`Ambitus`は両方を持つので、
上流のPid名に素直に寄せた（`noteHeadGroup` / `noteHeadType`）。結果として
**同じlibraryに`headType`が2つあって別のものを指す**状態になる。`Note`側の改名は別slice。

要素の導入versionを主張するときは、reference checkoutの`read460/`ではなく
`git show v4.6.5:…` / `git show v4.7.0:…` で当たること。同じ理由で「MS3が読まない」の
根拠に`rw/read302`を使うのも誤り——`read302`はmeasure readerを`read400`に委譲するので、
MuseScore 4/5は`version="3.02"`のfile中の4.x専用tagも読む。MS3の挙動は
`git show v3.6.2:libmscore/…`で確認する。

実害: ssmは`version="4.60"`を書くので、emitした`<ChordBracket>`は4.7+では往復するが
**4.6.xでは未知tagとして捨てられる**。それでもemitするのが正しい（代替はssm側で毎回失うこと）が、
4.6 readerに対してlosslessではない。

**［2026-09-05 追記］`CHORD_BRACKET`はmodel化した。** `SheetMusicCore`の`ChordBracket`と
`Chord.bracket`、decoder / encoderは`MSCX{Decoder,Encoder}+ChordBracket.swift`、
fixtureは`Tests/SheetMusicTests/Resources/own/chord-brackets.mscx`。
持っているのは`bracketHookLen` / `bracketHookPos` / `bracketRightSide`の3つで、
継承元`Arpeggio`のtag（`userLen1` / `userLen2` / `span` / `play` / `timeStretch`）は
preserved markup。`<subtype>`はMuseScoreのwriterがchord bracketには書かないのでmodelしない
（`twrite.cpp:747`）。`bracketHookPos`の`auto` / `up` / `down`は上流`DirectionV`
（`types/types.h:371-373`）を写した`ChordBracket.HookPosition`にした——ssmは
stem directionすらmodelしておらず、この形の型が1つも無かったため。2人目の利用者が出たら
共有型に昇格させる。

### 4.6.2 grace chordはmodel化した子要素を落とす（構造的な穴）

`CHORD_BRACKET`の実装中に見つかった、この節より広い問題。

`GraceChord`は`graceType` / `duration` / `notes` / `preservedMarkup`しか持たない
（`Sources/SheetMusicCore/Score/GraceChord.swift`）。一方
`MSCXDecoder+Voice.swift`のgrace分岐は`Chord.decode`を通してから`GraceChord`を組み直すので、
**`Chord`がmodelした子要素は全部そこで捨てられる**。`<Arpeggio>` / `<Articulation>` /
`<Ornament>` / `<ChordLine>` / `<Tremolo>` / `<Lyrics>`がこれに当たる。

たちが悪いのは、**要素をmodel化するたびにこの穴が1つ広がる**こと。model化前は
`Chord.preservedMarkup`に残って往復していたものが、model化した瞬間に
`Chord.decode`がそれを取り上げ、grace分岐が捨てる。`<Spanner>`だけは
`mscx.chord.spannerDropped`で診断が出るが、他は無言で消える。

`CHORD_BRACKET`については、grace分岐で元のsubtreeを`GraceChord.preservedMarkup`へ
戻すことで塞いだ（`ChordBracketEdgeTests.graceChordKeepsItsBracketAsPreservedMarkup`が固定）。
**他の要素は塞いでいない。** 本筋は`GraceChord`が`Chord`と同じ子要素を持つか、grace分岐が
狭いconsumed setで自前にpreserved markupを作るかで、どちらもこのsliceの外。
次にchord子要素をmodel化する人は、**grace分岐も一緒に見ること**。

**［2026-09-04 追記］`ORNAMENT`はmodel化した。** `SheetMusicCore`の`ChordOrnament`と
`Chord.ornaments`、decoderは`MSCXDecoder+ChordOrnament.swift`、encoderは
`MSCXEncoder+ChordOrnament.swift`。fixtureは`Tests/SheetMusicTests/Resources/own/ornaments.mscx`。
持っているのは23種のpalette symbol（+ `.unknown`）、`intervalAbove` / `intervalBelow`、
above / belowのaccidental、`ornamentShowAccidental` / `ornamentShowCueNote` /
`startOnUpperNote` / `ornamentStyle` / `play`。

意図的に持っていないものが3つあり、いずれもpreserved markupで往復する:

- **cue noteの`<Chord>`** — `Ornament::computeNotesAboveAndBelow`（`dom/ornament.cpp:253`）が
  親chordのtop noteからlayoutのたびに再計算する派生値。modelに置くと、下のnoteを編集した
  瞬間にstaleになる値をmodelが抱えることになる。
- **`<direction>` / `<placement>`** — ornament固有ではなく`Articulation` / `EngravingItem`の
  base property。`ChordArticulation`も持っていないので揃えた。
- **MuseScore 3形式の変換** — MS3は同じsymbolを`<Articulation><subtype>ornamentTrill</subtype>`
  として書く。これは今まで通り`ChordArticulation.unknown`にdecodeする。`ChordOrnament`に
  寄せるとround-tripのelement形が変わり（`Chord/Articulation`が`Chord/Ornament`になる）、
  gateに嘘のlossが出る。compat変換はparityとは別問題。testで固定してある。

**残っているのはplaybackとlayout。** intervalとaccidentalはmodelにあるが、
`MidiRenderer`はornamentを音に展開しないし、engravingもglyphを置かない。
これは「単独で追加できるMISSING」の外側——`LayoutElement`はwasm / Android bridgeにも
mirrorされるので、それぞれ別sliceになる。intervalをmodelに入れたのは、
その2つが読む先を用意するため。

---

## 5. 情報が落ちるもの（PARTIAL）

件数が多いので影響の大きい順に。全件は各sliceの調査記録に依るが、代表を挙げる。

**［2026-09-06 検算］「PARTIAL」の1語に3つの別状態が畳み込まれていた。**
§2.4の訂正（preserved markupの導入でMISSING = round-trip消失が成り立たなくなった）が、
この節の各論に降りていない。§4で6例出たのと同じ問題が、ここでは**別の形**で出ている——
§4は「file上の位置を間違えていた」、§5は「失われるかどうかを間違えていた」。

| 状態 | 意味 | 分水嶺 |
|---|---|---|
| **round-tripする / model化されていない** | byteは戻るが、型からは読めない | tagがconsumed setに**無い** |
| **model化されているが情報を落とす** | 型はあるが、fileの一部を落とす | tagがconsumed setに**有り**、model化もされている |
| **consumeして再生成する** | fieldは無いが、encoderが他のfieldから導出して書く | consumed setに**有り**、fieldが**無い**が、encoderが書く |
| **consumeされて捨てられる** | 型にも無く、bagにも入らない | consumed setに**有り**、fieldが**無く**、encoderも書かない |

**最後の1つが実損失で、しかも4つ目とdecoderからは見分けがつかない。** consumed setと
fieldだけでは足りず、**encoderがそのtagを書いているかまで見ないと判定できない**。
1段目で止めると`<tpc2>`を損失と誤判定する（§5.3の下の追記）。
そしてconsumed setに入れた時点でpreserved markupの対象から外れるので、
**「model化しないまま consumed set に足す」と、それまで往復していたものがその瞬間から失われる**。
§4.6.1のgrace chordの穴と同じ向きの罠が、tag levelにもある。

**［2026-09-06 追記］3つ目を全decoderで洗い出したところ、2件の実損失が出た。**
`<Measure><stretch>`（user stretch）と`<Measure><noOffset>`（measure number offset）が
consumed setに入っていて誰も読んでいなかった。consumed setから外して往復するようにしてある。

**preservation gateはこれを警告できなかった。** gateはcommitted fixtureの`parent/child`を
数えるので、**どのfixtureにも入っていないtagの損失は測定対象にすら入らない**。
つまりallowlistは「既知の損失の一覧」ではなく「fixtureが偶然踏んだ損失の一覧」で、
allowlistが短いことは損失が少ないことを意味しない。詳細と、この洗い出しで
**損失ではなかった**もの（`<tpc2>` / `<actualKey>`はencoderが再生成する、`<Style>`の大半は
`PageChrome`が持っている、`<multiMeasureRest>`を持つmeasureは意図的に丸ごと捨てる）は
`docs/development/mscx-preserved-markup.md`の「What the allowlist is not」を参照。

**§5.1から§5.4まで全部数え直した。** 結果は節ごとに大きく違い、**分かれ目は
「その型にbagがあるか」だった**——tag単位の4分類は、その手前の条件が満たされて初めて意味を持つ。

| 節 | 結果 |
|---|---|
| §5.1 spanner payload | **大筋が正しい。** payload型（`HairpinPayload`等）にbagが無いのが原因。ただし`LAISSEZ_VIB`は往復する（実測） |
| §5.2 author intent | **大半が誤り。** `Chord` / `Note`はbagを持つので、consumed setに無い子は往復する |
| §5.3 構造・signature | 4件中4件が予想と相違（下の追記） |
| §5.4 instrument / playback | 1行が誤り、残りは未測定（下の追記） |

**検算前の見立て（「§5.1 / §5.2は他より本当にPARTIALである可能性が高い」）は半分当たった。**
§5.1は当たり、§5.2は外れ。理由は上のとおりで、**要素の性質ではなく型のbagの有無**だった。

### 5.1 spanner payload

`Spanner.Kind`（`Spanner.swift:8`）は`volta` / `slur` / `hairpin` / `pedal` / `ottava` /
`textLine` / `glissando` / `vibrato` / `trill` / `palmMute` / `letRing` / `other`の12種。
`other` + `rawType: String`に落ちるのは`GRADUAL_TEMPO_CHANGE`（rit. / accel.のplayback）、
`NOTELINE`、`WHAMMY_BAR`、`RASGUEADO`、`HARMONIC_MARK`、`PICK_SCRAPE`、
`HAMMER_ON_PULL_OFF`、`TAPPING`系。この状態のspannerはlayoutが汎用text lineとして
描くだけで、MIDIは`.volta` / `.hairpin` / `.ottava`しか解釈しない。

さらに`SLine`共通のline style（diagonal / lineWidth / lineStyle / dashes）と
`TextLineBase`共通のフィールド（continueText / endText / hook / hook height / arrow /
gap / align）を持つ型がそもそも無いので、**payloadを持っているhairpinやottavaでも
線種と両端textは落ちる**。

**［2026-09-06 検算］この節は§5.3 / §5.4と違って、大筋が正しい。原因も分かった。**

**`Spanner`はwrapperにbagを持つが、payload型は持たない。**
`HairpinPayload` / `OttavaPayload` / `VibratoPayload` / `TrillPayload`のどれにも
`preservedMarkup`が無い（`Sources/SheetMusicCore/Score/Spanner.swift`）。
`<Spanner>`の未知の子は`Spanner.preservedMarkup`に入るが、
**modelされた`<HairPin>` / `<Volta>` / `<Glissando>`の内側は、そこに届かない**。

これはpreservation gateが既に測っていて、`spannerPayloadReason`が
`HairPin/Segment`・`Segment/off2`・`Segment/offset`・`Segment/subtype`・
`Volta/endHookType`・`Glissando/diagonal`をその理由で許容している——
reason文が「a payload-level bag would be needed」と正確に書いている。
**§5.1が「落ちる」と言っているものの大半は、この1つの構造に帰着する。**

§5.4で数えた「bagを持たない14型」の一段下に、**bagを持たない4つのpayload型**がある。

- `SLUR` — direction、line type、style、partial direction、Bézier編集が落ちる
- `TIE` — `Note.tieForward`/`tieBack`の位置番号のみ。placement / direction / style / 編集済みsegmentなし
- `GLISSANDO` — `showText`、shift、font / line stylingが落ちる。終点側markerを書かない
- `GUITAR_BEND` — bend量（quarter tone）、direction、whammy関連が落ちる（decoderがdiagnosticを出す）
- ~~`LAISSEZ_VIB` / `PARTIAL_TIE` — 専用modelなし。`.other`扱い~~
  **「専用modelが無い」は正しいが、`LAISSEZ_VIB`は落ちない。**
  `<LaissezVib>`は`<Note>`の子で、`consumedNoteChildren`に無いので
  `Note.preservedMarkup`に入って往復する。**しかもこれは実測**——
  `musicxml/testUnterminatedTies_ref.mscx`が持っていて、`allowedLosses`に
  対応entryが無いままgateが通っている。`docs/development/mscx-preserved-markup.md`が
  `<Note><LaissezVib><eid>`を例に挙げているのもこれ。`PARTIAL_TIE`はfixtureに無いので未測定

### 5.2 note / chordのauthor intent

geometryを導出するのは設計どおりだが、**導出できない作者の意図**まで落ちている。

**［2026-09-06 検算］この節は§5.1と逆で、大半が誤り。`Chord`と`Note`は両方bagを持つので、
consumed setに載っていない子は往復する。**

- 手動stem direction / stem長 / no-stem —— **分かれる。**
  ~~手動stem direction~~ **`StemDirection`は`consumedChordChildren`に無いので往復する。**
  一方**stem長は落ちる**——`Stem`はconsumed setに有り、`Chord`が持つのは`stemVisible`だけなので、
  `<Stem>`の中の`<userLen>`は要素ごとconsumeされて消える（§5.3の3分類の3つ目）
- ~~手動`BeamMode`とbeam fragment~~ **`BeamMode`はconsumed setに無く、往復する。**
  `BeamGrouping`が導出algorithmしか持たないのは正しいが、それは
  「modelから読めない」であって「fileから消える」ではない
- ~~`ChordRest.small` / `staffMove` / `crossMeasure`~~ **`staffMove`と`crossMeasure`は往復する**
  （どちらもconsumed setに無い）。**`small`だけは落ちる**——`Chord`側のconsumed setに有るのに
  `Chord`に対応fieldが無い（`Note`側の`small`は`Note.isSmall`があるので往復する）
- ~~`Note`の`headScheme` / `fixed`・`fixedLine` / `tuning` / `ghost` / `deadNote` / `dotsHidden`~~
  **6つともconsumed setに無いので往復する。** `consumedNoteChildren`が挙げているのは
  `Accidental` / `Bend` / `ChordLine` / `Fingering` / `Parenthesis` / `Symbol` / `Spanner` / `Tie` と
  `color` / `endSpanner` / `fret` / `head` / `offset` / `parentheses` / `pitch` / `placement` /
  `play` / `small` / `string` / `tpc` / `tpc2` / `veloType` / `velocity` / `visible` だけ

**残りの行（`Tuplet`・`Accidental.small`・`Fermata.play`・`Arpeggio`各種・`Tremolo`・`TDuration`）は
未検算。** ただし`Tremolo`と`Arpeggio`は§5.4で数えた「bagを持たない型」に入る可能性が高い
（`MSCXDecoder+Tremolo.swift`は`preservedMarkup`に触れていない）ので、そこは
`Chord` / `Note`とは別の結論になるはず。

**この節と§5.1の差は、bagの有無がどこにあるかだけ。** `Chord` / `Note`はbagを持つので
「modelに無い」が「落ちる」を意味しない。`Spanner`のpayload型はbagを持たないので意味する。
**「PARTIAL」と書く前に、その型にbagがあるかを見ること。**
- `Tuplet`のbase duration / bracket・number表示mode / direction / 手動端点 / custom text
- `Accidental.small`、`Fermata.play`、`Arpeggio.span`・`userLen2`・`play`
- `Tremolo`はr8–r64 / c8–c64のみ。r128 / r256 / buzz rollは非対応（diagnostic有り）
- `TDuration`はwhole–256thのみ。long / breve / 512th / 1024thと4点付点が無い

### 5.3 構造・signature

**［2026-09-06 検算］以下の4件は`git show v4.6.5:src/engraving/rw/read460/tread.cpp`の
readerが受けるtag集合と、ssm側のconsumed setを突き合わせて数え直した。**
初出時の記述は取り消し線で残す。`MEASURE`も同じ方法で部分的に確認した。

| 要素 | 4.6.5のreaderが受けるtag |
|---|---|
| `BarLine` | `subtype` `span` `spanFromOffset` `spanToOffset` `Articulation` `Symbol` `Image` `point` `play` |
| `TimeSig` | `sigN` `sigD` `subtype` `showCourtesySig` `stretchN` `stretchD` `textN` `textD` `Groups` `isCourtesy` ＋ 旧形式の`den` `nom1`–`nom4` |
| `KeySig` | `concertKey` `accidental`(旧) `actualKey` `custom` `mode` `subtype` `CustDef` `forInstrumentChange` `showCourtesySig` `isCourtesy` |
| `LayoutBreak` | `subtype` `pause` `startWithLongNames` `startWithMeasureOne` `firstSystemIndentation` |

- `BAR_LINE` — subtypeがtyped enumでなく生string。
  ~~`spanStaff` / `spanFrom` / `spanTo`なし~~ **その綴りのtagは存在しない。**
  実際は`span` / `spanFromOffset` / `spanToOffset`で、**3つともconsumed setに無いので往復する**。
  `Articulation` / `Symbol` / `Image` / `point` / `play`も同じ。
  **落ちているのはsubtypeのtyped化だけ**——生stringとして往復はする。
- `TIMESIG` — integer numerator / denominatorのみ、は正しい。ただし
  ~~`TimeSigType`、text numerator / denominator、local stretch、beam group、括弧が落ちる~~
  **`subtype`（`TimeSigType`）・`textN` / `textD`・`stretchN` / `stretchD`・`Groups`は
  consumed setに無いので往復する。**「括弧」に相当するtagは4.6.5のreaderに存在しない。
  つまりcommon timeとcut timeは**fileからは消えないが、`TimeSignature`からは読めない**。
  1つ目の分類。
- `KEYSIG` — concert fifthsのみ、は正しい。内訳は3分類に分かれる:
  - **往復する（consumed setに無い）**: `CustDef`、`subtype`、`isCourtesy`、
    そしてcustom key signatureの実体である`KeySym`子要素。
    ~~custom key signatureが落ちる~~ **定義そのものは残る**。
    ~~`forInstrumentChange`が落ちる~~ **往復する**
  - **consumeされて捨てられる**: `mode`、`custom`。decoderのdoc commentが理由を書いている
    （`custom` / `mode`はcustom key signatureのfallback判定に使い、fifthsを0に倒す）。
    **意図的な決定であって漏れではないが、bagにも入らないので本当に失われる**
  - `actualKey`はencoderが楽器のtranspositionから生成し直すので、作者が書いた値は残らない
- `LAYOUT_BREAK` — ~~`NOBREAK`が落ちる~~ **往復する。**
  ssmのdecoderはtag名ではなく**subtype単位**で判定していて（`MSCXDecoder+Measure.swift`の
  `modeledLayoutBreakSubtypes`、「A tag-name set cannot …」のcommentがその理由）、
  model化していないsubtypeの`<LayoutBreak>`は要素ごとbagに入る。
  一方**`pause` / `startWithLongNames` / `startWithMeasureOne` / `firstSystemIndentation`は
  落ちる**——これらはline / page / sectionという**model化済みsubtypeの子**なので、
  親要素ごとconsumeされて一緒に消える。落ちる条件が「property単位」ではなく
  「親のsubtypeがmodel化されているかどうか」である点が、初出時の記述では読み取れない。
- `MEASURE` — ~~per-staffのvisibility / stemless / hide-if-emptyが落ちる~~
  **`visible` / `stemless` / `hideIfEmpty`はconsumed setに無いので往復する。**
  `measureNumberMode`も同じ。**落ちるのは`stretch`（user stretch）・`multiMeasureRest`
  （mm rest count）・`noOffset`（measure number offset）で、3つともconsumed setに有るのに
  `Measure`に対応fieldが無い**——3つ目の分類そのもの。
  「noBreak」は上の`LAYOUT_BREAK`のとおり往復する。
- `STAFF` — 時間軸を持つStaffType / Clef / Key listが無い。visibility / cutaway /
  hideWhenEmpty / barline span / per-voice playbackが落ちる
  **（この行は未検算。`<Staff>`宣言側のconsumed setと突き合わせていない）**

### 5.4 instrument / playback

**［2026-09-06 検算］§5.3と同じ手法を当てた。1行は誤り、残りは「落ちる」こと自体は
もっともらしいが、どれも一度も測られていない。**

- `Instrument.id`が内部id・soundId・MusicXML idを1つに潰している（`MSCXDecoder+Instrument.swift`）。
  **これは正しい。** preservation gateの`Instrument/instrumentId`
  （`soundIDReason`）が実測でそう言っている——`<instrumentId>`はdrumsetのときencoderが
  合成するので、preserved markupに逃がすこともできない
- ~~per-staff clef、trait、singleNoteDynamics、glissandoStyleがInstrumentに無い~~
  **「modelに無い」は正しいが、「落ちる」は誤り。** `consumedInstrumentChildren`に
  `clef` / `singleNoteDynamics` / `glissandoStyle` / `trait`のどれも入っていないので、
  **`Instrument.preservedMarkup`に入って往復する**。`MSCXPreservedMarkupTests`の
  `partLevelMarkupSurvives`が`<clef>`について実際にそれを固定している
- channelはprogram / bank / volume / pan / chorus / reverb / port / channelのみ。
  **CC 0 / 7 / 10 / 32 / 91 / 93以外は落ちる**——`controller`がconsumed setに入っていて、
  encoderは6つのfieldから`<controller>`を**合成**するだけなので、任意のCCは戻らない。
  ただし**これは未測定**: committed fixtureにあるctrlは`0` / `7` / `10` / `32`の4つだけで、
  **model外のCCを持つfixtureが1つも無い**（`91` / `93`すらない）。§5.3の`Measure/stretch`と
  同じ形で、gateはこの主張を一度も検査していない
- drumsetはname / head / line / voice / stem / shortcutのみ。duration別notehead、
  variant、panel座標が無い。**未測定**（`<Drum>`の未model子要素を持つfixtureが無い）
- instrument articulationは`descr`が落ちる。**これは他より悪い**——
  `MSCXDecoder+InstrumentArticulation.swift`は`velocity`と`gateTime`を読むだけで、
  **consumed setもpreserved markupも持たない**。consumed setを持つ型は「宣言した子だけ」を
  失うが、**bagを持たない型は読まない子を全部失う**。`<descr>`もfixtureに1件も無いので、
  やはり未測定

#### bagを持たない型が14ある

上の`InstrumentArticulation`は単独の抜けではない。`Sources/SheetMusicMSCX/Decoders/`で
`preservedMarkup`に一度も触れていないdecoderを数えると14件ある。

- **corpusに出てくる**: `GuitarBend`、`InstrumentChange`、`MeasureRepeat`、`StaffText`、`Tempo`
- **corpusに出てこない**: `Breath`、`ChordLine`、`InstrumentArticulation`、`RehearsalMark`、
  `Swing`、`Tremolo`、`HeadType`、`ElementProperties+MSCX`、`TextProperties`

前者のうち`StaffText` / `Tempo`の損失はgateが実際に捕まえていて、`Text/style`などが
§7.1のTextContent作業として`allowedLosses`に載っている。**後者は二重に未測定**——
bagが無いうえにfixtureも無いので、何が落ちているかを言う手段が現状ゼロである。

**§7.1が入ってもこの穴は閉じない。** §7.1が救うのは`<text>`の**中身**（inline markup）で、
それは要素にbagを与えることとは別である。`<StaffText>`が`<text>`と並べて持つ未model子要素
——`<style>`が典型——は、**中身用の入れ物ができても行き先が無いまま**になる。
`allowedLosses`の`Text/style`が§7.1で消えるかどうかは、その作業が
`<text>`の中身だけを扱うのか要素全体にbagを与えるのかで決まる。
**2026-09-06時点のmainでは`StaffText`にbagは無い**（`Sources/SheetMusicCore/Score/StaffText.swift`に
`preservedMarkup`が0 hit）。§7.1完了後にこの行を確認し直すこと。

一般化するとこうなる。**tag単位の「consumedか / fieldがあるか」（上の4分類）の手前に、
型単位の「そもそも受け皿があるか」がある。** 前者は分類できるが、後者はその分類が
始まる前の条件で、bagが無い型では4分類そのものが意味を持たない——
consumed setに載っていない子も等しく落ちるので。

**この節の残りを「落ちる」と書き続けるのは、§5.3で誤りだった書き方と同じ**なので、
上では「落ちる」と「未測定」を分けてある。埋めるにはfixtureを足すしかない
（`docs/development/mscx-preserved-markup.md`の「What the allowlist is not」を参照）。

---

## 6. 意図的に持たないもの（parity対象外）

判断を毎回やり直さないための整理。

- **`*_SEGMENT` 25種、`SEGMENT` / `SYSTEM` / `PAGE` / `STEM` / `HOOK` / `LEDGER_LINE` /
  `STAFF_LINES` / `BEAM`のgeometry / `MEASURE_NUMBER` / `LYRICSLINE`** — `SheetMusicLayout`で導出。
  導出pathは実在する（`LayoutDocument.swift:5`、`LayoutMeasure.swift:5`、
  `FlagGlyph.swift:16`、`LayoutEngine+SystemBuild.swift:945`、`LayoutEngine+Lyrics.swift:393`）。
  ただし§5.2のとおり、**geometryではなくauthor intentは別扱いにすべき**。
- **`SELECTION` / `LASSO` / `SHADOW_NOTE` / `ACTION_ICON` / `ROOT_ITEM` / `DUMMY` /
  `TIME_TICK_ANCHOR` / `INPUT` / `ElementGroup` / `ScoreRange` / `SelectionFilter`** —
  editor runtime。immutable modelに置かない。
- **`InstrumentTemplate` / `ChordList`** — カタログであってscore stateではない。
- **`RepeatList` / `TempoMap` / `TimeSigMap`** — ssmは都度導出（`RepeatListBuilder.swift:4`、
  `Score+EffectiveTempo.swift:5`、`Score+EffectiveMeasureDurations.swift:3`）。
  file消失は起きないのでparity上は問題なし。ただし`Score+ActiveKey.swift:10`は
  mid-measureのkey変更をmeasure単位に粗く丸めており、これは精度の問題として残る。

---

## 7. 横断的な4つのギャップ

個別要素のPARTIALを1つずつ潰すより、この4つを先に入れたほうが一括で効く。

### 7.1 TextBaseのinline markup

MuseScoreは全text elementの中身をXML風のmarkup（`<b>` / `<i>` / `<u>` / `<sym>`）で保持する
（`dom/textbase.h:325`）。`<sym>`はtextの中に音楽記号glyphを埋め込む機構で、
「Swing ♪=♪♪」のような表記はこれで書かれている。

ssmはdecoderで再帰的にflattenしてplain `String`にし（`MSCXDecoder+StaffText.swift:30`）、
encoderは`<text>` 1つを書く（`MSCXEncoder+StaffText.swift:13`）。**書式もglyphも消える。**

最小の形は`TextContent = [TextRun]`（text / glyph / inline formatの3種）。
`TextProperties`は既にface / size / bold / italic / underline / strike / frame type /
paddingを持つので（`TextProperties.swift:12`）、そこにalign / frame width / round /
border / fill / line spacingを足せば揃う。

影響を受けるのは`LYRICS`・`DYNAMIC`・`STAFF_TEXT`・`SYSTEM_TEXT`・`HARMONY`・
`REHEARSAL_MARK`・`MARKER`・`JUMP`・`TEMPO_TEXT`・frame text — つまりtext系全部。

#### 7.1.1 ［2026-09-06 訂正］上の3段落は3箇所で誤っている

着手前に実コードを確認して分かったこと。3件とも、この文書の他の箇所と同じ形の誤り——
**上流のdata構造から推論していて、file上の書かれ方とssmの実際のcodeを見ていない。**

**1. `TEMPO_TEXT`は移行対象ではない。`<text>`が往復値ではなく派生値だから。**
`MSCXEncoder+Tempo.swift:46-70`は`beatsPerSecond` / `beatNote` / `beatDots`から
`<sym>metNoteQuarterUp</sym>`と`<b> = 120</b>`を**生成している**。decoderはglyphを読み戻さず、
printed numberだけ拾う——`MSCXDecoder+Tempo.swift:19-25`が
「version-dependentなnote glyphをtextからparseするのではなく」と明示している。
`TextContent`に移行すると、生成元（`beatsPerSecond`）と`TextContent`のどちらが正なのかが
決まらなくなる。

**判定基準:「encoder側が*その値を*modelから組み立てているなら派生値」。**
15箇所すべてに当てて、該当は`Tempo`だけだった。偽陽性が2件あり、どちらも
「その要素が何かを生成しているか」で切ると引っかかる——`MSCXEncoder+Capo.swift:42`は
`transposeMode`と`<string no=><apply>`をmodelから組み立てているが`<text>`はstored、
`MSCXEncoder+StringTunings.swift:29`も`visibleStrings`を`joined`で作るが`<text>`はstored。
**要素単位ではなく値単位で切ること。**

同じ形はMuseScore側にもある。`<FiguredBass>`のitem形式では、readerが末尾で
`b->setXmlText(normalizedText)`（`v4.6.5:read460/tread.cpp:1440`）と再生成するので、
file上の`<text>`は読み込み時に捨てられる。**「text系」は移行対象として一枚岩ではなく、
`<text>`を往復する要素と生成する要素に分かれる。**

**2. `TextRun`のtreeという最小形は、実fileのmarkupを表現できない。**
committed fixtureに入っている`<b>`はすべてこの形:

```xml
<text><b></b><font face="ScoreText"/><b><font face="FreeSerif"/> = 180</b></text>
```
（`testVoltaTemp.mscx:189`, `repeat53.mscx:124`, `testArpeggio.mscx:161`, `repeat52.mscx:124`）

**空の`<b></b>`と、子を持たない`<font face=…/>`。** これはnested styled runのtreeではなく、
**以降のstyleを変える状態機械**である。MuseScore 2/3期のtempo markingで、
metronome glyphは`<sym>`ではなく**ScoreText fontの1文字**として書かれている。
`[TextRun]`で最初からmodel化しようとすると、この形を「入れ子のstyle」として誤読する。

**3. flattenしているのはdecoderだけではない。serializerも同じ消去をしている。**
`XMLTreeParser.swift:18`が自分でそう書いている——
「child positionsを消し、要素が閉じるとき1度trimする」。
そして`XMLTreeSerializer.swift:31-37`は`node.text`を**全childの前に1度だけ**書き、
childがあるときはindentと改行まで足す。つまり`a<b>B</b>c`は往復で`c`の位置を失うだけでなく、
**元のsourceに無かったwhitespaceが入る。** 直すべき箇所は2つあって、1つではない。

**4.（誤りではないが見積もりに効く）decode側には共有helperがあるが、encode側には無い。**
decodeは`StaffText.plainText(of:)`（`MSCXDecoder+StaffText.swift:34`）を複数のdecoderが使う。
encodeは**14ファイル15箇所**が`XMLTreeNode(name: "text", …)`をinlineで組み立てている。
「decoder 1つを差し替えれば全要素に効く」はdecode側にしか当たらない。

**5.（実装して分かった）decode側の共有helperは、全員が使っているわけではない。**
`plainText(of:)`は**再帰**（自分のcharacter data + 子孫のflatten）だが、
`Marker` / `Jump` / `Lyric` / `FrameText`は**その要素自身のcharacter dataしか読まない**。
`<text><sym>coda</sym></text>`は`StaffText`にとって`"coda"`、`Marker`にとって`""`である。
`FrameText`はさらに独自で、文字列レベルの`stripInlineMarkup`を通していた。

**この差は暗黙で、encoderが「markupのflatten結果 == modelのtext」で再出力を判定した瞬間に
契約に変わる。** 全decoderが同じ規約でflattenしていることを要求してしまうので、
そうでないMarkerでは`<sym>`が永久に戻らない。実装中に実際にこれが起きて、
4つのdecoderが再帰flattenに書き換えられ、MusicXML importのsemantic比較
（`phase2_jumpMarker_semanticEquivalence`の`testCodaHBox`）が落ちて発覚した。

**対処は「decoderが自分のflatten結果を渡す」**——`PreservedTextMarkup.derivedText`。
規約が呼び出し側に閉じるので、どのdecoderも導出を変えずに済む。
**一般則として、共有helperの存在は共通規約の存在を意味しない。** helperの戻り値を
別の場所の判定に使うときは、全呼び出し元がそれを使っているかを確認すること。

**この訂正が測れる形:** preservation gateのallowlistに`"b/font"` / `"text/b"` /
`"text/font"` / `"text/sym"`が載っており、理由文が「§7.1の作業で消す」と自称している
（`MSCXPreservationGateTests.swift:65, 184`）。ただし前3つはfixture上**Tempo markingにしか
出現しない**ので、この節の作業では消えない。消えるのは`"text/sym"`だけで、その根拠は
`repeat53.mscx:203`の`<Marker><text><sym>segno</sym></text>`——Markerの`<text>`はstored
なので、markupを戻せば復活する。

### 7.2 element base property

MuseScoreの`Pid`は376個、base itemは`offset` / `autoplace` / `minDistance` / `color` /
`visible` / `z` / `placement` / `track` / `systemFlag` / `sizeSpatiumDependent` /
`excludeFromOtherParts` / `appearanceLinked` / `positionLinked`を持つ
（`dom/engravingitem.h:253`, `:340`）。

ssmの`ElementProperties`は`visible`と`color`の2つだけ（`ElementProperties.swift:7`）。
しかもencoderは`visible`しか書かず、colorはdecode専用と明記されている
（`ElementProperties+MSCX.swift:15`）。**手動offsetが全element種で保存されない**のが最大の実害。

さらにこのbagを持っていないmodel型がある: `Score` / `Part` / `Staff` / `Measure` / `Voice` /
`Instrument` / `Tuplet` / `Marker` / `Jump` / `MeasureRepeat` / `GraceChord`。

**［2026-09-06 追記］`offset`と`color`を入れた。** `ElementProperties.offset: ScoreOffset?`と、
`color`のencode。`ScoreOffset`はspatium単位の2 Double値型で、`CGPoint`を使っていない——
portable targetは`SheetMusicFoundation`だけをimportする規約（AGENTS.md）があり、
`FrameText.offsetMm`がその例外を`#if canImport(CoreGraphics)`で1箇所だけ引き受けている。
あれはmm単位の絶対offset（`P_TYPE::POINT`のABS型、`value * DPMM`）で、**spatiumの`<offset>`とは
別物なので統合していない**。

#### 7.2.1 共有base propertyを1つ足すと、decoder全部に波及する

見積もりを2回外したので書いておく。

`<offset>`を持つmodel型は6つ（`RehearsalMark` / `Harmony` / `Tempo` / `Swing` /
`InstrumentChange` / `StaffText`）で、MSCX側は12 fileだった。しかし
`ElementProperties(decodingMSCXChildrenOf:)`は**24 decoderが共有**しているので、そこで
`<offset>`を読み始めると6型だけでなく全要素が`elementProperties.offset`を持つ。
preserved bagを持つdecoderのconsumed setに`"offset"`を足さないと、**modelとpreservedの
二重所有**になり`preservedNamesNeverCollide`が落ちる。実際には+14 file、計49 fileになった。

`<color>`も同じで、encoderが自前で書いていたのは5つだが、`mscxChildren()`を呼ぶ
**27箇所すべて**にtrailing呼び出しが要る（呼ばない要素はcolorが書かれないまま残るため）。
23 encoder file。2段合わせて66 fileになった。

**consumed setに足すのは、読む側が実装されたのと同じcommitで。** consumed setは
「preserved markupから除外する」宣言なので、まだ誰も読まないtagを先に入れると、
そのtagは**modelにもbagにも入らず消える**。並行レーンが先回りで`"offset"`を入れていて、
merge前に往復から落ちる状態になっていた。

#### 7.2.2 `<color>`は`<style>`の後に書く（上流とわざと違える）

`Pid::COLOR`はstyled text property（`style/textstyle.cpp:37`ほか、各text styleに
`Color → Pid::COLOR`の行がある）。`<style>`を読むと`setProperty(Pid::TEXT_STYLE, …)`が
`TextBase::initTextStyleType(tid)`の**1引数版**（`dom/textbase.cpp:3078`）を呼び、

```cpp
setTextStyleType(tid);
for (const auto& p : *textStyle(tid)) {
    setProperty(getTextPID(p.pid), styleValue(p.pid, p.sid));
}
```

と**無条件に上書き**する（2引数版`:3026`には`getProperty == propertyDefault`のガードが
あるが、property setter経路はそちらを通らない）。つまり**`<style>`より前に読まれた`<color>`は
潰される**。

そしてMuseScoreのwriter自身が`writeItemProperties`（`<color>`、`twrite.cpp:1361`）→
`Pid::TEXT_STYLE`（`<style>`、`:1362`）の順で書く。**上流は自分のreaderが潰す順序で書いている。**
同じ形の問題は`TempoText`の`symbolSize`について`read460/tread.cpp:627`に
「4.6.0-4.6.2で順序が逆だった」と回避コメント付きで残っているが、colorは未修正。

**ssmは`<color>`を最後（preserved markupの後）に出す。** readerはper-tag dispatchなので
後置でも正しく読まれ、**MuseScore自身よりauthor intentに忠実になる**。byte順を上流に
合わせると、author の色を落とす動作まで再現することになる。
これはこのpackageが「gate以外の理由で」上流の出力形とわざと違える唯一の箇所。

順序制約が実際に効くのは`Harmony` / `Sticking` / `ExpressionText` / `Fingering`の4つだけ
（bagを持ち、そこに未modelの`<style>`が入りうる型）。`StaffText` / `Tempo` / `Swing` /
`InstrumentChange` / `RehearsalMark`は**bagを持っていない**ので`<style>`は今日すでに
捨てられており、位置は無意味——これは§7.3のstyle作業に残る別の穴。
**規則は全要素に一律適用した。** 要素ごとの表にすると次の人が毎回導出し直すことになり、
非TextBase要素では位置が無害なだけなので。

固定しているのは`ElementColorMSCXWriteBackTests`の「`<style>`→`<color>`の順で出る」という
assertion。これが無いと、後のrefactorで上流と同じバグが黙って戻る。**実際に
`MSCXEncoder+Sticking.swift`で`mscxTrailingChildren()`をpreserved markupの前に移して
確かめた**——`["text", "color", "style"]`になって赤くなる。doc に「testで固定済み」と
書くなら、その1行を壊して赤くなるかを一度見ること。緑のままなら固定できていない。

**`Pid::STAFF_COLOR`もXML tag名が`"color"`。** `property.cpp:310`、`Pid::COLOR`
（`:63`）とは別のPidなのに同じ綴りで書かれる。いまは`Staff`が`elementProperties`を
持たないので顕在化していないが、**tag名だけではpropertyを同定できない**ということなので、
§7.3のstyle作業や`Staff`にbagを持たせる作業で効く。consumed setは tag 名で引くので、
`<Staff>`のdecoderが`"color"`をconsumeし始めた時点で共有基底の`<color>`と区別がつかなくなる。

#### 7.2.3 `<placement>`はfingerprintに入れてはいけない

3段目。`<placement>`を共有基底に寄せた（2026-09-06）。`Spanner`だけが持っていたのを
top-levelの`Placement`にして全要素へ。`Spanner.placement`はsugar、`Spanner.Placement`は
aliasなので呼び出し側は無変更。

**この段の制約はfingerprintだった。** `<offset>`は順序制約なし、`<color>`は`<style>`の後、
`<placement>`は**hasherに入れないこと**——段ごとに別の制約が1つずつある。

理由: `<placement>`はspanner以外では preserved markup に落ちていて、**preserved markupは
hashされない**。共有`combineOccupied(_ properties:)`が混ぜ始めると、placementを持つ要素が
1つでもあるscore全部のfingerprintが変わり、**committed replay goldenが全滅する**。
`ScoreFingerprintHasher`が`<offset>`を"display trivia"として除外しているのと同じ分類。

`Spanner.placement`をsugarにすれば既存の`combine(spanner.placement?.rawValue)`は同じ値を
読んで同じbyteを混ぜるので、**`+Occupants.swift`と`+Parity.swift`を1行も触らずに中立が保てる**。
「2つのscoreがplacementだけ違っても同じhash」をtestで固定してある。

**未知のtokenは診断して捨てる。** `"placement"`がconsumed setに入った結果、
`<placement>middle</placement>`のような値はpreserved markupからも外れて消える——
このsliceより前はbagに落ちて生き延びていたので、**狭い範囲の後退**。`PlacementV`は上流で
2値、ssmは4.60対象なので露出は手書き入力に限られるが、**testで「意図的な損失」として固定した**。
既知の損失をtestが説明しているのは構わない。この codebase で繰り返し見つかっているのは
未知の損失の方。

### 7.3 style

`Sid`は2050個（`style/styledef.h:50-2276`）、`ScoreStyle`は10 property
（spatium / pageLayout / pageChrome / swingUnit / swingRatio / 4種のalign / ottavaNumbersOnly）。
`MSCXDecoder+Style.swift:11`はこのsubsetだけを読み、他は捨てる。

`TextStyleType`は76対21で、欠けている55はpage系（`DEFAULT` / `COPYRIGHT` /
`INSTRUMENT_LONG` / `INSTRUMENT_SHORT` / `FRAME`…）、measure系（`MEASURE_NUMBER` /
`METRONOME` / `TEMPO_CHANGE` / `REPEAT_*`…）、note系（`TUPLET` / `ARTICULATION` /
`FINGERING` / `STRING_NUMBER` / TAB系…）、line系（`VOLTA` / `OTTAVA` / `PALM_MUTE`…）、
`USER1`–`USER12`。

2050個を全部持つのは現実的でない。判断としては「**engravingに影響するSidだけ**を段階的に
足す」か、「**未modelのstyle XMLをopaqueに保持してwrite時に戻す**」かの二択。後者なら
model parityを広げずにround-trip lossだけ止められるので、費用対効果は高い。

#### 7.3.1 ［2026-09-06 訂正］後者は既に入っている。この節は二択が開いているかのように読める

**「未modelのstyle XMLをopaqueに保持する」は優先順1（preserved markup）で実装済み**で、
2050対10という数字はround-trip lossを一切意味していない。

`MSCXDecoder+Style.swift:56`:

```swift
let inline = node.preservedMarkup(consuming: consumedStyleChildren)
```

**consumed setに無い`<Style>`の子は全部bagに入って往復する。** しかも同じ関数は
`.mscz`の`score_style.mss`側とinline側をtag名でmergeしていて、
「style fileにしか無いkeyがinline化で消える」という二次的な穴まで塞いである。

**gateで確認できる。** preservation gateの`allowedLosses`に載っている`Style/`は**1件だけ**で、
それも損失ではない:

```
"Style/Spatium" — by design: the v4 encoder writes lowercase <spatium>;
                  the decoded value round-trips.
```

**綴りの変更であって値の損失ではない。** つまり`<Style>`配下でfileから消えるものは無い。
`TextStyleType`の21対76も同様で、未modelの`<TextStyle>`は`<Style>`の未model子として
bagに入る——**§2.4の「MISSING = fileから消える」がstyleには最初から当てはまらない。**

**残っているのは意味論の側だけ。** styleを`ScoreStyle`のfieldとして持たない限り、
layoutとrendererはそれに反応できないので、**「MuseScoreと同じに見えるか」は解けていない**。
ただしそれは**fidelityの問題ではなくengravingの問題**で、この文書の§2.4の判定区分とは別の軸。
費用対効果を論じるべき対象は「どのSidをengravingに繋ぐか」であって、
「保持するかどうか」ではもう無い。

**この節が古くなった形は§8のリストと同じ。** 書かれた時点では二択が開いていて、
優先順1がその片方を実装し、**実装した人がこの節を更新しなかった**。
§7.1・§7.2が完了した今、§7の4つのうち§7.3は「**round-tripは解決済み、engravingは未着手**」
という状態で、他の3つと同じ列に並べると残工事を過大に見積もる。

### 7.4 時間軸を持つmap

MuseScoreは`KeyList` / `ClefList` / `StaffTypeList` / `TimeSigMap`をtick keyのmapとして持つ。
ssmはinline element + 都度導出。導出方針自体は妥当だが、以下が具体的な穴になっている。

- `StaffTypeList`が無いため`STAFFTYPE_CHANGE`を表現できない（§4.5）
- `Score+ActiveKey.swift:10`がmid-measureのkey変更をmeasure単位に丸める
- `TimeSigMap`のnominal / actual分離が無く、`TimeSignature`はinteger分数のみ

---

## 8. 推奨する順序

parity作業として意味のある依存順。対象は出荷版のMuseScore 4.6 / 4.7。

0. **MSC 5.00のversion guard** — §3.3。数行。実装ではなく、静かな消失を
   説明可能な失敗に変えるためのもの。他と独立なのでいつでも入る。
1. **未modelのXMLをopaqueに保持してwriteで戻す機構** — §7.3後段。model parityを進める前に
   round-trip lossを止める。MISSING 25件の実害の大半がこれで消える。
2. **横断的な4つ**（§7）— TextContent、ElementProperties拡張、style、時間軸map。
   個別要素のPARTIALの大半がここに帰着する。
3. **単独で追加できるMISSING** — ~~`ORNAMENT`~~（2026-09-04完了、§4.6の追記）、
   ~~`FINGERING`~~（2026-09-04完了、§4.2の追記）、
   ~~`StringData`~~+~~`STRING_TUNINGS`~~+~~`CAPO`~~（§4.1の追記。前者は2026-09-04、
   後2者は2026-09-06）+`FRET_DIAGRAM`、
   ~~`STICKING`/`EXPRESSION`~~（2026-09-04完了、§4.2の追記）、
   ~~`FIGURED_BASS`~~（2026-09-06完了、§4.2の追記）、
   `FSYMBOL`、**annotation位置の**`SYMBOL`。

   **［2026-09-06 訂正］この行は2件古かった。** `SYMBOL`は**note添付分が
   2026-09-05にmodel化済み**（`EngravingSymbol`、§4.3の追記）で、残っているのは
   annotation位置のものだけ。`SPACER`は**外した**——§4.4の表が「model は無いが往復する」と
   書いているとおりで、しかも`<Spacer>`という綴りのtagは存在せず（実際は`vspacer` /
   `vspacerDown`）、ssmは縦方向の手動間隔調整をlayoutしないのでmodel化してもinertなdataになる。
   **§2.4の「MISSING = fileから消える」が成り立たないので、parityの穴ではない。**
   消した理由をここに残すのは、§4.4を読んだ人が「§8に無いのは見落としでは」と
   再調査しないため。

   **この行が古かったことの意味。** §8は「次に何をやるか」を決めるために読まれる節なので、
   **古いリストはそのまま作業指示になる。** 誰かが`SPACER`を実装しに行って、往復済みだと
   気づくまで半日使う経路が実在した。§4を更新した人が§8を更新していない、という形で
   2件とも生まれている——**§4の追記と§8のリストは同じcommitで動かすこと。**
   互いに独立なので並列に進められる。

   実装して分かったこの層の境目: **noteやchordに直接ぶら下がる要素は単発で入る**
   （`ORNAMENT`・`FINGERING`・`CHORD_BRACKET`がそうだった）。**voice streamに並ぶ要素は
   `VoiceElement`にcaseを足す話になる**（`STICKING`・`EXPRESSION`・`FIGURED_BASS`・
   voice stream上の`SYMBOL`・`AMBITUS`）。同じ「単独で追加できる」でも作業量が違うので、
   分けて見積もること。

   **ただしその差は2倍程度で、当初の見積りは過大だった（2026-09-05に実測）。**
   ここには「`.harmony`のgrepが13箇所以上出るので、fingerprint・layout・
   `ScoreCanvas`・`LayoutBridge`・edit commandまで届く」と書いてあったが、
   enumにcaseを足してprobe buildを回すとexhaustive switchは**Sources 7箇所 +
   Tests 1箇所**しかなく、**うち3つがno-op arm**だった（残り5つは実際の値を返す）。
   layout（Placement / Spacing / Skyline）・`ScoreCanvas`・`LayoutBridge`には**届かない**
   ——あれは`LayoutElement.harmony`側の話で、`LayoutElement`にcaseを足さない限り無関係。
   engravingを別sliceに切る前提なら、voice stream要素のmodel化はnote添付要素の2倍程度で
   見積もってよい。内訳は§4.2.1。

   **その2段の下にもう1段ある。`<Instrument>`配下のようにscore構造の外側にぶら下がる要素は、
   `VoiceElement`にもfingerprintにも触れずに終わる。** `Instrument`は
   `ScoreFingerprintHasher`が歩いていないので、`StringData`ではoccupants方式の
   hasher追加すら要らなかった。全部で3段——instrument / part配下、note・chord添付、
   voice stream。

   **fingerprintのoccupant tagはレーンをまたいで一意にすること。** 別worktreeで並行実装すると
   双方が「未使用の次の番号」として同じ値を選ぶ。実際に2026-09-05に衝突した。
   **global な採番があるのはoccupant tagだけ。case tagはswitchごとにローカル。**
   これが正しい問いの立て方で、「次に空いている番号は何か」ではなく
   **「このtagはどのstreamに属するか」**を先に決める。

   - **occupant tag（global、21-）** —— `combineOccupied`が親のhashに混ぜるので、
     どこから来ても一意でなければならない。**レーンをまたいで採番を配る対象はこれだけ。**
     現在 21-54: 21-28 measure flag、29-32 chord / note、33-35 `ChordOrnament`、
     36-38 `Fingering`、39-42 voice stream annotation、43-45 `ChordBracket`、
     46-48 `EngravingSymbol`、49-50 `Capo`、51-52 `StringTunings`、53-54 `Ambitus`。
     **次の空きは55。**
   - **case tag（switchごとにローカル、0-）** —— 少なくとも2本ある。
     `combine(_ element: VoiceElement)`が **0-16**（16が`Ambitus`、次は17）、
     `combine(_ element: SystemElement)`が **0-4**（`ScoreFingerprintHasher.swift:307`。
     tempo / rehearsalMark / staffText / swing / instrumentChange、次は5）。
     **同じ0から始まるが別のstreamなので衝突しない。**
   - さらに小さいordinalが**switchの数だけ**ある——`combine(_ duration:)`、
     `combine(_ note:)`、`combine(_ articulation:)`、`combine(_ glissando:)`、
     `combine(_ lyric:)`、`combine(_ tremolo:)`、`combine(_ chordLine:)`…
     どれも0から始まる小さい整数を混ぜている。

   occupant tagが**21**始まりなのは、0-20を`VoiceElement`のcase tag用に空けているから
   （hasherのheaderに"21 and up, so no tag can be mistaken for a `VoiceElement` case tag"）。

   **［2026-09-06 訂正2回］**この段落は2度直っている。1度目は「16-20は削除された番号なので
   再利用禁止」という**誤り**の訂正——16-20は`VoiceElement` case tagの予約領域である。
   2度目は、その訂正が書いた「名前空間は2つ」という言い方が**まだ足りなかった**こと。
   実際にはcase tagはswitchごとにローカルで、`SystemElement`にcaseを足す人が
   「次の空きは17」を取ってしまう形になっていた（衝突はしないが、`VoiceElement`の番号である）。

   **数えるだけでは足りず、規約を読むだけでも足りず、その番号を混ぜている呼び出し元まで見ること。**
   素朴に`combine\([0-9]+\)`をgrepすると`combineFlags`のmeasure flag（21-28）も
   case tagに見える。表はmergeのたびにstaleになるので数え直す必要があるが、
   **数え方（`grep -c`は行数、`-o`は出現数）でも結果が変わる**。

   この段落の訂正2回は、どちらも同じ形で生まれている——**観測が解釈を経て規則になる段で、
   根拠が確認されていない**。1度目は「16-20が空いている」という観測に「削除された番号かも」
   という解釈が付いた。2度目は「名前空間は2つ」という**訂正そのもの**が、確認した2つだけを
   数えて書かれた。**訂正は訂正であるがゆえに検証されにくい。**

   **optionalをfingerprintに混ぜるときはpresence byteを落とさないこと。** これはtag採番とは
   別の軸——tagは「衝突させない」話、presenceは「情報を落とさない」話。`nil`と「値がordinal 0」は
   別物で、presenceを省くと両者が同じhashになる。`combinePresence`が`nil`で`0`、非nilで`1`+値を
   混ぜているのはそのため。

   2026-09-05〜06に**3回**出た——`ExpressionText.snapToDynamics`（`Bool?`）、
   `+Parity.swift`分割でhelperをinline化しようとしたとき、`Ambitus.mirror`（`.auto`がordinal 0）。
   **毎回違うレーンが違う入口から来ている**ので、「optionalをhashに混ぜる」場面に来たら疑うこと。
   diffを縮めたくなる場所でもあるので、helperを展開するときは特に。

   **どちら側かは要素名では決まらない。親をread460で確認すること。** §4の節見出しは
   上流のelement familyで切ってあり、file上の親子関係とは一致しない。実際に
   §4.6「note / chord周辺」の4件を確認したら、単発だったのは`CHORD_BRACKET`だけで、
   `AMBITUS`はvoice stream、`MMREST_RANGE`はmeasure直下、`DEAD_SLAPPED`は
   **MSCXに読み書きが存在しない**（parity対象外）だった。§4.6の訂正を参照。
   `SYMBOL`も同様に、note添付だけが単発で、annotation位置のものは`VoiceElement`側
   （§4.3の追記）。
4. **構造変更を伴うもの** — ~~box family~~（2026-09-06完了、§4.4の追記）、
   ~~`STAFFTYPE_CHANGE`（staffの時間軸）~~（2026-09-06検算、§4.5）、
   そして**excerpt / linked parts**——ただし下記のとおりfidelityとsemanticsで桁が違う。

   **この列は3項目とも、着手前の検算で見積もりを外していた。しかも3件とも同じ形——
   fidelityのコストをsemanticsのコストで見積もっていた。**

   | 項目 | 初出時の見立て | 検算結果 |
   |---|---|---|
   | box family | `MeasureBase`相当の並びが要る | score直下の疎な列1本で足りた（§4.4） |
   | staff時間軸 | 構造変更が要る | 8行中7行は既に往復済み。要素ですらない行が2つ（§4.5） |
   | excerpt | `ARCHITECTURE.md`と正面から交渉 | fidelityはcontainer層のpass-through 1本（§4.5） |

   誤りの出どころも3件とも同じで、**上流のdata構造からssmに要る形を推論していた**。
   boxは「MuseScoreがlinked listで持っているから同じ形が要る」、excerptは
   「`Excerpt`クラスがlink graphを持つから同じものが要る」。**見るべきなのはdata構造ではなく
   file上の書かれ方**——writerが`staffIdx == 0`でしかboxを書かない時点でboxはscore-levelだと
   分かるし、link graphがfileに無く読み込み後に`linkMeasures`で導出される時点で、
   保存に必要なのはlink graphではないと分かる。

   **残工事の見積もりは、この列以外もまだ引き直していない。** 着手前に
   「その要素はfile上どこにいるか」「いま実際に失われているか」をread460と
   preservation gateで確認するのを、実装前の定型手順にすること。§4の表は
   `ElementType` enumから起こされていてfile formatから起こされていない（§4.5に6例）。

**MSC 5.00の`<SpannerMap>` + EID対応はこの列に入れない。** `v5.0.0-alpha` tagが立った時点で
着手する（§3.6・§3.7）。1を先に済ませておけば、対応が入る前でもMS5 fileはデータ欠損しない。

---

## 9. 検証状況

**独立に確認済み（この文書の著者がgrep / file読みで直接確認）:**

- MuseScore checkoutのversion（`version.cmake`、`constants.h:31`）
- `<SpannerMap>` の書き出しpathと`read460` / `read500`の非対称（`writer.cpp:265`、
  `twrite.cpp:512`、`read460/measureread.cpp:334`、`read500/read500.cpp:194`）
- spanner endpointがEID / `startTick`+`ticks`表現に変わっていること（`twrite.cpp:1663-1697`）と、
  slurがspanner mapに入ること（`dom/score.cpp:1106-1118`）
- ssmが`<eid>`を意図的に無視していること（`MSCXDecoder+Chord.swift:78-81`）
- ssmのversion検出がmajor >= 4を`.v4`に丸めること（`MSCXDecoder+Score.swift:236-256`）
- fixtureが`version="4.60"`でinline `<Spanner>`を持ち、`SpannerMap`を含まないこと
- MISSING 25件すべてが`Sources/SheetMusicCore`・`Sources/SheetMusicMSCX`に0 hitであること
- 未知elementを黙って捨てる旨（`MSCXDecoder+Voice.swift:329`）とpassthroughの不在
- `Sid` 2050、`TextStyleType` 76対21、`ScoreStyle` 10 property、`ElementType` 147（うち`*_SEGMENT` 25）
- 出荷版が4.7.x / MSC 4.70であること（tag一覧、`git show v4.7.4:…/constants.h`）と、
  `v4.7.4`が`<SpannerMap>`を書かないこと（同tagの`twrite.cpp`に0 hit）
- `RWRegister::reader`が460–499を`Read460`で読むこと（`rw/rwregister.cpp:52`）と、
  4.60→4.70の差分が`mscVersion() < 470`分岐10箇所に限られること
- §3.4・§3.5のcommit / tag日付と月次commit数（`git log`・`git tag`の出力そのもの）と、
  repository内にrelease scheduleの記載が無いこと（`.github/`・`docs/`を確認）
- 4.6サイクルでリリース11日前まで永続形式が変わっていたこと
  （`rw/write`の2025-09 commit一覧）

**Codex agentの報告に依拠し、個別には再確認していない部分:**

- 各PARTIAL項目の「落ちるfield」の網羅性。代表例は確認したが全フィールドは追っていない
- `Pid` 376という数（`property.h`の`END`序数として報告されたもの）
- MuseScore側の`twrite.cpp`各行番号

**未実施:**

- 実fileでのround-trip検証。本調査は静的読解のみで、MuseScore 5で保存したfileをssmに
  通す実験はしていない。§3の結論はcode pathからの演繹であり、実測ではない
- MusicXML importer側のparity。MSCXのみを対象にした
