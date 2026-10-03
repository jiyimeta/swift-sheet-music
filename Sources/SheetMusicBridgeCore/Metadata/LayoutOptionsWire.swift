import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout
import Wirelet

/// Optional engraving-spacing overrides carried by `LayoutOptionsWire`.
///
/// These fields use `nil` for "unspecified", unlike the scalar sentinels on
/// `LayoutOptionsWire`. An absent non-optional wire field throws
/// `WireFormatError.unknownTag`, while a nested struct default such as
/// `.init()` cannot be translated by the Kotlin emitter. Making the nested
/// struct and its fields optional preserves old blobs, lets generated Kotlin
/// use `null`, and keeps a real `minNoteDistance` value of `0` unambiguous.
@WireFormat
public struct EngravingSpacingWire {
    public var minNoteDistance: Double?
    public var spacePerQuarter: Double?
    public var systemStretch: Double?
    public var marginTop: Double?
    public var marginLeading: Double?
    public var marginBottom: Double?
    public var marginTrailing: Double?
    public var firstSystemIndent: Double?
    public var continuationSystemIndent: Double?
    public var minStaffGap: Double?
    public var systemVerticalPadding: Double?

    public init(
        minNoteDistance: Double? = nil,
        spacePerQuarter: Double? = nil,
        systemStretch: Double? = nil,
        marginTop: Double? = nil,
        marginLeading: Double? = nil,
        marginBottom: Double? = nil,
        marginTrailing: Double? = nil,
        firstSystemIndent: Double? = nil,
        continuationSystemIndent: Double? = nil,
        minStaffGap: Double? = nil,
        systemVerticalPadding: Double? = nil,
    ) {
        self.minNoteDistance = minNoteDistance
        self.spacePerQuarter = spacePerQuarter
        self.systemStretch = systemStretch
        self.marginTop = marginTop
        self.marginLeading = marginLeading
        self.marginBottom = marginBottom
        self.marginTrailing = marginTrailing
        self.firstSystemIndent = firstSystemIndent
        self.continuationSystemIndent = continuationSystemIndent
        self.minStaffGap = minStaffGap
        self.systemVerticalPadding = systemVerticalPadding
    }
}

/// Display settings passed from the Android Reader to the layout bridge across JNI.
/// Self-contained (no cross-directory @WireFormat references) so the SheetMusicAndroid
/// wirelet codegen can emit its Kotlin model + codec from this file alone.
///
/// **`ScoreViewOptions.fixedLayoutWidth` deliberately has no counterpart here.**
/// It exists because `ScoreView` measures its own container with a
/// `GeometryReader` and re-wraps as that container resizes; the option turns
/// that following off. This bridge never measures anything — the host passes
/// `pageWidthMM` to `LayoutBridge.encode` and that *is* the wrap width — so a
/// portable host already has the behaviour the option buys on Apple, by
/// passing a width it chose. Adding the field would only give the same number
/// a second way in.
///
/// **Tag 3 is retired.** It carried a `0`/`1` break boolean until 4.0.0, when `breakPolicyRaw` became the only
/// break field. Reserving it keeps every later field on the tag it has always had — the implicit tags are assigned in
/// declaration order, skipping reserved ones — and stops a future field from reading an old host's boolean as its
/// own value. A blob that still carries tag 3 decodes; the reader skips it as an unknown field.
@WireFormat(reservedTags: [3])
public struct LayoutOptionsWire {
    public var layoutMode: UInt8 // 0 = vertical, 1 = horizontal, 2 = page
    public var staffSize: Double
    public var collapseMultiMeasureRests: UInt8 // 0/1
    public var showsInvisibleElements: UInt8 // 0/1
    public var hiddenStaves: [HiddenStaffWire]
    public var clefOverrides: [ClefOverrideWire]
    /// Whole-score notation transposition in semitones, clamped to −12…+12 by `transposeDelta`. `0` = concert pitch.
    ///
    /// Rides on the display options rather than on its own bridge because it is exactly that: a re-spelling of the
    /// score before layout, which the host already re-runs whenever these options change. Note IDs and ticks survive
    /// `Score.transposed(bySemitones:)`, so cursor lookups against the resulting document are unaffected.
    ///
    /// This is the NOTATION half only. Transposed *playback* is a tuning shift on the melodic channels
    /// (`AndroidPlaybackEngine.setTranspose`), never a re-render — matching the Apple engine.
    public var transposeSemitones: Int32
    /// Whether sung text is engraved at all. `0` hides it, anything else shows it — a host that
    /// omitted the field would otherwise hide lyrics by accident, and showing them is the behaviour
    /// every release before this one had.
    ///
    /// Hiding is a display choice, not MuseScore's per-element `visible` flag: the whole row goes,
    /// including the hyphens and the melisma rules, and `showsInvisibleElements` does not bring it
    /// back. The engraved document is genuinely SHORTER as a result, which is what a host reserving
    /// a fixed-height notation strip depends on.
    ///
    /// The default is what makes this an APPENDED field rather than a breaking one: the Kotlin
    /// emitter carries it into the generated `data class`, so a host built before this field
    /// existed still compiles and still gets the behaviour it had. Without it the generated
    /// constructor gains a required parameter and every Kotlin host breaks at the source level,
    /// even though the wire itself stayed readable.
    public var showsLyrics: UInt8 = 1

    // MARK: - The rest of ScoreViewOptions
    //
    // Everything below reaches `ScoreViewOptions` too, and every one of them defaults to the value
    // `LayoutBridge` hard-coded before this wire carried it. That is the whole compatibility story:
    // a host that sends the old blob gets the old layout, byte for byte.
    //
    // Each uses a sentinel for "I have no opinion" rather than the engine's literal default, so the
    // default only ever lives in one place — `ScoreViewOptions` — and a change there is not silently
    // pinned to an old value by this file.

    /// `0` = no opinion (`.honor`, `ScoreViewOptions`' own default); `1` = `.honor`, `2` = `.ignoreSystemBreaks`
    /// (ignore `<LayoutBreak>line` but still honor `page`), `3` = `.ignoreAll`. Any other value reads as `0`.
    ///
    /// Read it through `breakPolicy`, never by comparing raw values: every entry point that lays out or paginates
    /// has to agree on the policy, or the page boundaries a host is told about stop matching the pages it draws.
    public var breakPolicyRaw: UInt8 = 0

    /// Minimum consecutive rest measures before they collapse into one H-bar. Values below `2` are
    /// treated as `2`, which is also what `LayoutPaginator` does with them, so this clamps in the
    /// same direction rather than adding a second rule.
    ///
    /// Only consulted when `collapseMultiMeasureRests` is `1`.
    public var multiMeasureRestMinimum: Int32 = 2

    /// `0` = a label at each system head only; `n > 0` = additionally every `n`-th measure.
    ///
    /// Additive rather than exclusive, matching `MeasureNumberPolicy.interval`: turning the interval
    /// up never takes away a label the reader could already see.
    public var measureNumberInterval: Int32 = 0

    /// Vertical gap between systems in points. `0` keeps the bridge's derived `staffSize * 1.25`.
    ///
    /// Derived rather than `ScoreViewOptions`'s own fixed 40 pt because a gap that does not scale
    /// with the staff looks wrong at both ends of the staff-size range, and Android hosts have had
    /// the derived one since the first release.
    public var systemGapPoints: Double = 0

    /// `2` = decide from the layout mode (horizontal off, others on) as the bridge always has;
    /// `0` = never reserve the title block; `1` = always.
    public var includeTitleFrameRaw: UInt8 = 2

    /// `0` = draw no break-indicator badges, `1` = page breaks only, `2` = all.
    ///
    /// `0` is the default because it is what the bridge hard-coded. NOTE: this reaches
    /// `ScoreViewOptions` but has no effect on the draw program yet — the badges are an overlay the
    /// Apple renderer draws over the score (`BreakIndicatorOverlay`), not a `LayoutElement`, so a
    /// Compose overlay has to exist before a non-zero value here shows anything.
    public var breakIndicatorVisibilityRaw: UInt8 = 0

    /// Scale factor for grace-note glyphs. `0` keeps `ScoreViewOptions`'s own default.
    public var graceNoteMag: Double = 0

    /// Scale factor for small / cue noteheads. `0` keeps `ScoreViewOptions`'s own default.
    public var smallNoteMag: Double = 0

    /// Optional engraving-spacing overrides. `nil` preserves the engine defaults.
    public var spacing: EngravingSpacingWire?

    /// Whether each transposing part is drawn at its WRITTEN pitch (the notes, key signatures and chord symbols a
    /// player of that instrument reads) instead of the concert pitch the score stores. `0`, the default, draws
    /// concert pitch, as every release before this field did. Anything else applies `Score.writtenPitchView()` after
    /// the clef overrides and before `transposeSemitones`, the order Apple hosts use.
    ///
    /// Opt-in rather than always on, because a host may apply the written view itself before handing the score over.
    /// A Windows host that runs its own display chain into `ScorePages` does, and applying the view twice moves a
    /// transposing part by its interval twice. Display only: the view never reaches playback or an encoder.
    ///
    /// Appended with a default for the same reason as `showsLyrics`: the generated Kotlin constructor keeps
    /// compiling for every host built before it.
    public var writtenPitch: UInt8 = 0

    // swiftlint:disable:next function_default_parameter_at_end
    public init(
        layoutMode: UInt8,
        staffSize: Double,
        collapseMultiMeasureRests: UInt8,
        showsInvisibleElements: UInt8,
        hiddenStaves: [HiddenStaffWire],
        clefOverrides: [ClefOverrideWire],
        transposeSemitones: Int32,
        showsLyrics: UInt8 = 1,
        breakPolicyRaw: UInt8 = 0,
        multiMeasureRestMinimum: Int32 = 2,
        measureNumberInterval: Int32 = 0,
        systemGapPoints: Double = 0,
        includeTitleFrameRaw: UInt8 = 2,
        breakIndicatorVisibilityRaw: UInt8 = 0,
        graceNoteMag: Double = 0,
        smallNoteMag: Double = 0,
        spacing: EngravingSpacingWire? = nil,
        writtenPitch: UInt8 = 0,
    ) {
        self.layoutMode = layoutMode
        self.staffSize = staffSize
        self.collapseMultiMeasureRests = collapseMultiMeasureRests
        self.showsInvisibleElements = showsInvisibleElements
        self.hiddenStaves = hiddenStaves
        self.clefOverrides = clefOverrides
        self.transposeSemitones = transposeSemitones
        self.showsLyrics = showsLyrics
        self.breakPolicyRaw = breakPolicyRaw
        self.multiMeasureRestMinimum = multiMeasureRestMinimum
        self.measureNumberInterval = measureNumberInterval
        self.systemGapPoints = systemGapPoints
        self.includeTitleFrameRaw = includeTitleFrameRaw
        self.breakIndicatorVisibilityRaw = breakIndicatorVisibilityRaw
        self.graceNoteMag = graceNoteMag
        self.smallNoteMag = smallNoteMag
        self.spacing = spacing
        self.writtenPitch = writtenPitch
    }
}

@WireFormat
public struct HiddenStaffWire {
    public var partIndex: Int32
    public var staffIndexInPart: Int32

    public init(partIndex: Int32, staffIndexInPart: Int32) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
    }
}

@WireFormat
public struct ClefOverrideWire {
    public var partIndex: Int32
    public var staffIndexInPart: Int32
    public var rawType: String

    public init(partIndex: Int32, staffIndexInPart: Int32, rawType: String) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.rawType = rawType
    }
}

extension LayoutOptionsWire {
    public enum Mode: UInt8 { case vertical = 0, horizontal = 1, page = 2 }
    public var mode: Mode {
        Mode(rawValue: layoutMode) ?? .vertical
    }

    public var hiddenStaffAddresses: Set<StaffAddress> {
        Set(hiddenStaves.map { StaffAddress(partIndex: Int($0.partIndex), staffIndexInPart: Int($0.staffIndexInPart)) })
    }

    public var clefOverrideMap: [StaffAddress: String] {
        Dictionary(uniqueKeysWithValues: clefOverrides.map {
            (StaffAddress(partIndex: Int($0.partIndex), staffIndexInPart: Int($0.staffIndexInPart)), $0.rawType)
        })
    }

    /// The transposition to apply, clamped to the range the engine supports (−12…+12, an octave either way — the
    /// same clamp the Apple `PlaybackEngine.setTranspose` and `AndroidPlaybackEngine.setTranspose` use). A wire
    /// value outside it is pinned rather than rejected, so a host that has not clamped can never produce an absurd
    /// re-spelling.
    ///
    /// THIS CLAMP AND THE TWO AUDIO ONES MOVE TOGETHER. This is the notation half; the audio half is a tuning
    /// shift on the melodic channels. Widening only the audio side leaves the score sounding transposed past the
    /// narrower bound while still LOOKING like the written key — which is the failure the three-way symmetry exists
    /// to prevent.
    public var transposeDelta: Int {
        max(-12, min(12, Int(transposeSemitones)))
    }

    /// Whether the engraver should lay lyrics out. Anything other than an explicit `0` shows them,
    /// so the safe direction for a host that has not been updated is the pre-existing behaviour.
    public var lyricsVisible: Bool {
        showsLyrics != 0
    }

    /// Whether the layout draws transposing parts at written pitch. Anything other than `0` turns it on.
    public var drawsWrittenPitch: Bool {
        writtenPitch != 0
    }

    /// How to consume authored `<LayoutBreak>` markup — the one resolution of `breakPolicyRaw`.
    ///
    /// Every bridge entry point reads this: the layout itself (`LayoutBridge`), the page boundaries
    /// (`nativePageBreaks`, wasm `pageBreaks`) and the break-indicator badges. A second reading anywhere is how
    /// those two page-boundary entry points once paginated by an older boolean while the layout drew by this
    /// policy, so `.ignoreSystemBreaks` could report one page where two were drawn.
    public var breakPolicy: LayoutBreakPolicy {
        switch breakPolicyRaw {
        case 2: .ignoreSystemBreaks
        case 3: .ignoreAll
        default: .honor
        }
    }

    /// Multi-measure-rest collapse policy.
    public var multiMeasureRestPolicy: MultiMeasureRestPolicy {
        guard collapseMultiMeasureRests == 1 else { return .disabled }
        return .collapse(minimumMeasures: max(2, Int(multiMeasureRestMinimum)))
    }

    /// How often a measure-number label is engraved.
    public var measureNumberPolicy: MeasureNumberPolicy {
        measureNumberInterval > 0 ? .interval(every: Int(measureNumberInterval)) : .systemStart
    }

    /// Which break-indicator badges an overlay should draw.
    public var breakIndicatorVisibility: BreakIndicatorVisibility {
        switch breakIndicatorVisibilityRaw {
        case 1: .pageOnly
        case 2: .all
        default: .none
        }
    }

    /// Vertical gap between systems in points, falling back to the staff-proportional default.
    public func systemGap(staffSize: Double) -> Double {
        systemGapPoints > 0 ? systemGapPoints : staffSize * 1.25
    }

    /// Whether to reserve the title block, given what the layout mode would have decided.
    ///
    /// `2` (the default) is "keep deciding from the mode", so a host that never sets this sees the
    /// behaviour it always had; `0` and `1` override in each direction.
    public func includesTitleFrame(modeDefault: Bool) -> Bool {
        switch includeTitleFrameRaw {
        case 0: false
        case 1: true
        default: modeDefault
        }
    }

    /// Engraving spacing with every omitted wire field restored from the engine default.
    public var engravingSpacing: EngravingSpacing {
        let standard = EngravingSpacing.standard
        return EngravingSpacing(
            minNoteDistance: CGFloat(spacing?.minNoteDistance ?? Double(standard.minNoteDistance)),
            spacePerQuarter: CGFloat(spacing?.spacePerQuarter ?? Double(standard.spacePerQuarter)),
            systemStretch: CGFloat(spacing?.systemStretch ?? Double(standard.systemStretch)),
            margins: EngravingMargins(
                top: CGFloat(spacing?.marginTop ?? Double(standard.margins.top)),
                leading: CGFloat(spacing?.marginLeading ?? Double(standard.margins.leading)),
                bottom: CGFloat(spacing?.marginBottom ?? Double(standard.margins.bottom)),
                trailing: CGFloat(spacing?.marginTrailing ?? Double(standard.margins.trailing)),
            ),
            firstSystemIndent: CGFloat(
                spacing?.firstSystemIndent ?? Double(standard.firstSystemIndent),
            ),
            continuationSystemIndent: CGFloat(
                spacing?.continuationSystemIndent ?? Double(standard.continuationSystemIndent),
            ),
            minStaffGap: CGFloat(spacing?.minStaffGap ?? Double(standard.minStaffGap)),
            systemVerticalPadding: CGFloat(
                spacing?.systemVerticalPadding ?? Double(standard.systemVerticalPadding),
            ),
        )
    }

    /// The options `LayoutBridge.compute(score:pageWidthMM:pageHeightMM:)` (the no-options path) lays out with, and
    /// the default wherever an options argument is optional.
    public static var verticalDefault: LayoutOptionsWire {
        LayoutOptionsWire(
            layoutMode: 0, staffSize: 28,
            collapseMultiMeasureRests: 0, showsInvisibleElements: 0,
            hiddenStaves: [], clefOverrides: [], transposeSemitones: 0, showsLyrics: 1,
        )
    }
}

public enum LayoutOptionsCodec {
    public static func decode(_ data: Data) throws -> LayoutOptionsWire {
        try LayoutOptionsWire(decoding: data)
    }
}
