import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCXEncoder MS3 target")
struct MSCXEncoderMS3Tests {
    @Test("MSCXVersion has v3 and v4 cases")
    func mscxVersionCases() {
        let v3: MSCXVersion = .v3
        let v4: MSCXVersion = .v4
        #expect(v3 != v4)
    }
}
