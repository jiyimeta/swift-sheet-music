import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout
@testable import SheetMusicPages
import Testing

/// `ScorePageOptions.revealedStaff` through the portable path — `ScorePages.compute`, its wire, the bridge — reaches
/// `ScoreViewOptions.revealedStaff`: the system holding a host's editing caret on a staff it would hide draws every
/// staff, and no other system does (the Apple `ScoreView`'s rule, `EmptyStaffHidingTests`).
@Suite("ScorePages: the revealed staff")
struct ScorePagesRevealedStaffTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let oboe = StaffAddress(partIndex: 1, staffIndexInPart: 0)
    private static let cello = StaffAddress(partIndex: 2, staffIndexInPart: 0)
    private static let all = [flute, oboe, cello]

    private static func provider() throws -> any FontMetricsProvider {
        let table = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SheetMusicPagesTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Web/sheet-music-web/assets/sheet-music.smft")
        return try makeFontMetricsTableProvider(table: FontMetricsTable.decode(Data(contentsOf: table)))
    }

    /// Flute, oboe and cello, one bar to a system, "hide empty staves" on; the oboe rests in the middle system.
    private static func trio() -> Score {
        func staff(_ notes: [Bool], breaks: Bool = false) -> Staff {
            Staff(measures: notes.map { hasNote in
                let elements: [VoiceElement] = hasNote
                    ? [.chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)]))]
                    : [.rest(duration: .measure)]
                return Measure(voices: [Voice(elements: elements)], lineBreak: breaks)
            })
        }
        func part(_ name: String, _ staff: Staff) -> Part {
            Part(id: name, instrument: Instrument(id: name, longName: name), staves: [staff])
        }
        var score = Score(division: 480, parts: [
            part("Flute", staff([true, true, true], breaks: true)),
            part("Oboe", staff([true, false, true])),
            part("Cello", staff([true, true, true])),
        ])
        score.style.hideEmptyStaves = true
        return score
    }

    private static func systems(revealing revealed: ScoreViewOptions.RevealedStaff?) -> [[StaffAddress]] {
        let options = ScorePageOptions(mode: .vertical, staffSize: 20, revealedStaff: revealed)
        return ScorePages.compute(score: trio(), pageWidthMM: 200, pageHeightMM: 280, options: options)
            .document.systems.map(\.staffAddresses)
    }

    @Test("the caret on a staff its system hides opens that system, and no other")
    func revealedStaffOpensItsSystem() throws {
        try FontMetrics.$scopedProvider.withValue(Self.provider()) {
            let plain = Self.systems(revealing: nil)
            try #require(plain == [Self.all, [Self.flute, Self.cello], Self.all])
            #expect(Self.systems(revealing: .init(staff: Self.oboe, measureIndex: 1)) == [Self.all, Self.all, Self.all])
            // On a staff the system draws anyway, or in a system that hides nothing, the caret opens nothing.
            #expect(Self.systems(revealing: .init(staff: Self.flute, measureIndex: 1)) == plain)
            #expect(Self.systems(revealing: .init(staff: Self.oboe, measureIndex: 2)) == plain)
        }
    }

    @Test("wire() carries the revealed staff, and leaves it out when there is none")
    func wireCarriesIt() {
        let revealed = ScorePageOptions(revealedStaff: .init(staff: Self.oboe, measureIndex: 4)).wire()
        #expect(revealed.revealedStaffValue == .init(staff: Self.oboe, measureIndex: 4))
        #expect(ScorePageOptions().wire().revealedStaff == nil)
    }
}
