import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

@Suite struct LayoutPartLabelClefTests {
    @available(macOS 15.0, iOS 16.0, *)
    @Test func partLabelsAndDefaultClefsAlignWithMultiStavePart() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "multiPartMixedStaves",
                withExtension: "mscx"
            )
        )
        let score = try MSCXParser.parse(contentsOf: url)

        let contexts = LayoutEngine.measureContexts(for: score)
        let m0 = try #require(contexts.first)

        // Display order is [Vln1, Vln2, Piano-RH, Piano-LH, Vc].
        // Old bug: partLabels[idx] used parts[idx], so slot 3 (Piano-LH)
        // pointed at parts[3] (= Vc) instead of parts[2] (= Piano).
        #expect(m0.partLabels[0] == "Violin 1")
        #expect(m0.partLabels[1] == "Violin 2")
        #expect(m0.partLabels[2] == "Piano")
        #expect(m0.partLabels[3] == "Piano")
        #expect(m0.partLabels[4] == "Violoncello")

        // Default clef chain expected: G, G, G, F, F.
        // Old bug: slot 4 picked up parts[4].staffDeclarations.first
        // (out of bounds → fell back to "G") instead of the F clef
        // declared on Vc's staff.
        #expect(m0.clefRawTypes == ["G", "G", "G", "F", "F"])
    }
}
