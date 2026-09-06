import SheetMusicFoundation

/// Plans one lyric-entry keystroke without owning editor state or a caret.
///
/// The syllabic repairs mirror MuseScore's `NotationInteraction::navigateToLyrics`,
/// `NotationInteraction::navigateToNextSyllable` and `NotationInteraction::addMelisma`. MuseScore can keep an
/// empty destination `Lyrics` object in its live editor; this stateless planner writes no such score entry. Instead,
/// a new syllable derives `.end` from a preceding `.begin` or `.middle`. That is the complement of
/// `LayoutEngine.connectsWithHyphen`, which draws a dash only from `.begin`/`.middle` to `.middle`/`.end`.
public enum LyricInputPlanner {
    /// What key ended the syllable the user just typed.
    public enum Terminator: Sendable, Equatable {
        /// Enter or Escape: commit without advancing.
        case none
        /// Space: the next chord starts a new word.
        case word
        /// Hyphen: the next chord continues this word.
        case syllable
        /// Underscore: hold this syllable over the next chord.
        case melisma
    }

    public struct Cursor: Sendable, Equatable, Hashable {
        public var location: VoiceElementID
        public var verse: Int

        public init(location: VoiceElementID, verse: Int) {
            self.location = location
            self.verse = verse
        }
    }

    public enum VerseDirection: Sendable {
        case next
        case previous
    }

    public struct Plan: Sendable {
        /// The edit to apply as one undo step, or `nil` when nothing changes.
        public let command: (any EditCommand)?
        /// Where the caret goes next; `nil` when there is no advance or the staff has no further chord.
        public let next: Cursor?
    }

    /// Plans the score mutation and cursor advance for one completed syllable.
    public static func plan(
        typing text: String,
        terminatedBy terminator: Terminator,
        at cursor: Cursor,
        in score: Score,
    ) -> Plan {
        let trimmed = text.trimmingWhitespaceAndNewlines()
        let current = lyric(at: cursor, in: score)
        let next = nextCursor(after: cursor, for: terminator, in: score)
        var commands: [any EditCommand] = []

        if trimmed.isEmpty {
            if current != nil {
                commands.append(SetLyric(at: cursor.location, verse: cursor.verse, text: nil))
                if let repair = precedingRepair(for: terminator, before: cursor, in: score) {
                    commands.insert(repair, at: 0)
                }
            } else if let repair = precedingRepair(for: terminator, before: cursor, in: score) {
                commands.append(repair)
            }
        } else if let write = writingCommand(
            text: trimmed,
            current: current,
            terminator: terminator,
            at: cursor,
            in: score,
        ) {
            commands.append(write)
        }

        if let next, let repair = destinationRepair(for: terminator, at: next, in: score) {
            commands.append(repair)
        }
        return Plan(command: bundled(commands, at: cursor.location), next: next)
    }

    public static func verseCursor(_ direction: VerseDirection, from cursor: Cursor) -> Cursor? {
        switch direction {
        case .next:
            Cursor(location: cursor.location, verse: cursor.verse + 1)
        case .previous:
            cursor.verse > 0 ? Cursor(location: cursor.location, verse: cursor.verse - 1) : nil
        }
    }

    public static func previousCursor(from cursor: Cursor, in score: Score) -> Cursor? {
        score.previousChord(before: cursor.location).map {
            Cursor(location: $0, verse: cursor.verse)
        }
    }

    /// The non-empty syllable at the cursor. Empty verse-padding entries are treated as absent.
    public static func lyric(at cursor: Cursor, in score: Score) -> Lyric? {
        guard let lyric = SetLyric.current(at: cursor.location, verse: cursor.verse, in: score),
              !lyric.text.isEmpty
        else { return nil }
        return lyric
    }

    private static func nextCursor(
        after cursor: Cursor,
        for terminator: Terminator,
        in score: Score,
    ) -> Cursor? {
        guard terminator != .none,
              let location = score.nextChord(after: cursor.location)
        else { return nil }
        return Cursor(location: location, verse: cursor.verse)
    }

    private static func writingCommand(
        text: String,
        current: Lyric?,
        terminator: Terminator,
        at cursor: Cursor,
        in score: Score,
    ) -> (any EditCommand)? {
        var written = current.map { SyllableState($0) } ?? SyllableState(
            syllabic: startingSyllabic(before: cursor, in: score),
            ticks: 0,
        )
        repairFrom(&written, for: terminator, at: cursor.location, cursor: cursor.location, in: score)
        let unchanged = current.map {
            $0.text == text && $0.syllabic == written.syllabic && $0.ticks == written.ticks
        } ?? false
        guard !unchanged else { return nil }
        return SetLyric(
            at: cursor.location,
            verse: cursor.verse,
            text: text,
            syllabic: written.syllabic,
            ticks: written.ticks,
        )
    }

    private static func precedingRepair(
        for terminator: Terminator,
        before cursor: Cursor,
        in score: Score,
    ) -> (any EditCommand)? {
        guard terminator != .none,
              let preceding = precedingLyric(before: cursor, in: score)
        else { return nil }
        var repaired = SyllableState(preceding.lyric)
        repairFrom(
            &repaired,
            for: terminator,
            at: preceding.location,
            cursor: cursor.location,
            in: score,
        )
        guard repaired != SyllableState(preceding.lyric) else { return nil }
        return SetLyric(
            at: preceding.location,
            verse: cursor.verse,
            text: preceding.lyric.text,
            syllabic: repaired.syllabic,
            ticks: repaired.ticks,
        )
    }

    private static func destinationRepair(
        for terminator: Terminator,
        at cursor: Cursor,
        in score: Score,
    ) -> (any EditCommand)? {
        guard let lyric = lyric(at: cursor, in: score) else { return nil }
        var destination = SyllableState(lyric)
        let previous = destination
        switch terminator {
        case .none:
            return nil
        case .word, .melisma:
            switch destination.syllabic {
            case .middle: destination.syllabic = .begin
            case .end: destination.syllabic = .single
            case .single, .begin: break
            }
        case .syllable:
            switch destination.syllabic {
            case .single: destination.syllabic = .end
            case .begin: destination.syllabic = .middle
            case .middle, .end: break
            }
        }
        guard destination != previous else { return nil }
        return SetLyric(
            at: cursor.location,
            verse: cursor.verse,
            text: lyric.text,
            syllabic: destination.syllabic,
            ticks: destination.ticks,
        )
    }

    private static func repairFrom(
        _ lyric: inout SyllableState,
        for terminator: Terminator,
        at location: VoiceElementID,
        cursor: VoiceElementID,
        in score: Score,
    ) {
        switch terminator {
        case .none:
            return
        case .word:
            switch lyric.syllabic {
            case .begin: lyric.syllabic = .single
            case .middle: lyric.syllabic = .end
            case .single, .end: break
            }
            lyric.ticks = 0
        case .syllable:
            switch lyric.syllabic {
            case .single: lyric.syllabic = .begin
            case .end: lyric.syllabic = .middle
            case .begin, .middle: break
            }
            lyric.ticks = 0
        case .melisma:
            if lyric.syllabic != .single, lyric.syllabic != .end {
                lyric.syllabic = .end
            }
            lyric.ticks = melismaTicks(from: location, through: cursor, in: score) ?? lyric.ticks
        }
    }

    private static func startingSyllabic(before cursor: Cursor, in score: Score) -> Syllabic {
        guard let preceding = precedingLyric(before: cursor, in: score) else { return .single }
        switch preceding.lyric.syllabic {
        case .begin, .middle:
            return .end
        case .single, .end:
            return .single
        }
    }

    private static func precedingLyric(
        before cursor: Cursor,
        in score: Score,
    ) -> (location: VoiceElementID, lyric: Lyric)? {
        var location = score.previousChord(before: cursor.location)
        while let candidate = location {
            let candidateCursor = Cursor(location: candidate, verse: cursor.verse)
            if let lyric = lyric(at: candidateCursor, in: score) {
                return (candidate, lyric)
            }
            location = score.previousChord(before: candidate)
        }
        return nil
    }

    private static func melismaTicks(
        from location: VoiceElementID,
        through cursor: VoiceElementID,
        in score: Score,
    ) -> Int? {
        if location == cursor {
            guard case let .chord(chord) = score[location] else { return nil }
            let duration = score.effectiveMeasureDuration(
                at: location.staff,
                measureIndex: location.measureIndex,
            )
            return chord.duration
                .resolved(in: duration)
                .ticks(division: score.division)
        }
        guard let start = score.absoluteTick(of: location),
              let end = score.absoluteTick(of: cursor)
        else { return nil }
        return end - start
    }

    private static func bundled(
        _ commands: [any EditCommand],
        at location: VoiceElementID,
    ) -> (any EditCommand)? {
        switch commands.count {
        case 0: nil
        case 1: commands[0]
        default: CompositeEditCommand(commands: commands, location: location)
        }
    }

    private struct SyllableState: Equatable {
        var syllabic: Syllabic
        var ticks: Int

        init(syllabic: Syllabic, ticks: Int) {
            self.syllabic = syllabic
            self.ticks = ticks
        }

        init(_ lyric: Lyric) {
            syllabic = lyric.syllabic
            ticks = lyric.ticks
        }
    }
}
