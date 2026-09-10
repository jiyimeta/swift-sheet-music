@testable import SheetMusicCore
import Testing

enum GraceIdentityFixtures {
    static func grace(_ pitch: Int = 59) -> GraceChord {
        GraceChord(graceType: .acciaccatura, duration: .eighth, notes: [Note(pitch: pitch, tpc: 13)])
    }

    static func chord(before: [GraceChord], after: [GraceChord]) -> Chord {
        Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
            graceNotesBefore: before,
            graceNotesAfter: after,
        )
    }

    static func score(before: [GraceChord], after: [GraceChord]) -> Score {
        VoiceIdentityFixtures.score(elements: [.chord(chord(before: before, after: after))])
    }

    static func chord(_ score: Score, index: Int = 0) throws -> Chord {
        let element = VoiceIdentityFixtures.elements(score)[index]
        let value: Chord? = if case let .chord(chord) = element { chord } else { nil }
        return try #require(value)
    }

    static func ids(_ list: IdentifiedArray<GraceChord>) -> [EID] {
        list.indices.map { list.eid(at: $0) }
    }

    static func mutate(_ score: inout Score, index: Int = 0, _ body: (inout Chord) -> Void) {
        TupletIdentityFixtures.mutate(&score) { voice in
            voice.elements.updateValue(at: index) { element in
                guard case var .chord(chord) = element else { return }
                body(&chord)
                element = .chord(chord)
            }
        }
    }
}
