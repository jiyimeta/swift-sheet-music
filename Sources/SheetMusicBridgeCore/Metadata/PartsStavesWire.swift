import SheetMusicCore
import SheetMusicFoundation
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
    /// MuseScore `<Part><show>` — 0 when the file authored this part as hidden
    /// (`<show>0</show>`), 1 when shown. The Android Reader seeds authored-hidden
    /// parts' staves into its hidden-staff set, mirroring iOS.
    public var isVisibleInScore: UInt8 // 0/1
}

/// Descriptor for one staff in the display inspector.
@WireFormat
public struct StaffWire {
    /// The staff's authored/default clef rawType (e.g. "G", "F", "PERC"), or "" when none.
    public var defaultClefRawType: String
    /// 1 when the file hides this staff in the score — by its own `<isStaffVisible>0` or by its part's `<show>0` —
    /// that is, when `Score.authoredHiddenStaffAddresses` holds it; 0 otherwise. The host seeds these into its
    /// hidden-staff set as they are, so the rule that combines the two flags is only ever the Swift one.
    public var isAuthoredHidden: UInt8 // 0/1
}

extension PartsStavesWire {
    /// Derives the descriptor from a decoded `Score`, using the canonical
    /// `Score.staffDisplayName(at:)` helper for iOS/Android name parity:
    /// instrument long name → track name → "Staff N" fallback, with empty
    /// strings treated as absent.
    public init(score: Score) {
        let authoredHidden = score.authoredHiddenStaffAddresses
        parts = score.parts.enumerated().map { partIndex, part in
            PartWire(
                name: score.staffDisplayName(at: StaffAddress(partIndex: partIndex, staffIndexInPart: 0)),
                staves: part.staves.indices.map { staffIndex in
                    let address = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
                    return StaffWire(
                        defaultClefRawType: score.authoredClef(at: address) ?? "",
                        isAuthoredHidden: authoredHidden.contains(address) ? 1 : 0,
                    )
                },
                isVisibleInScore: part.isVisibleInScore ? 1 : 0,
            )
        }
    }
}
