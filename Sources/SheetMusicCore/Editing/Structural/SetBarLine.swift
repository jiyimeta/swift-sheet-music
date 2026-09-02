import SheetMusicFoundation

/// Writes the visible END barline of one measure column on every staff — the `.barLine` at or after the last timed
/// element of voice 0 — replacing the one already there, appending one where there is none, and for `.normal`
/// removing it. A mid-measure barline (rare; `LayoutEngine+Placement` positions one by tick) is never touched.
///
/// Every staff, because a barline spans the system: MuseScore's end-barline segment is written per staff and
/// `LayoutEngine+SystemBuild` takes the LAST `.barLine` it finds on each.
///
/// > Note: This command is sugar over `ReplaceVoiceElements` (× staff count) + `CompositeEditCommand`. It exists to
/// > give the operation a domain-meaningful name and to centralise the small bit of validation it performs;
/// > callers can equally well construct the equivalent Composite directly. See `docs/edit-commands.md`.
public struct SetBarLine: EditCommand {
    public let measure: MeasureRef
    public let style: BarLineStyle

    public init(at measure: MeasureRef, style: BarLineStyle) {
        self.measure = measure
        self.style = style
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(staff: Score.canonicalStaff, measureIndex: measure.measureIndex, voiceIndex: 0, elementIndex: 0)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard score.contains(measure) else { throw Self.refused(.targetNotFound(affectedLocation)) }
        var writes: [any EditCommand] = []
        for (address, _) in score.allStaves {
            let ref = VoiceRef(staff: address, measureIndex: measure.measureIndex, voiceIndex: 0)
            guard let voice = score[voice: ref] else { continue }
            var elements = voice.elements
            let trailingIndex = Self.trailingBarLineIndex(in: elements)
            switch (style, trailingIndex) {
            case let (.normal, index?):
                elements.remove(at: index)
            case (.normal, nil):
                continue
            case let (_, index?):
                elements[index] = .barLine(BarLine(subtype: style.rawValue))
            case (_, nil):
                elements.append(.barLine(BarLine(subtype: style.rawValue)))
            }
            writes.append(ReplaceVoiceElements(
                staff: address, measureIndex: measure.measureIndex, voiceIndex: 0,
                elements: elements, tuplets: voice.tuplets,
            ))
        }
        return try CompositeEditCommand(commands: writes, location: affectedLocation).apply(to: &score)
    }

    /// Index of the `.barLine` that follows the last chord or rest of `elements`, if any.
    static func trailingBarLineIndex(in elements: [VoiceElement]) -> Int? {
        let lastTimed = elements.lastIndex { if case .chord = $0 { true } else { false } } ?? -1
        return elements.indices.last { index in
            index > lastTimed && { if case .barLine = elements[index] { true } else { false } }()
        }
    }
}
