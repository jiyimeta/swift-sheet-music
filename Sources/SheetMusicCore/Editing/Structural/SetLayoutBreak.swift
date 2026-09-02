import SheetMusicFoundation

/// `<LayoutBreak>` subtypes an edit can toggle. Raw values are the wire bytes (`SetLayoutBreakIntentWire.kind`);
/// zero is deliberately unassigned so a zeroed payload decodes to a refusal rather than to a line break.
public enum LayoutBreakKind: UInt8, Sendable, CaseIterable {
    case line = 1
    case page = 2
    case section = 3
}

/// Sets or clears one layout-break flag on one measure column. The flag lives on the canonical staff's measure
/// (`Score.canonicalStaff`; `LayoutEngine.measureForcesLineBreak` reads `staves.first`). A page break does not
/// also set `lineBreak` — the layout already treats a page break as implying a system break.
public struct SetLayoutBreak: EditCommand {
    public let measure: MeasureRef
    public let kind: LayoutBreakKind
    public let enabled: Bool

    public init(at measure: MeasureRef, kind: LayoutBreakKind, enabled: Bool) {
        self.measure = measure
        self.kind = kind
        self.enabled = enabled
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(staff: Score.canonicalStaff, measureIndex: measure.measureIndex, voiceIndex: 0, elementIndex: 0)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard var target = score[measure: measure, staff: Score.canonicalStaff] else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        let keyPath: WritableKeyPath<Measure, Bool> = switch kind {
        case .line: \.lineBreak
        case .page: \.pageBreak
        case .section: \.sectionBreak
        }
        let inverse = SetLayoutBreak(at: measure, kind: kind, enabled: target[keyPath: keyPath])
        target[keyPath: keyPath] = enabled
        score[measure: measure, staff: Score.canonicalStaff] = target
        return inverse
    }
}
