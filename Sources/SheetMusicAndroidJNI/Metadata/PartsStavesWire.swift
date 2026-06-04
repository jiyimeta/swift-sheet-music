import Foundation
import SheetMusicCore
import Wirelet

/// Per-part / per-staff descriptor for the Android Reader's display-inspector Parts section.
@WireFormat
public struct PartsStavesWire {
    public var parts: [PartWire]
}

/// Descriptor for one part in the display inspector.
@WireFormat
public struct PartWire {
    public var name: String
    public var staves: [StaffWire]
}

/// Descriptor for one staff in the display inspector.
@WireFormat
public struct StaffWire {
    /// The staff's authored/default clef rawType (e.g. "G", "F", "PERC"), or "" when none.
    public var defaultClefRawType: String
}

extension PartsStavesWire {
    /// Derives the descriptor from a decoded `Score`, using the canonical
    /// `Score.staffDisplayName(at:)` helper for iOS/Android name parity:
    /// instrument long name → track name → "Staff N" fallback, with empty
    /// strings treated as absent.
    public init(score: Score) {
        parts = score.parts.enumerated().map { partIndex, part in
            PartWire(
                name: score.staffDisplayName(at: StaffAddress(partIndex: partIndex, staffIndexInPart: 0)),
                staves: part.staves.map { staff in
                    StaffWire(defaultClefRawType: staff.defaultClefType ?? "")
                },
            )
        }
    }
}
