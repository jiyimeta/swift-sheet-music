@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// The MSCX articulation token table, now in Core: `ChordArticulation.Kind.mscxToken` and its inverse. The decode
/// and encode paths call it, so this suite is what pins that the move changed no string.
@Suite("ChordArticulation.Kind mscx tokens")
struct ArticulationTokenTests {
    private static let known: [(ChordArticulation.Kind, String)] = [
        (.staccato, "articStaccato"), (.staccatissimo, "articStaccatissimo"), (.tenuto, "articTenuto"),
        (.accent, "articAccent"), (.marcato, "articMarcato"),
        (.accentStaccato, "articAccentStaccato"), (.marcatoStaccato, "articMarcatoStaccato"),
    ]

    @Test("each known kind spells its MuseScore SymId base, and reads back", arguments: known)
    func tokens(kind: ChordArticulation.Kind, token: String) {
        #expect(kind.mscxToken == token)
        #expect(ChordArticulation.Kind(mscxToken: token) == kind)
    }

    @Test("an unknown token has no known kind, and an unknown kind spells its raw string back")
    func unknown() {
        #expect(ChordArticulation.Kind(mscxToken: "articSoftAccentAbove") == nil)
        #expect(ChordArticulation.Kind.unknown(subtype: "articSoftAccentAbove").mscxToken == "articSoftAccentAbove")
    }

    @Test("the decoder still strips the anchor and keeps the FULL string for an unknown", arguments: [
        ("articStaccatoAbove", ChordArticulation(kind: .staccato, anchor: .above)),
        ("articTenutoBelow", ChordArticulation(kind: .tenuto, anchor: .below)),
        ("articAccent", ChordArticulation(kind: .accent, anchor: nil)),
        ("articSoftAccentAbove", ChordArticulation(kind: .unknown(subtype: "articSoftAccentAbove"))),
    ])
    func decodeIsUnchanged(subtype: String, expected: ChordArticulation) {
        #expect(ChordArticulation.fromSubtypeXML(subtype) == expected)
    }

    @Test("encode is the inverse for every known kind and both anchors, and verbatim for an unknown")
    func encodeIsUnchanged() {
        for (kind, token) in Self.known {
            #expect(ChordArticulation(kind: kind, anchor: .above).subtypeXML() == token + "Above")
            #expect(ChordArticulation(kind: kind, anchor: .below).subtypeXML() == token + "Below")
            #expect(ChordArticulation(kind: kind, anchor: nil).subtypeXML() == token + "Above")
        }
        #expect(ChordArticulation(kind: .unknown(subtype: "x"), anchor: .below).subtypeXML() == "x")
    }

    /// MuseScore's `ARPEGGIO_TYPES` is `0 NORMAL, 1 UP, 2 DOWN, 3 BRACKET, 4 UP_STRAIGHT, 5 DOWN_STRAIGHT`
    /// (`typesconv.cpp:2558-2565`). Only 2 and 5 spread downwards. The tree's one arpeggio fixture carries
    /// subtypes 0, 1 and 2 only, so this predicate is the only place 3…5 is checked at all.
    @Test("arpeggio subtypes 2 and 5 descend; 0, 1, 3 and 4 ascend", arguments: [
        (0, true), (1, true), (2, false), (3, true), (4, true), (5, false),
    ] as [(Int, Bool)])
    func arpeggioDirection(subtype: Int, ascending: Bool) {
        #expect(Arpeggio(subtype: subtype).isAscending == ascending)
    }
}
