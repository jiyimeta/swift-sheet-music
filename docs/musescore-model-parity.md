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

1. **要素そのものが存在しない（MISSING）: 25件** — fret diagram、figured bass、capo、
   string tunings、harp pedal diagram、fingering、sticking、expression、symbol、image、
   HBox / TBox / FBox、spacer、staff type change、linked parts（excerpt）など。
   MSCX decoderは未知elementを黙って捨てる（`MSCXDecoder+Voice.swift:329`）ので、
   これらはread→writeで**fileから削除される**。詳細は §4。

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
消えるものは限定され、gateのallowlistに理由付きで列挙されている。主なものは
`<eid>`（MS5 identity、意図的に捨てる）、`<instrumentId>`（Sound IDがattributeの`id`と
畳まれている）、`<text>`のinline markup（§7.1のTextContent作業待ち）、
`<Staff>` body直下のbox（§4.4の構造作業待ち）。

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
| `STRING_TUNINGS` | `dom/stringtunings.h:49` | なし | preset・表示弦・tuning dataが消える |
| `CAPO` | `types/types.h:1368`（`CapoParams`） | なし | capo位置・除外弦・transpose modeが消える。playback pitchに影響 |
| `StringData`（Instrument配下） | `dom/stringdata.h:42` | なし | TAB楽器のtuningを持てない。`Note.string`/`fret`は保持するが、検証も再計算もできない（`MSCXDecoder+Note.swift:51`に「never reach here」の注釈あり） |
| `TAB_DURATION_SYMBOL` | `dom/tabdurationsymbol.h:40` | なし | TABのduration表示 |
| `TREMOLOBAR` | `dom/tremolobar.h:37` | なし | whammy barのpitch curve。ssmの`Tremolo`は別物（beam tremolo） |
| `GUITAR_BEND_TEXT` | `twrite.cpp:1609` | なし | bend labelのuser編集 |
| `HARP_DIAGRAM` | `dom/harppedaldiagram.h` | なし | harp pedal 7状態 |

TABをまともに扱うなら`StringData`が起点。これが無いと`FRET_DIAGRAM`も`STRING_TUNINGS`も
単体では意味を持ちにくい。

### 4.2 text annotation系

| MuseScore | 定義 | ssm | 影響 |
|---|---|---|---|
| `EXPRESSION` | `twrite.cpp:1343` | なし | 表情記号text。dynamicとは別element |
| `FINGERING` | `types/types.h:121` | なし | 運指番号。note添付 |
| `STICKING` | `dom/sticking.h:35` | なし | 打楽器のR/L |
| `FIGURED_BASS`＋`FIGURED_BASS_ITEM` | `dom/figuredbass.h:91` | なし | 数字付低音。prefix / digit / suffix / continuationの構造 |
| `PLAYTECH_ANNOTATION` | `dom/playtechannotation.h:35` | なし | 奏法指定（pizz.等）とplayback反映 |
| `SOUND_FLAG` | `twrite.cpp:3273` | なし | StaffTextの子。preset・奏法・全staff適用 |
| `PLAY_COUNT_TEXT` | `twrite.cpp:2743`（MSC 5.00） | なし | 反復回数表示 |
| `STAVE_SHARING_LABEL` | `dom/stavesharinglabel.h:27`（MSC 5.00） | なし | staff共有label |
| `TRIPLET_FEEL` | `dom/tripletfeel.h:28` | なし | ssmの`Swing`とは別概念。typed feel + 生成text |

### 4.3 記号・画像

| MuseScore | 定義 | ssm | 影響 |
|---|---|---|---|
| `SYMBOL` | `dom/symbol.h:46` | なし | 任意のSMuFL記号添付。`SymId` / font / size / angle / anchor |
| `FSYMBOL` | `dom/symbol.h:93` | なし | 任意fontの1文字 |
| `IMAGE` | `dom/image.h:52` | なし | 埋め込みraster / SVG |

`SYMBOL`は「modelにない記譜をとりあえず貼る」というMuseScore側の逃げ道でもあるので、
実file中の出現頻度は低くない。ssmが`NoteParentheses`だけ特別扱いしている
（`MSCXDecoder+Note.swift:235`）のは、この一般機構が無いための個別対応。

### 4.4 frame / layout container

| MuseScore | 定義 | ssm | 影響 |
|---|---|---|---|
| `HBOX` | `dom/box.h:35` | なし | 水平frame全般 |
| `TBOX` | `dom/box.h:245` | なし | text frame |
| `FBOX` | `dom/box.h:182` | なし | fret diagram frame |
| `SPACER` | `dom/spacer.h:35` | なし | UP / DOWN / FIXEDの手動間隔調整 |
| `SYSTEM_DIVIDER` | `dom/systemdivider.h:32` | なし | system間の区切り記号 |

VBoxだけは`ScoreFrame`として部分的に存在するが、**先頭measureより前の1つ目のtitle frameのみ**
（`MSCXDecoder+Score.swift:78`）。曲の途中に挟まるVBox、nested frame、margin / gap / auto-sizeは無い。

MuseScoreは`MeasureBase`のlinked listとしてmeasureとboxを同列に並べるが、ssmは
`Score.parts[].staves[].measures`という配列で、boxの居場所が構造的にない。ここは
`Score.measureBases: [ScoreBlock]`のような並び替えが要るので、単発の追加では済まない。

### 4.5 staff / part構造

| MuseScore | 定義 | ssm | 影響 |
|---|---|---|---|
| `STAFFTYPE_CHANGE` | `dom/stafftypechange.h:38` | なし | 曲の途中でpitched↔TAB↔percussionを切り替えられない |
| `StaffTypeList` | `dom/stafftypelist.h:35` | なし | 同上（時間軸を持つstaff type） |
| `STAFF_STATE` | `types/types.h:81` | なし | staff状態変更 |
| `STAFF_LINES` | `types/types.h:180` | なし | measure単位のline数上書き |
| `SHARED_PART` / `Excerpt` / `LinkedObjects` | `dom/excerpt.h:41`, `dom/linkedobjects.h:30` | なし | part譜がない。`MSCZReader.swift:5`にexcerptを無視する旨の明記あり |
| `SCOREORDER` | `dom/scoreorder.h` | なし | part並び順のpolicy |
| `SynthesizerState` | `dom/synthesizerstate.h:41` | なし | score固有のsynth / effect設定 |
| `NoteEvent` / `NoteEventList` | `dom/noteevent.h:36` | なし | user編集済みplayback event（`<Events>`）。`MSCXDecoder+Note.swift:21`が到達しない |

**linked parts（excerpt）が単独で一番重い。** 他のMISSINGが「型を1つ足す」で済むのに対し、
これはimmutable `Score`の外側にdocument wrapper（master score + excerpt定義 + 安定element ID +
link graph）を作る話で、value type設計そのものへの追加になる。`ARCHITECTURE.md`が謳う
「back-pointerを持たない」方針と正面から交渉が要る唯一の項目。

### 4.6 note / chord周辺

| MuseScore | 定義 | ssm | 影響 |
|---|---|---|---|
| `ORNAMENT` | `dom/ornament.h:29` | なし | MuseScore 4で`Articulation`から分離したornament。interval / accidental / cue note / playback。chord decoderは`<Articulation>`しか見ない（`MSCXDecoder+Chord.swift:31`） |
| `AMBITUS` | `dom/ambitus.h:38` | なし | 音域表示 |
| `MMREST_RANGE` | `dom/mmrestrange.h:34` | なし | 多小節休符の範囲label |
| `DEAD_SLAPPED` | `dom/deadslapped.h:34` | なし | rest添付のdead slap |
| `CHORD_BRACKET` | `dom/chordbracket.h:29` | なし | chord bracket |

`ORNAMENT`が実質的に一番効く。trill / turn / mordentのplayback intervalとaccidentalが
MuseScore 4以降ここに載っているため、無いと装飾音のMIDI再現ができない。

---

## 5. 情報が落ちるもの（PARTIAL）

件数が多いので影響の大きい順に。全件は各sliceの調査記録に依るが、代表を挙げる。

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

- `SLUR` — direction、line type、style、partial direction、Bézier編集が落ちる
- `TIE` — `Note.tieForward`/`tieBack`の位置番号のみ。placement / direction / style / 編集済みsegmentなし
- `GLISSANDO` — `showText`、shift、font / line stylingが落ちる。終点側markerを書かない
- `GUITAR_BEND` — bend量（quarter tone）、direction、whammy関連が落ちる（decoderがdiagnosticを出す）
- `LAISSEZ_VIB` / `PARTIAL_TIE` — 専用modelなし。`.other`扱い

### 5.2 note / chordのauthor intent

geometryを導出するのは設計どおりだが、**導出できない作者の意図**まで落ちている。

- 手動stem direction / stem長 / no-stem（`Chord`は`stemVisible`相当のみ）
- 手動`BeamMode`とbeam fragment（`BeamGrouping`は導出algorithmのみ）
- `ChordRest.small` / `staffMove`（cross-staff） / `crossMeasure`
- `Note`の`headScheme` / `fixed`・`fixedLine` / `tuning` / `ghost` / `deadNote` / `dotsHidden`
- `Tuplet`のbase duration / bracket・number表示mode / direction / 手動端点 / custom text
- `Accidental.small`、`Fermata.play`、`Arpeggio.span`・`userLen2`・`play`
- `Tremolo`はr8–r64 / c8–c64のみ。r128 / r256 / buzz rollは非対応（diagnostic有り）
- `TDuration`はwhole–256thのみ。long / breve / 512th / 1024thと4点付点が無い

### 5.3 構造・signature

- `BAR_LINE` — subtypeがtyped enumでなく生string。`spanStaff` / `spanFrom` / `spanTo`なし
- `TIMESIG` — `TimeSigType`（common / alla breve等）、text numerator / denominator、
  local stretch、beam group、括弧が落ちる。integer numerator / denominatorのみ
- `KEYSIG` — concert fifthsのみ。actual / transposing keyの区別、mode、custom key signature、
  `forInstrumentChange`が落ちる
- `LAYOUT_BREAK` — line / page / sectionの3 boolのみ。`NOBREAK`、pause、
  startWithLongNames、startWithMeasureOne、first system indentが落ちる
- `MEASURE` — noBreak、mm rest count、user stretch、measure number override / mode、
  per-staffのvisibility / stemless / hide-if-emptyが落ちる
- `STAFF` — 時間軸を持つStaffType / Clef / Key listが無い。visibility / cutaway /
  hideWhenEmpty / barline span / per-voice playbackが落ちる

### 5.4 instrument / playback

- `Instrument.id`が内部id・soundId・MusicXML idを1つに潰している（`MSCXDecoder+Instrument.swift:7`）
- channelはprogram / bank / volume / pan / chorus / reverb / port / channelのみ。
  CC 0 / 7 / 10 / 32 / 91 / 93以外を捨てる（`MSCXDecoder+InstrumentChannel.swift:30`）。
  名前付きMIDI action list、synth名 / color / user bankが無い
- drumsetはname / head / line / voice / stem / shortcutのみ。duration別notehead、
  variant（articulation / tremolo別のpitch差し替え）、panel座標が無い
- instrument articulationは`descr`が落ちる
- per-staff clef、trait、singleNoteDynamics、glissandoStyleがInstrumentに無い

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
3. **単独で追加できるMISSING** — `ORNAMENT`、`StringData`+`FRET_DIAGRAM`+`STRING_TUNINGS`+`CAPO`、
   `FIGURED_BASS`、`SYMBOL`/`FSYMBOL`、`SPACER`、`FINGERING`/`STICKING`/`EXPRESSION`。
   互いに独立なので並列に進められる。
4. **構造変更を伴うもの** — box family（`MeasureBase`相当の並びが要る）、
   `STAFFTYPE_CHANGE`（staffの時間軸）、そして最後に**excerpt / linked parts**。

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
