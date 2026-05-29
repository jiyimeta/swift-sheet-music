# MuseScore engraving reference

A navigation map for spelunking the upstream MuseScore C++ source
(<https://github.com/musescore/MuseScore>, GPL-3.0; not vendored here —
clone separately for reference). Lists **where to look** and **what
surprises to expect** for the topics we keep porting. All paths below
are relative to the MuseScore repository root. Specific constants
(sizes, magic numbers, defaults) intentionally aren't duplicated here
— `grep`, the `Sid::` / `Pid::` enums, and `engraving/style/styledef.cpp`
are the source of truth and they drift between MuseScore versions.


## Coordinate systems & units

MuseScore renders into a **high-DPI internal coordinate space**
(see `DPI` / `DPMM` / `INCH` constants in
`engraving/dom/mscore.h`). Public APIs (`pos()`, `bbox()`, layout
data) all work in those internal units, **not** typographic
points. Conversion happens only at I/O boundaries.

When porting positions to a 72-DPI surface (Core Graphics, Swift
typography), divide internal units by `DPI / 72`, or convert from
the original mm / spatium directly.

**Surprises:**

* "Point" in MuseScore-speak almost never means typographic point.
  It usually means an internal-DPI unit, *or* the
  `OffsetType::ABS` setting (which actually selects mm — see
  below).
* Math that looks right at default spatium can be off by ~5 % when
  the score declares a custom one. Reach for the score's spatium,
  not a hardcoded constant.


## Spatium

A spatium ("staff space") is the score's universal length unit.

* `<Spatium>` in `.mscx` is in **mm** (despite the name).
* `StaffMetrics.staffHeight = 4 × spatium`.
* The default music-symbol size is calibrated against the default
  spatium (`MUSICAL_SYMBOLS_DEFAULT_FONT_SIZE` in
  `engraving/dom/mscore.h`); a non-default spatium rescales every
  notation glyph proportionally.


## Offsets — `<offset>` and `OffsetType`

Each `EngravingItem` carries `m_offset: PointF`. Render time:

```cpp
PointF pos() const { return ldata()->pos() + m_offset; }
// engraving/dom/engravingitem.h
```

**`m_offset`'s unit is item-dependent.** It depends on the item's
`OffsetType` (`engraving/dom/mscore.h`):

| OffsetType | XML value interpreted as | Conversion at read |
|---|---|---|
| `ABS`     | **millimetres**     | `value × DPMM`    |
| `SPATIUM` | spatium multiples   | `value × spatium` |

The branch is in `engraving/rw/read460/tread.cpp`,
`case P_TYPE::POINT`. Same pattern in older readers
(`read400/read206/read114`).

`offsetIsSpatiumDependent()` decides which branch — defined per
item type. Most text-based styles default to `ABS`; placement
adjustments default to `SPATIUM`. Check the item's overrides
before assuming.

**Surprises:**

* `ABS` means **mm**, not typographic points and not internal
  DPI units. This trips up everyone the first time. A Composer
  offset of `-70` is **-70 mm** (~16× larger than -70 points).
* The same value flows through both code paths — a `<offset>`
  written by one MuseScore version may be re-read with a
  different `offsetIsSpatiumDependent()` answer if the item's
  default changed across versions. Inspect with both readings if
  the result looks half a page off.
* `styledef.cpp` defaults are `PointF` literals; they go through
  the same `OffsetType` conversion as user-overridden values.
  Don't pretend the defaults are in points.


## Frames (`<VBox>` / `<HBox>` / `<TBox>`)

Frames live INSIDE a `<Staff>` (typically staff 0) as siblings of
`<Measure>`. They reserve vertical space and host `<Text>`
children (title block, section headers, etc.).

* `<height>` is in **spatium units**; `absoluteFromSpatium()` does
  the conversion (see `engraving/rendering/score/boxlayout.cpp`).
* `<boxAutoSize>` (1 / 0) toggles between "grow to fit text" and
  "honor the declared height".

**Surprises:**

* A frame near the top of the score is usually a title block, but
  MuseScore allows frames anywhere between measures (section
  dividers etc.). Don't assume "first frame = title block".
* Frame text positioning is computed in
  `engraving/rendering/score/textlayout.cpp::layoutBaseTextBase1`
  via `AlignV` (`TOP / BOTTOM / VCENTER / BASELINE`). The bbox-
  based math interacts subtly with each style's default offset —
  if porting a layout case, read this function before guessing.


## Title-block text styles

Title / Subtitle / Composer / Lyricist defaults: search
`engraving/style/styledef.cpp` for `titleAlign` /
`subTitleAlign` / `composerAlign` / `lyricistAlign` (and the
parallel `*FontSize`, `*Offset`, `*OffsetType` lines). Each
`styleDef(...)` line is one default.

**Surprises:**

* Each style has independent vertical anchors — they're NOT all
  pinned to the top with stacked offsets. Composer / Lyricist
  default to `BOTTOM` of the VBox.
* Default font is `Edwin` (bundled with MuseScore). System fonts
  have different ascent/descent, so a port that uses
  `system(.regular)` will not pixel-match MuseScore even at the
  same nominal point size.
* Inline `<b>` / `<font>` markup inside `<text>` overrides per
  fragment. We currently strip it; un-stripping requires a
  structured representation rather than a flat `String`.


## XML read paths (compat tiers)

MuseScore keeps separate readers for each historical format
generation. They share property-conversion logic but diverge in
subtle item-specific handling.

| Reader | Targets format |
|--------|----------------|
| `engraving/rw/read460/` | MuseScore 4.6+ (current) |
| `engraving/rw/read400/` | MuseScore 4.0 – 4.5 |
| `engraving/rw/read302/` | MuseScore 3.x |
| `engraving/rw/read206/` | MuseScore 2.x |
| `engraving/rw/read114/` | MuseScore 1.x / 0.9 |

Check `<programVersion>` at the top of an `.mscx` to predict which
reader MuseScore would use. Our parser doesn't branch on this — we
follow the read460 conventions and accept that older files may
have minor encoding differences. When something round-trips badly,
diff the relevant `case` against `read400` / `read206` first.


## Where to look next

* **Tempo / metronome:** `engraving/playback/playbackeventsrenderer.cpp`
  (`renderMetronome`). The simple-vs-compound branching there is
  the canonical reference for "what should beat positions look
  like" in a given time signature.
* **System / measure layout:** `engraving/rendering/score/systemlayout.cpp`,
  `boxlayout.cpp`, `tlayout.cpp`. Start at `tlayout.cpp` to find
  the entry point for a specific item.
* **Style defaults:** `engraving/style/styledef.cpp`. Every
  `styleDef(...)` line is a default value; the symbolic `Sid::*`
  IDs cross-reference into `styledef.h`.
* **Property serialization:** `engraving/dom/property.cpp`
  (`propertyToString`) and `engraving/rw/read460/tread.cpp`
  (`readProperty`) — the canonical XML round-trip with the
  unit-conversion table embedded in the `case P_TYPE::*` switch.
