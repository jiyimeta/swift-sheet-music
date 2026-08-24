@testable import SheetMusicLayout
import Testing

struct NoteHeadGroupTests {
    @Test func tokenResolves() {
        #expect(NoteHeadGroup.from(token: "xcircle") == .xcircle)
        #expect(NoteHeadGroup.from(token: "altbrevis") == .brevisAlt)
        #expect(NoteHeadGroup.from(token: "a-sharp-name") == .aSharpName)
        #expect(NoteHeadGroup.from(token: "custom") == nil)
        #expect(NoteHeadGroup.from(token: "bogus") == nil)
    }

    @Test func glyphNames() {
        #expect(NoteHeadGroup.symName(group: .xcircle, kind: .quarter, stemUp: false) == "noteheadCircleX")
        #expect(NoteHeadGroup.symName(group: .normal, kind: .whole, stemUp: false) == "noteheadWhole")
        // FA flips triangle-right (down stem) vs triangle-left (up stem).
        #expect(NoteHeadGroup.symName(group: .fa, kind: .quarter, stemUp: false) == "noteShapeTriangleRightBlack")
        #expect(NoteHeadGroup.symName(group: .fa, kind: .quarter, stemUp: true) == "noteShapeTriangleLeftBlack")
    }

    @Test func everyGroupSymNameResolves() {
        for group in NoteHeadGroup.allCases {
            for kind in [NoteHeadKind.whole, .half, .quarter, .doubleWhole] {
                for stemUp in [false, true] {
                    let name = NoteHeadGroup.symName(group: group, kind: kind, stemUp: stemUp)
                    if name != "noSym" {
                        let msg = "\(group) \(kind) stemUp=\(stemUp): \(name) not in subset"
                        #expect(SMuFLCodepoint.byName(name) != nil, "\(msg)")
                    }
                }
            }
        }
    }
}
