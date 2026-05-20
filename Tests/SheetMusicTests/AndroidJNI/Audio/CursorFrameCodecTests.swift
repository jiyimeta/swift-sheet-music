#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import Testing

    #if canImport(CoreGraphics)
        import CoreGraphics
    #endif

    struct CursorFrameCodecTests {
        // MARK: - Round-trip tests

        @Test
        func roundTripPositiveRect() throws {
            let rect = CGRect(x: 10.5, y: 20.0, width: 4.0, height: 80.5)
            let encoded = CursorFrameCodec.encode(rect)
            let decoded = try #require(try CursorFrameCodec.decode(encoded))
            #expect(abs(decoded.x - Double(rect.origin.x)) < 0.0001)
            #expect(abs(decoded.y - Double(rect.origin.y)) < 0.0001)
            #expect(abs(decoded.width - Double(rect.size.width)) < 0.0001)
            #expect(abs(decoded.height - Double(rect.size.height)) < 0.0001)
        }

        @Test
        func roundTripZeroRect() throws {
            let rect = CGRect.zero
            let encoded = CursorFrameCodec.encode(rect)
            let decoded = try #require(try CursorFrameCodec.decode(encoded))
            #expect(decoded.x == 0.0)
            #expect(decoded.y == 0.0)
            #expect(decoded.width == 0.0)
            #expect(decoded.height == 0.0)
        }

        @Test
        func roundTripSubMillimeterPrecision() throws {
            // Verify microsecond-level precision is preserved.
            let rect = CGRect(x: 1.000001, y: 2.000002, width: 0.5, height: 100.123456)
            let encoded = CursorFrameCodec.encode(rect)
            let decoded = try #require(try CursorFrameCodec.decode(encoded))
            #expect(abs(decoded.x - Double(rect.origin.x)) < 1e-5)
            #expect(abs(decoded.y - Double(rect.origin.y)) < 1e-5)
            #expect(abs(decoded.width - Double(rect.size.width)) < 1e-5)
            #expect(abs(decoded.height - Double(rect.size.height)) < 1e-5)
        }

        // MARK: - Empty data → nil

        @Test
        func emptyDataReturnsNil() throws {
            let result = try CursorFrameCodec.decode(Data())
            #expect(result == nil)
        }

        // MARK: - Version mismatch throws

        @Test
        func versionMismatchThrows() throws {
            let rect = CGRect(x: 1, y: 2, width: 3, height: 4)
            var encoded = CursorFrameCodec.encode(rect)
            // Corrupt the version bytes to 0xFF 0xFF.
            encoded[0] = 0xFF
            encoded[1] = 0xFF
            #expect(throws: AudioBinaryReader.BinaryReaderError.self) {
                _ = try CursorFrameCodec.decode(encoded)
            }
        }

        // MARK: - Byte length

        @Test
        func encodedLengthIs34Bytes() {
            // u16 version + 4 × i64 = 2 + 4*8 = 34 bytes.
            let rect = CGRect(x: 1, y: 2, width: 3, height: 4)
            let encoded = CursorFrameCodec.encode(rect)
            #expect(encoded.count == 34)
        }

        // MARK: - Known-bytes spot check

        @Test
        func knownBytesVersionField() {
            let rect = CGRect(x: 0, y: 0, width: 0, height: 0)
            let encoded = CursorFrameCodec.encode(rect)
            // First 2 bytes: version = 1 LE.
            #expect(encoded[0] == 0x01)
            #expect(encoded[1] == 0x00)
        }
    }
#endif
