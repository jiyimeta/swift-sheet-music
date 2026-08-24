@testable import SheetMusicLayout
import Testing

struct ShowsInvisibleOptionTests {
    @Test func defaultsToFalse() {
        #expect(ScoreViewOptions().showsInvisibleElements == false)
    }

    @Test func canEnable() {
        var opts = ScoreViewOptions()
        opts.showsInvisibleElements = true
        #expect(opts.showsInvisibleElements == true)
    }
}
