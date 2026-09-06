import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout
import Wirelet

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
@WireFormat
public struct LayoutOptionsWire {
    public var layoutMode: UInt8 // 0 = vertical, 1 = horizontal, 2 = page
    public var staffSize: Double
    public var honorLayoutBreaks: UInt8 // 0/1
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

    /// `0` defers to `honorLayoutBreaks`; `1` = `.honor`, `2` = `.ignoreSystemBreaks`,
    /// `3` = `.ignoreAll`.
    ///
    /// The deferral is why `0` is not `.honor`: `honorLayoutBreaks` is a boolean, and a host that
    /// sends `honorLayoutBreaks = 0` today means `.ignoreAll`. Making `0` here mean `.honor` would
    /// silently flip that host's layout the moment this field shipped.
    ///
    /// `.ignoreSystemBreaks` — ignore `<LayoutBreak>line` but still honor `page` — had no
    /// representation at all in the boolean, which is the gap this field closes.
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

    // swiftlint:disable:next function_default_parameter_at_end
    public init(
        layoutMode: UInt8,
        staffSize: Double,
        honorLayoutBreaks: UInt8,
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
    ) {
        self.layoutMode = layoutMode
        self.staffSize = staffSize
        self.honorLayoutBreaks = honorLayoutBreaks
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

    /// How to consume authored `<LayoutBreak>` markup.
    ///
    /// `breakPolicyRaw == 0` means the host has not spoken, so the older boolean answers — that
    /// deferral is what keeps a host built before this field from having its layout flipped.
    public var breakPolicy: LayoutBreakPolicy {
        switch breakPolicyRaw {
        case 1: .honor
        case 2: .ignoreSystemBreaks
        case 3: .ignoreAll
        default: honorLayoutBreaks == 1 ? .honor : .ignoreAll
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

    /// Default for the legacy no-options LayoutBridge.compute path + tests.
    public static var verticalDefault: LayoutOptionsWire {
        LayoutOptionsWire(
            layoutMode: 0, staffSize: 28,
            honorLayoutBreaks: 1, collapseMultiMeasureRests: 0, showsInvisibleElements: 0,
            hiddenStaves: [], clefOverrides: [], transposeSemitones: 0, showsLyrics: 1,
        )
    }
}

public enum LayoutOptionsCodec {
    public static func decode(_ data: Data) throws -> LayoutOptionsWire {
        try LayoutOptionsWire(decoding: data)
    }
}
