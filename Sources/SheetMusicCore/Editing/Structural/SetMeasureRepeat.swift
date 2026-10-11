import SheetMusicFoundation

/// Turns `numMeasures` consecutive bars of one staff into a measure-repeat group — the `%` sign in the first bar,
/// `measureRepeatCount = 1…n` across the group — or, with `nil`, dissolves the group that starts at `measure` back
/// into measure rests. Per staff, because that is what a measure repeat is (`Measure.measureRepeatCount` is not part
/// of `Measure.Flags`).
///
/// **The sign replaces the bar's music**, as MuseScore's `makeMeasureRepeatGroup` does (MuseScore asks first; this
/// command leaves the asking to the host, and its inverse brings every bar back whole). What goes is what a delete of
/// the whole bar takes: every note and rest — voice 1's become the sign (or, past the first bar, a measure rest),
/// tuplets with them — and the upper voices outright. What stays is what that delete keeps: everything in voice 1
/// that is not a note or a rest — a key / time signature, a clef, a barline, an annotation — in its order, with the
/// sign standing where the first note or rest stood.
///
/// Refused: a bar already inside a group, and a bar whose upper voice holds anything but notes and rests — a measure
/// repeat is ONE voice, and an annotation up there would have nowhere to go.
///
/// The inverse carries the group's bars whole (`restoring:`), the `SetRehearsalMark(restoringLane:)` idiom.
public struct SetMeasureRepeat: EditCommand {
    public let measure: MeasureRef
    public let staff: StaffAddress
    /// 1, 2 or 4 to write a group of that length; `nil` to clear the group starting here.
    public let numMeasures: Int?
    let restoredMeasures: [Measure]?

    public init(at measure: MeasureRef, staff: StaffAddress, numMeasures: Int?) {
        self.measure = measure
        self.staff = staff
        self.numMeasures = numMeasures
        restoredMeasures = nil
    }

    init(restoring measures: [Measure], at measure: MeasureRef, staff: StaffAddress) {
        self.measure = measure
        self.staff = staff
        numMeasures = nil
        restoredMeasures = measures
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure.measureIndex, voiceIndex: 0, elementIndex: 0)
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard score[staff] != nil else { throw Self.refused(.staffNotFound(staff)) }
        guard score.contains(measure) else { throw Self.refused(.targetNotFound(affectedLocation)) }
        if let restoredMeasures {
            let previous = try group(of: restoredMeasures.count, in: score)
            write(restoredMeasures, to: &score)
            return SetMeasureRepeat(restoring: previous, at: measure, staff: staff)
        }
        if let numMeasures {
            return try writeGroup(of: numMeasures, in: &score, ids: &ids)
        }
        return try clearGroup(in: &score, ids: &ids)
    }

    /// Writes the `%` sign into the first bar of the span and the group's continuation marks across the rest.
    private func writeGroup(
        of numMeasures: Int, in score: inout Score, ids: inout EIDAllocator,
    ) throws -> any EditCommand {
        guard [1, 2, 4].contains(numMeasures) else {
            throw Self.refused(.invalidMeasureRepeatSpan(numMeasures: numMeasures))
        }
        let previous = try group(of: numMeasures, in: score)
        if let offset = previous.firstIndex(where: { !Self.canTakeSign($0) }) {
            throw Self.refused(.measureRepeatSpanNotEmpty(measureIndex: measure.measureIndex + offset))
        }
        let rewritten = previous.enumerated().map { offset, bar -> Measure in
            var next = bar
            let body: VoiceElement = offset == 0
                ? .measureRepeat(MeasureRepeat(numMeasures: numMeasures, duration: .measure))
                : .rest(duration: .measure)
            next.voices = [Self.rebuiltVoice(bar.voices[0], body: body, ids: &ids)]
            next.measureRepeatCount = offset + 1
            return next
        }
        write(rewritten, to: &score)
        return SetMeasureRepeat(restoring: previous, at: measure, staff: staff)
    }

    /// Dissolves the group that STARTS at `measure` back into measure rests, keeping each bar's leading signatures
    /// and whatever trails its body (a special end barline, a mid-score clef).
    private func clearGroup(in score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let first = score[measure: measure, staff: staff], first.measureRepeatCount == 1,
              let sign = groupSign(in: score)
        else { throw Self.refused(.targetNotFound(affectedLocation)) }
        let previous = try group(of: sign.numMeasures, in: score)
        // A continuation bar with no voice at all is constructible; refuse it rather than index into nothing.
        if let offset = previous.firstIndex(where: { $0.voices.isEmpty }) {
            throw Self.refused(.measureRepeatSpanNotEmpty(measureIndex: measure.measureIndex + offset))
        }
        let cleared = previous.map { bar -> Measure in
            var next = bar
            next.voices = [Self.rebuiltVoice(bar.voices[0], body: .rest(duration: .measure), ids: &ids)]
            next.measureRepeatCount = nil
            return next
        }
        write(cleared, to: &score)
        return SetMeasureRepeat(restoring: previous, at: measure, staff: staff)
    }

    /// The `%` sign of the group starting at `measure`, searched across EVERY bar of the group rather than only
    /// its first: MuseScore anchors the sign in the middle of the group — bar 2 of a 4-bar one
    /// (`src/engraving/dom/measurerepeat.cpp`) — so a MuseScore-authored group has nothing in bar 1 to find.
    /// Writing still anchors in bar 1, which this reads back just as well. Bounded by the contiguous
    /// `measureRepeatCount = 1…n` run, so it can never walk out of the group.
    private func groupSign(in score: Score) -> MeasureRepeat? {
        var offset = 0
        while let bar = score[measure: MeasureRef(measureIndex: measure.measureIndex + offset), staff: staff],
              bar.measureRepeatCount == offset + 1
        {
            if let sign = bar.voices.first.flatMap(Self.measureRepeatSign) { return sign }
            offset += 1
        }
        return nil
    }

    private func group(of count: Int, in score: Score) throws -> [Measure] {
        var bars: [Measure] = []
        for offset in 0 ..< count {
            let ref = MeasureRef(measureIndex: measure.measureIndex + offset)
            guard let bar = score[measure: ref, staff: staff] else {
                throw Self.refused(.invalidMeasureRepeatSpan(numMeasures: count))
            }
            bars.append(bar)
        }
        return bars
    }

    private func write(_ bars: [Measure], to score: inout Score) {
        for (offset, bar) in bars.enumerated() {
            score[measure: MeasureRef(measureIndex: measure.measureIndex + offset), staff: staff] = bar
        }
    }

    /// `voice` with its timed run collapsed into the one `body` — the sign, or a measure rest — standing where the
    /// run's first element stood, and every other element kept, in order. A rest written over a rest keeps that
    /// rest's identifier. A voice with no timed element at all (constructible) takes `body` after its leading
    /// signatures. Tuplets go: the run they bracketed is one slot long now.
    private static func rebuiltVoice(_ voice: Voice, body: VoiceElement, ids: inout EIDAllocator) -> Voice {
        var pairs: [(EID, VoiceElement)] = []
        var placed = false
        for (index, element) in voice.elements.enumerated() {
            guard isBody(element) else {
                pairs.append((voice.elements.eid(at: index), element))
                continue
            }
            guard !placed else { continue }
            placed = true
            pairs.append((body.isRest && element.isRest ? voice.elements.eid(at: index) : ids.next(), body))
        }
        if !placed {
            let prefix = MeasureStructure.leadingSignaturePrefix(of: voice).values.count
            pairs.insert((ids.next(), body), at: prefix)
        }
        return Voice(elements: IdentifiedArray(pairs))
    }

    /// The `%` sign a group's first bar carries, wherever in the voice it sits — a trailing barline can follow it.
    private static func measureRepeatSign(in voice: Voice) -> MeasureRepeat? {
        for element in voice.elements {
            if case let .measureRepeat(sign) = element { return sign }
        }
        return nil
    }

    /// A timed element, or the `%` sign standing in for one — what the command's body slot holds. Only the body is
    /// the command's to rewrite; dropping the rest of the voice is how a `SetBarLine` before a `SetMeasureRepeat`
    /// used to lose its barline.
    private static func isBody(_ element: VoiceElement) -> Bool {
        switch element {
        case .chord, .measureRepeat: true
        default: false
        }
    }

    /// Not already in a group, and every voice above the first holding nothing but notes and rests — the voices
    /// the sign replaces outright, since a measure repeat is one voice.
    private static func canTakeSign(_ bar: Measure) -> Bool {
        guard bar.measureRepeatCount == nil, !bar.voices.isEmpty else { return false }
        return bar.voices.dropFirst().allSatisfy { voice in
            voice.elements.allSatisfy { element in
                if case .chord = element { true } else { false }
            }
        }
    }
}
