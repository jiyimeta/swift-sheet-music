import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

/// `LayoutSystem.staffAddresses` is populated by `LayoutEngine+SystemBuild`, but the post-build passes that rebuild
/// each system — vertical packing (`shift(_:byY:)`), `attachSpanners`, and `attachTies` — must carry it forward.
/// A dropped `staffAddresses` silently breaks every consumer that maps a `StaffAddress` to a flat staff index
/// (notably the Reader's tap-to-seek hit test), because the field defaults to `[]`.
@Suite("StaffAddressesPropagation")
struct StaffAddressesPropagationTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// A two-part score so every laid-out system carries two distinct staff addresses. The full
    /// `LayoutEngine.layout` pipeline runs packing + spanner + tie passes; each must preserve `staffAddresses`.
    @available(macOS 15.0, *)
    @Test func layoutPipelinePreservesStaffAddresses() throws {
        let mscx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60">
          <Score>
            <Division>480</Division>
            <Part id="1">
              <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
              <Instrument id="i1"><longName>Flute</longName></Instrument>
            </Part>
            <Part id="2">
              <Staff id="2"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
              <Instrument id="i2"><longName>Cello</longName></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <Chord><durationType>quarter</durationType><Note><pitch>67</pitch><tpc>15</tpc></Note></Chord>
                </voice>
              </Measure>
            </Staff>
            <Staff id="2">
              <Measure>
                <voice>
                  <Chord><durationType>quarter</durationType><Note><pitch>48</pitch><tpc>14</tpc></Note></Chord>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        let score = try MSCXParser.parse(Data(mscx.utf8))
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(staffSize: 20, wrapToViewWidth: true),
            availableWidth: 400,
        )

        #expect(!doc.systems.isEmpty)
        for system in doc.systems {
            // The whole point: the address array survived the rebuild passes and stays aligned with staffOrigins.
            #expect(system.staffAddresses.count == system.staffOrigins.count)
            #expect(!system.staffAddresses.isEmpty)
            // Two-part score → the two staves keep their canonical addresses in display order.
            #expect(system.staffAddresses == [
                StaffAddress(partIndex: 0, staffIndexInPart: 0),
                StaffAddress(partIndex: 1, staffIndexInPart: 0),
            ])
        }
    }
}
