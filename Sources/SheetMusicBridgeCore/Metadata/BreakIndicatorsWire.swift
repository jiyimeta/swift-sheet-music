import SheetMusicFoundation
import Wirelet

/// One break-indicator badge crossing the JNI boundary.
///
/// `kind`: 0 = line break, 1 = page break. An explicit numbering rather than a generated enum
/// because this payload is read by a Compose overlay that switches on it to pick an icon, and a
/// silent renumber there would swap the two icons rather than fail.
///
/// `xMm` / `yMm` are the badge's CENTRE in document millimetres — the same space every other
/// geometry entry point uses, so a host places it with the transform it already has.
@WireFormat
public struct BreakIndicatorWire: Equatable {
    public let kind: Int32
    public let xMm: Double
    public let yMm: Double

    public init(kind: Int32, xMm: Double, yMm: Double) {
        self.kind = kind
        self.xMm = xMm
        self.yMm = yMm
    }
}

/// Every badge for a laid-out score.
///
/// A list rather than a draw program, unlike the sticky header: the badge is drawn at a FIXED size
/// and deliberately does not scale with the staff — it is an authoring hint about the file, not
/// notation, and a hint that shrinks with the music becomes unreadable exactly when the score is
/// zoomed out to look at its breaks. A draw program carries staff-scaled geometry, so it is the
/// wrong shape for this; positions plus a kind is the right one, and the host draws the badge in
/// its own idiom (SF Symbols on Apple, a Compose shape on Android).
@WireFormat
public struct BreakIndicatorsWire: Equatable {
    public let indicators: [BreakIndicatorWire]

    public init(indicators: [BreakIndicatorWire]) {
        self.indicators = indicators
    }
}
