import Foundation
import SheetMusicCore
import SheetMusicMSCX
import Testing

@Suite("Stable column identity")
struct ColumnIdentityTests {
    private let positionalActor = UInt64.max - 1
    private let collisionActor = UInt64.max - 2

    private func bytes(ids: [EID?]) -> Data {
        let measures = ids.map { id in
            let eid = id.map { "<eid>\($0.stringValue)</eid>" } ?? ""
            return "<Measure>\(eid)<voice><Rest><durationType>measure</durationType></Rest></voice></Measure>"
        }.joined()
        return Data("""
        <museScore version="4.00"><Score><Division>480</Division>
        <Part><Staff id="1"/><Instrument><trackName>Piano</trackName></Instrument></Part>
        <Staff id="1">\(measures)</Staff></Score></museScore>
        """.utf8)
    }

    private func columns(_ score: Score) -> [EID] {
        score.systemMeasures.indices.map { score.systemMeasures.eid(at: $0) }
    }

    @Test func missingColumnsAreStableAcrossParses() throws {
        let data = bytes(ids: [nil, nil, nil])
        let first = try MSCXParser.parse(data)
        let second = try MSCXParser.parse(data)
        #expect(columns(first) == columns(second))
        #expect(columns(first) == (0 ..< 3).map { EID(first: positionalActor, second: UInt64($0)) })
    }

    @Test func mixedColumnsResolveCollisionsDeterministically() throws {
        let existing = EID(first: positionalActor, second: 2)
        let occupiedFallback = EID(first: collisionActor, second: 1)
        let data = bytes(ids: [existing, occupiedFallback, nil, nil])
        let expected = [
            existing, occupiedFallback, EID(first: collisionActor, second: 2),
            EID(first: positionalActor, second: 3),
        ]
        let first = try MSCXParser.parse(data)
        let second = try MSCXParser.parse(data)
        #expect(columns(first) == expected)
        #expect(columns(second) == expected)
        #expect(Set(columns(first)).count == 4)
    }

    @Test func assignmentPreservesOtherElementIDs() {
        let rest = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
        let lane = SystemMeasure(elements: [PositionedSystemElement(
            position: .start, element: .rehearsalMark(RehearsalMark(text: "A")),
        )])
        var score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [rest])])],
            systemMeasures: [lane],
        )
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        #expect(score.parts.eid(at: 0) == EID(first: 42, second: 1))
        #expect(score.parts[0].staves.eid(at: 0) == EID(first: 42, second: 2))
        #expect(score.parts[0].staves[0].measures[0].voices[0].elements.eid(at: 0) == EID(first: 42, second: 3))
        #expect(score.systemMeasures[0].elements.eid(at: 0) == EID(first: 42, second: 5))
        #expect(ids.counter == 5)
    }

    @Test func savedEditsRetainColumnIDs() throws {
        var score = try MSCXParser.parse(bytes(ids: [nil, nil]))
        let original = columns(score)
        _ = try InsertMeasure(measureIndex: 0).apply(to: &score)
        let reopened = try MSCXParser.parse(MSCXEncoder.encode(score))
        #expect(columns(reopened) == columns(score))
        #expect(Array(columns(reopened).dropFirst()) == original)
        #expect(!original.contains(reopened.systemMeasures.eid(at: 0)))
    }
}
