import Foundation
import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

/// `LayoutEngine.stickyHeaderSystem` builds its frozen pane from the template system's staff origins, so it has to
/// carry the same staves' addresses. It used to leave them out — `LayoutSystem.init` defaulted them to `[]` — and a
/// header without them cannot answer `flatIndex(for:)` for any staff, even though every row it draws is one of the
/// template's.
struct StickyHeaderStaffAddressTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    @Test("the sticky header carries the template system's staff addresses")
    func stickyHeaderCarriesTheTemplateAddresses() throws {
        // Four parts, the third a two-staff piano, so the addresses are not just `0 ..< n` in part order.
        let url = try #require(TestResources.url(forResource: "multiPartMixedStaves", withExtension: "mscx"))
        let score = try MSCXParser.parse(contentsOf: url)
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(staffSize: 18, systemGap: 16, wrapToViewWidth: false),
            availableWidth: 2000,
        )
        let template = try #require(doc.systems.first)
        let context = try #require(LayoutEngine.measureContexts(for: score).first)

        let sticky = LayoutEngine.stickyHeaderSystem(for: context, templateSystem: template, metrics: doc.metrics)

        let pianoLeftHand = StaffAddress(partIndex: 2, staffIndexInPart: 1)
        #expect(template.staffAddresses.count == 5)
        #expect(template.staffAddresses.contains(pianoLeftHand))
        #expect(sticky.staffAddresses == template.staffAddresses)
        #expect(sticky.staffAddresses.count == sticky.staffOrigins.count)
        #expect(sticky.flatIndex(for: pianoLeftHand) == template.flatIndex(for: pianoLeftHand))
    }
}
