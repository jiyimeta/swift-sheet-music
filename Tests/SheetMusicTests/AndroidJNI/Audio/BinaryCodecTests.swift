#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import Testing

    struct BinaryCodecTests {
        // MARK: - BinaryWriter

        @Test
        func writerAppendsUInt8() {
            var w = AudioBinaryWriter()
            w.append(UInt8(0xAB))
            #expect(w.data == Data([0xAB]))
        }

        @Test
        func writerAppendsUInt16LittleEndian() {
            var w = AudioBinaryWriter()
            w.append(UInt16(0x1234))
            #expect(w.data == Data([0x34, 0x12]))
        }

        @Test
        func writerAppendsInt32LittleEndian() {
            var w = AudioBinaryWriter()
            w.append(Int32(-1))
            #expect(w.data == Data([0xFF, 0xFF, 0xFF, 0xFF]))
        }

        @Test
        func writerAppendsInt32Value() {
            var w = AudioBinaryWriter()
            w.append(Int32(0x0102_0304))
            #expect(w.data == Data([0x04, 0x03, 0x02, 0x01]))
        }

        @Test
        func writerAppendsInt64LittleEndian() {
            var w = AudioBinaryWriter()
            w.append(Int64(1_000_000))
            #expect(w.data == Data([0x40, 0x42, 0x0F, 0x00, 0x00, 0x00, 0x00, 0x00]))
        }

        @Test
        func writerAppendsMultipleValues() {
            var w = AudioBinaryWriter()
            w.append(UInt8(0x01))
            w.append(UInt16(0x0203))
            w.append(Int32(0x0405_0607))
            #expect(w.data == Data([0x01, 0x03, 0x02, 0x07, 0x06, 0x05, 0x04]))
        }

        // MARK: - BinaryReader success paths

        @Test
        func readerReadsUInt8() throws {
            var r = AudioBinaryReader(Data([0xAB]))
            let v = try r.readUInt8()
            #expect(v == 0xAB)
        }

        @Test
        func readerReadsUInt16() throws {
            var r = AudioBinaryReader(Data([0x34, 0x12]))
            let v = try r.readUInt16()
            #expect(v == 0x1234)
        }

        @Test
        func readerReadsInt32() throws {
            var r = AudioBinaryReader(Data([0x04, 0x03, 0x02, 0x01]))
            let v = try r.readInt32()
            #expect(v == 0x0102_0304)
        }

        @Test
        func readerReadsInt64() throws {
            var r = AudioBinaryReader(Data([0x40, 0x42, 0x0F, 0x00, 0x00, 0x00, 0x00, 0x00]))
            let v = try r.readInt64()
            #expect(v == 1_000_000)
        }

        @Test
        func readerReadsSequentialValues() throws {
            var r = AudioBinaryReader(Data([0x01, 0x03, 0x02, 0x07, 0x06, 0x05, 0x04]))
            let a = try r.readUInt8()
            let b = try r.readUInt16()
            let c = try r.readInt32()
            #expect(a == 0x01)
            #expect(b == 0x0203)
            #expect(c == 0x0405_0607)
        }

        // MARK: - BinaryReader error paths

        @Test
        func readerThrowsUnderflowOnEmptyData() {
            var r = AudioBinaryReader(Data())
            #expect(throws: AudioBinaryReader.BinaryReaderError.self) {
                _ = try r.readUInt8()
            }
        }

        @Test
        func readerThrowsUnderflowWhenTruncated() {
            var r = AudioBinaryReader(Data([0x01, 0x02]))
            #expect(throws: AudioBinaryReader.BinaryReaderError.self) {
                _ = try r.readInt32() // needs 4 bytes, only 2 available
            }
        }

        @Test
        func readerVersionMismatchError() {
            let err = AudioBinaryReader.BinaryReaderError.versionMismatch(
                expected: 1, found: 99,
            )
            if case let .versionMismatch(expected, found) = err {
                #expect(expected == 1)
                #expect(found == 99)
            } else {
                Issue.record("expected versionMismatch case")
            }
        }

        // MARK: - Round-trip

        @Test
        func roundTripInt32() throws {
            var w = AudioBinaryWriter()
            w.append(Int32(-42))
            var r = AudioBinaryReader(w.data)
            let v = try r.readInt32()
            #expect(v == -42)
        }

        @Test
        func roundTripInt64() throws {
            var w = AudioBinaryWriter()
            w.append(Int64.min)
            var r = AudioBinaryReader(w.data)
            let v = try r.readInt64()
            #expect(v == Int64.min)
        }
    }
#endif
