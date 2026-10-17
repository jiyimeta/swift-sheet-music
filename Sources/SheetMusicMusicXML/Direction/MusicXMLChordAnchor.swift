import SheetMusicCore
import SheetMusicFoundation

/// Where a chord or rest sits in its measure by the clock: its `<duration>` window, `start` being `mTime` before the
/// note and `end` after it (`P2:2851-2853`). `elementIndex` is its index in the voice's element array.
struct MusicXMLChordAnchor: Sendable, Equatable {
    let elementIndex: Int
    let start: Fraction
    let end: Fraction
}

/// A voice element waiting to be spliced in at an absolute tick of its measure.
struct MusicXMLQueuedElement: Sendable, Equatable {
    let tick: Fraction
    let element: VoiceElement
}
