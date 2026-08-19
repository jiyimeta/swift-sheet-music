import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout
import Wirelet

/// Display settings passed from the Android Reader to the layout bridge across JNI.
/// Self-contained (no cross-directory @WireFormat references) so the SheetMusicAndroid
/// wirelet codegen can emit its Kotlin model + codec from this file alone.
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
    public var showsLyrics: UInt8
}

@WireFormat
public struct HiddenStaffWire {
    public var partIndex: Int32
    public var staffIndexInPart: Int32
}

@WireFormat
public struct ClefOverrideWire {
    public var partIndex: Int32
    public var staffIndexInPart: Int32
    public var rawType: String
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
