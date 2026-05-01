import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicPDF
import Testing

@Suite struct PageChromeMacroTests {
    private func ctx(
        page: Int = 0, total: Int = 1,
        meta: [String: String] = [:]
    ) -> PageChromeMacroExpander.Context {
        PageChromeMacroExpander.Context(
            pageIndex: page, pageCount: total, metaTags: meta
        )
    }

    @Test func expandsBasicPageMacros() {
        let cases: [(
            template: String,
            page: Int,
            total: Int,
            expected: String
        )] = [
            ("$P", 0, 1, "1"),
            ("$P", 4, 5, "5"),
            ("$p", 0, 5, ""), // hidden on page 1
            ("$p", 1, 5, "2"),
            ("$N", 0, 1, ""), // hidden when single page
            ("$N", 0, 3, "1"),
            ("$n", 0, 7, "7"),
            ("Page $P of $n", 1, 5, "Page 2 of 5"),
            ("$$", 0, 1, "$"),
        ]
        for (template, page, total, expected) in cases {
            let actual = PageChromeMacroExpander.expand(
                template, context: ctx(page: page, total: total)
            )
            #expect(
                actual == expected,
                "template '\(template)' (page \(page)/\(total))"
            )
        }
    }

    @Test func expandsMetaTagMacros() {
        let meta = [
            "workTitle": "My Title",
            "copyright": "(c) 2026",
            "movementTitle": "II. Slow",
        ]
        let c = ctx(meta: meta)
        #expect(PageChromeMacroExpander.expand("$T", context: c)
            == "My Title")
        #expect(PageChromeMacroExpander.expand("$C", context: c)
            == "(c) 2026")
        #expect(PageChromeMacroExpander.expand(
            "$:movementTitle:", context: c
        ) == "II. Slow")
        // Unknown tag → empty string.
        #expect(PageChromeMacroExpander.expand(
            "$:lyricist:", context: c
        ).isEmpty)
    }

    @Test func firstPageOnlyAndSkipFirstPage() {
        let meta = ["copyright": "(c) X"]
        // `$C` shows on page 1 only.
        #expect(PageChromeMacroExpander.expand(
            "$C", context: ctx(page: 0, total: 3, meta: meta)
        )
            == "(c) X")
        #expect(PageChromeMacroExpander.expand(
            "$C", context: ctx(page: 1, total: 3, meta: meta)
        )
        .isEmpty)
        // `$c` shows on every page.
        #expect(PageChromeMacroExpander.expand(
            "$c", context: ctx(page: 1, total: 3, meta: meta)
        )
            == "(c) X")
        // `$p` skips page 1.
        #expect(PageChromeMacroExpander.expand(
            "$p", context: ctx(page: 0, total: 3)
        ).isEmpty)
    }

    @Test func unterminatedTagFallsThrough() {
        // `$:foo` (no closing colon) — emit as literal '$' and
        // continue, matching the C++ fallback.
        let out = PageChromeMacroExpander.expand(
            "$:foo", context: ctx()
        )
        #expect(out == "$:foo")
    }

    @Test func unknownMacroEchoesLiteral() {
        // `$Q` isn't defined; mirror MuseScore's `default:` branch
        // (`headerfooterlayout.cpp:397-400`).
        let out = PageChromeMacroExpander.expand(
            "$Q", context: ctx()
        )
        #expect(out == "$Q")
    }
}
