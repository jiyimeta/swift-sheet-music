import SheetMusicFoundation

/// Per-measure container for elements that apply to the whole
/// system at a given measure position (tempo, rehearsal mark,
/// system text, swing). Lives at `Score.systemMeasures` and is
/// positionally aligned with the measure index across all staves.
///
/// Kept deliberately small: only the system-level *elements*
/// migrate here in the initial refactor. System-level *measure
/// flags* (start/end repeats, markers, jumps, line/page break,
/// actual length, irregular) still live on per-staff `Measure`
/// as of this commit; see the follow-up tracking issue.
public struct SystemMeasure: Sendable, Equatable {
    public var elements: [PositionedSystemElement]

    public init(elements: [PositionedSystemElement] = []) {
        self.elements = elements
    }
}

/// A `SystemElement` paired with its `MeasurePosition` inside the
/// containing `SystemMeasure`. Stored in document order.
///
/// `originalStaff` records the staff this element was attached to
/// in the source. It's `nil` for system-flagged elements (Tempo,
/// RehearsalMark, system-flagged StaffText/Swing) — those don't
/// belong to a particular staff and the renderer typically places
/// them above the topmost visible staff. It's `.some(addr)` for
/// staff-bound text (`pizz.`, `con sord.`, staff-flagged Swing) so
/// the renderer can place it above the originating staff.
public struct PositionedSystemElement: Sendable, Equatable {
    public var position: MeasurePosition
    public var element: SystemElement
    public var originalStaff: StaffAddress?

    public init(
        position: MeasurePosition,
        element: SystemElement,
        originalStaff: StaffAddress? = nil,
    ) {
        self.position = position
        self.element = element
        self.originalStaff = originalStaff
    }
}
