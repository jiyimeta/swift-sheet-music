import Foundation
@testable import SheetMusicCore
import Testing

struct TremoloModelTests {
    @Test func tremolo_default_init() {
        let t = Tremolo(subtype: .r16)
        #expect(t.subtype == .r16)
        #expect(t.span == .single)
        #expect(t.strokeStyle == .default)
    }

    @Test func tremolo_full_init() {
        let t = Tremolo(subtype: .r8, span: .between, strokeStyle: .traditional)
        #expect(t.subtype == .r8)
        #expect(t.span == .between)
        #expect(t.strokeStyle == .traditional)
    }
}
