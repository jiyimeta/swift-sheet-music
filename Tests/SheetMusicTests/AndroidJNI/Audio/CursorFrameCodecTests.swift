#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import Testing

    #if canImport(CoreGraphics)
        import CoreGraphics
    #endif

    struct CursorFrameCodecTests {
        // Byte-count assertions are superseded by golden fixtures in the Kotlin
        // codec tests. Only round-trip and nil-sentinel tests are kept here.

        // MARK: - Round-trip tests

        @Test
        func roundTripPositiveRect() throws {
            let rect = CGRect(x: 10.5, y: 20.0, width: 4.0, height: 80.5)
            let encoded = CursorFrameCodec.encode(rect)
            let decoded = try #require(try CursorFrameCodec.decode(encoded))
            // Raw IEEE 754 Double is bit-identical for representable values.
            #expect(decoded.x == Double(rect.origin.x))
            #expect(decoded.y == Double(rect.origin.y))
            #expect(decoded.width == Double(rect.size.width))
            #expect(decoded.height == Double(rect.size.height))
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
            // Raw Double round-trip is bit-identical, so precision is exact
            // (~15 significant decimal digits), not micros-quantized.
            let rect = CGRect(x: 1.000001, y: 2.000002, width: 0.5, height: 100.123456)
            let encoded = CursorFrameCodec.encode(rect)
            let decoded = try #require(try CursorFrameCodec.decode(encoded))
            #expect(decoded.x == Double(rect.origin.x))
            #expect(decoded.y == Double(rect.origin.y))
            #expect(decoded.width == Double(rect.size.width))
            #expect(decoded.height == Double(rect.size.height))
        }

        // MARK: - Empty data → nil

        @Test
        func emptyDataReturnsNil() throws {
            let result = try CursorFrameCodec.decode(Data())
            #expect(result == nil)
        }
    }
#endif
