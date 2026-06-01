import Foundation
@testable import SheetMusicAudioCore
import Testing

struct MetronomeClickSourceTests {
    @Test func clickSamplesCarriesBothUrls() {
        let strong = URL(fileURLWithPath: "/tmp/strong.wav")
        let weak = URL(fileURLWithPath: "/tmp/weak.wav")
        let source = MetronomeClickSource.clickSamples(strong: strong, weak: weak)
        #expect(source == .clickSamples(strong: strong, weak: weak))
        #expect(source != .defaultGM)
    }

    @Test func providerReturnsConfiguredSource() {
        struct FixedProvider: MetronomeClickProvider {
            let source: MetronomeClickSource
            func metronomeClickSource() -> MetronomeClickSource {
                source
            }
        }
        let provider = FixedProvider(source: .defaultGM)
        #expect(provider.metronomeClickSource() == .defaultGM)
    }
}
