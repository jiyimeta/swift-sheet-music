#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import Testing

    struct HandleTableTests {
        @Test
        func storeReturnsNonZeroHandle() {
            let table = HandleTable<String>()
            let h = table.insert("hello")
            #expect(h != 0)
        }

        @Test
        func storedValueRoundTrips() {
            let table = HandleTable<String>()
            let h = table.insert("hello")
            #expect(table.value(for: h) == "hello")
        }

        @Test
        func releaseRemovesValue() {
            let table = HandleTable<String>()
            let h = table.insert("hello")
            table.release(h)
            #expect(table.value(for: h) == nil)
        }

        @Test
        func handlesAreMonotonicAndUnique() {
            let table = HandleTable<Int>()
            let a = table.insert(1)
            let b = table.insert(2)
            let c = table.insert(3)
            #expect(a < b && b < c)
            #expect(Set([a, b, c]).count == 3)
        }

        @Test
        func releaseOfUnknownHandleIsNoOp() {
            let table = HandleTable<Int>()
            table.release(999) // does not crash
            #expect(table.value(for: 999) == nil)
        }
    }
#endif
