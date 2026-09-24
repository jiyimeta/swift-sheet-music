#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        import Foundation
        import SheetMusicAudioCore
        @testable import SheetMusicAudioSwiftySynth
        import Testing

        /// Backends loading one SoundFont share one parse — what keeps parallel part renders from costing a font each.
        struct SoundFontCacheTests {
            private static func writeFont(samples: Int) throws -> URL {
                let wave = (0 ..< samples).map { $0 % 2 == 0 ? Int16(12000) : Int16(-12000) }
                let sf2 = ClickSoundFontBuilder.build(strong: wave, strongRate: 44100, weak: wave, weakRate: 44100)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID()).sf2")
                try sf2.write(to: url)
                return url
            }

            @Test func `concurrent loads of one file share a single parse`() async throws {
                let url = try Self.writeFont(samples: 2205)
                defer { try? FileManager.default.removeItem(at: url) }
                let cache = SoundFontCache()

                async let first = cache.soundFont(at: url)
                async let second = cache.soundFont(at: url)
                let fonts = try await [#require(first), #require(second)]

                #expect(fonts[0].font === fonts[1].font)
            }

            @Test func `a later load reuses a font someone still holds`() async throws {
                let url = try Self.writeFont(samples: 2205)
                defer { try? FileManager.default.removeItem(at: url) }
                let cache = SoundFontCache()

                let held = try #require(await cache.soundFont(at: url))
                let again = try #require(await cache.soundFont(at: url))

                #expect(held.font === again.font)
            }

            @Test func `a file replaced at the same path is parsed again`() async throws {
                let url = try Self.writeFont(samples: 2205)
                defer { try? FileManager.default.removeItem(at: url) }
                let cache = SoundFontCache()

                let old = try #require(await cache.soundFont(at: url))
                let replacement = try Self.writeFont(samples: 4410)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
                let new = try #require(await cache.soundFont(at: url))

                #expect(old.font !== new.font)
            }

            @Test func `a missing file loads nothing`() async {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).sf2")
                #expect(await SoundFontCache().soundFont(at: url) == nil)
            }
        }
    #endif
#endif
