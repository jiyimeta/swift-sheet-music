#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    import Testing

    struct GMInstrumentCodecTests {
        @Test func encodesAll128PatchesInOrder() {
            let data = GMInstrumentCodec.encodeAll()
            #expect(!data.isEmpty)

            var r = AudioBinaryReader(data)
            let version = try? r.readUInt16()
            #expect(version == GMInstrumentCodec.version)
            let count = try? r.readInt32()
            #expect(count == 128)

            for expected in GMInstrument.all {
                let program = try? r.readUInt8()
                _ = try? r.readUInt8() // familyIndex
                let nameLen = try? r.readUInt16()
                guard let len = nameLen else {
                    Issue.record("nameLen decode failed")
                    return
                }
                let nameBytes = try? r.readBytes(Int(len))
                let name = nameBytes.flatMap { String(data: Data($0), encoding: .utf8) }

                #expect(program == expected.program)
                #expect(name == expected.name)
            }
        }

        @Test func familyIndexMatchesCanonicalOrder() {
            let data = GMInstrumentCodec.encodeAll()
            var r = AudioBinaryReader(data)
            _ = try? r.readUInt16() // version
            _ = try? r.readInt32() // count

            let families = GMInstrument.Family.allCases
            for expected in GMInstrument.all {
                _ = try? r.readUInt8() // program
                let familyIdx = try? r.readUInt8()
                let nameLen = (try? r.readUInt16()) ?? 0
                _ = try? r.readBytes(Int(nameLen))

                let expectedIdx = families.firstIndex(of: expected.family)
                #expect(familyIdx.map { Int($0) } == expectedIdx)
            }
        }
    }
#endif
