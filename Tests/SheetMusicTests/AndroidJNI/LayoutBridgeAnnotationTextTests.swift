#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicBridgeCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// An annotation staff text reaches the draw program with the opcodes plain staff text already uses — and in the
    /// style's weight: expression text is italic (`setTextStyle` carries the bit).
    @Suite("LayoutBridge annotation text")
    struct LayoutBridgeAnnotationTextTests {
        private let _installApple = TestSupport.installApple

        @Test("an expression is emitted italic, a sticking regular")
        func expressionIsItalic() {
            let score = AnnotationFixtures.score([
                .expression(ExpressionText(text: "dolce")), .sticking(Sticking(text: "R")), AnnotationFixtures.whole(),
            ])
            let document = AnnotationFixtures.layout(score)
            let out = LayoutBridge.buildCommands(layout: document)
            let styles = out.enumerated().compactMap { index, command -> (String, UInt8)? in
                guard case let .text(text, _, _, _, _) = command, index > 0,
                      case let .setTextStyle(flags) = out[index - 1] else { return nil }
                return (text, flags)
            }
            #expect(styles.contains { $0.0 == "dolce" && $0.1 & DrawCommand.TextStyleFlag.italic != 0 })
            #expect(styles.contains { $0.0 == "R" && $0.1 == DrawCommand.TextStyleFlag.none })
        }
    }
#endif
