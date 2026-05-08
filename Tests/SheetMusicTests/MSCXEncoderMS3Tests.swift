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

    @Test("MSCXEncoderOptions defaults to v4")
    func optionsDefaultsToV4() {
        let opts = MSCXEncoderOptions()
        #expect(opts.targetVersion == .v4)
    }

    @Test("MSCXEncoderOptions accepts v3")
    func optionsAcceptsV3() {
        let opts = MSCXEncoderOptions(targetVersion: .v3)
        #expect(opts.targetVersion == .v3)
    }
}
