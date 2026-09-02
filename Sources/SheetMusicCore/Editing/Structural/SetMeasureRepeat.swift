import SheetMusicFoundation

/// Turns `numMeasures` consecutive empty bars of one staff into a measure-repeat group — the `%` sign in the first
/// bar, `measureRepeatCount = 1…n` across the group — or, with `nil`, dissolves the group that starts at `measure`
/// back into measure rests. Per staff, because that is what a measure repeat is (`Measure.measureRepeatCount` is
/// not part of `Measure.Flags`).
///
/// Only empty bars qualify: a bar with notes, a second voice, or one already inside a group is refused rather than
/// silently overwritten. A leading key / time signature is kept in front of the sign, and whatever trails the
/// bar's body — an end barline, a clef — is kept behind it.
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
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard score[staff] != nil else { throw Self.refused(.staffNotFound(staff)) }
        guard score.contains(measure) else { throw Self.refused(.targetNotFound(affectedLocation)) }
        if let restoredMeasures {
            let previous = try group(of: restoredMeasures.count, in: score)
            write(restoredMeasures, to: &score)
            return SetMeasureRepeat(restoring: previous, at: measure, staff: staff)
        }
        if let numMeasures {
            return try writeGroup(of: numMeasures, in: &score)
        }
        return try clearGroup(in: &score)
    }

    /// Writes the `%` sign into the first bar of the span and the group's continuation marks across the rest.
    private func writeGroup(of numMeasures: Int, in score: inout Score) throws -> any EditCommand {
        guard [1, 2, 4].contains(numMeasures) else {
            throw Self.refused(.invalidMeasureRepeatSpan(numMeasures: numMeasures))
        }
        let previous = try group(of: numMeasures, in: score)
        if let offset = previous.firstIndex(where: { !Self.isEmpty($0) }) {
            throw Self.refused(.measureRepeatSpanNotEmpty(measureIndex: measure.measureIndex + offset))
        }
        let rewritten = previous.enumerated().map { offset, bar -> Measure in
            var next = bar
            let (prefix, suffix) = Self.frame(of: bar.voices[0])
            let body: VoiceElement = offset == 0
                ? .measureRepeat(MeasureRepeat(numMeasures: numMeasures, duration: .measure))
                : .rest(duration: .measure)
            next.voices = [Voice(elements: prefix + [body] + suffix)]
            next.measureRepeatCount = offset + 1
            return next
        }
        write(rewritten, to: &score)
        return SetMeasureRepeat(restoring: previous, at: measure, staff: staff)
    }

    /// Dissolves the group that STARTS at `measure` back into measure rests, keeping each bar's leading signatures
    /// and whatever trails its body (a special end barline, a mid-score clef).
    private func clearGroup(in score: inout Score) throws -> any EditCommand {
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
            let (prefix, suffix) = Self.frame(of: bar.voices[0])
            next.voices = [Voice(elements: prefix + [.rest(duration: .measure)] + suffix)]
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

    /// The `%` sign a group's first bar carries, wherever in the voice it sits — a trailing barline can follow it.
    private static func measureRepeatSign(in voice: Voice) -> MeasureRepeat? {
        for element in voice.elements {
            if case let .measureRepeat(sign) = element { return sign }
        }
        return nil
    }

    /// What stays put around a bar's body when the `%` sign replaces it: the leading signature run, and
    /// everything after the last body element — a trailing barline, a clef at the end of the bar. Only the body
    /// (the chords and rests, or the sign standing in for them) is the command's to rewrite; dropping the rest
    /// of the voice is how a `SetBarLine` before a `SetMeasureRepeat` used to lose its barline.
    private static func frame(of voice: Voice) -> (prefix: [VoiceElement], suffix: [VoiceElement]) {
        let prefix = MeasureStructure.leadingSignaturePrefix(of: voice)
        guard let lastBody = voice.elements.lastIndex(where: isBody) else {
            return (prefix, Array(voice.elements.dropFirst(prefix.count)))
        }
        return (prefix, Array(voice.elements[(lastBody + 1)...]))
    }

    /// A timed element, or the `%` sign standing in for one — what the command's body slot holds.
    private static func isBody(_ element: VoiceElement) -> Bool {
        switch element {
        case .chord, .measureRepeat: true
        default: false
        }
    }

    /// One voice, no tuplets, no group membership, and a body of nothing but rests. Signatures and barlines
    /// count as empty only where `frame` keeps them — at the head and the tail; one BETWEEN two rests would be
    /// dropped by the rewrite, so a bar carrying one is refused instead.
    private static func isEmpty(_ bar: Measure) -> Bool {
        guard bar.voices.count == 1, bar.measureRepeatCount == nil, bar.voices[0].tuplets.isEmpty else {
            return false
        }
        let voice = bar.voices[0]
        let (prefix, suffix) = frame(of: voice)
        return voice.elements.dropFirst(prefix.count).dropLast(suffix.count).allSatisfy { element in
            if case let .chord(chord) = element { chord.notes.isEmpty } else { false }
        }
    }
}
