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
    /// Derives the descriptor from a decoded `Score`. Mirrors the display-name
    /// priority used by `Score.staffDisplayName(at:)` and `LayoutEngine`:
    /// `instrument.longName ?? part.trackName ?? ""`.
    public init(score: Score) {
        parts = score.parts.map { part in
            PartWire(
                name: part.instrument.longName ?? part.trackName ?? "",
                staves: part.staves.map { staff in
                    StaffWire(defaultClefRawType: staff.defaultClefType ?? "")
                },
            )
        }
    }
}
