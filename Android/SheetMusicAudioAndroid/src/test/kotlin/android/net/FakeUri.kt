package android.net

import android.os.Parcel

/**
 * Minimal same-package [Uri] subclass usable in a Robolectric-free JVM
 * unit test. `android.net.Uri`'s only constructor is package-private, so
 * ordinary test code (a different package) cannot `extends Uri` /
 * `: Uri()` directly — declaring this helper IN `android.net` sidesteps
 * that.
 *
 * Every abstract member below is intentionally left unimplemented: this
 * exists purely to give [io.github.jiyimeta.sheetmusic.audio.SoundfontResolver]
 * fakes a real, non-null `Uri` instance to hand to
 * `SynthDriver.loadSoundFont(uri, context)`, whose fakes (see
 * `FakeSynthDriver`) never dereference the `uri` argument — only
 * `AudioExporter` / `FluidSynthEngine`'s null-check on the reference
 * itself matters, not its content. `Uri.EMPTY` does NOT substitute for
 * this: this module has no Robolectric, and
 * `unitTests.isReturnDefaultValues = true` makes the Android stub jar's
 * `Uri.EMPTY` static initializer (itself built from stubbed methods)
 * resolve to `null`.
 */
internal class FakeUri : Uri() {
    override fun isHierarchical() = throw UnsupportedOperationException()
    override fun isRelative() = throw UnsupportedOperationException()
    override fun getScheme(): String = throw UnsupportedOperationException()
    override fun getSchemeSpecificPart(): String = throw UnsupportedOperationException()
    override fun getEncodedSchemeSpecificPart(): String = throw UnsupportedOperationException()
    override fun getAuthority(): String = throw UnsupportedOperationException()
    override fun getEncodedAuthority(): String = throw UnsupportedOperationException()
    override fun getUserInfo(): String = throw UnsupportedOperationException()
    override fun getEncodedUserInfo(): String = throw UnsupportedOperationException()
    override fun getHost(): String = throw UnsupportedOperationException()
    override fun getPort() = throw UnsupportedOperationException()
    override fun getPath(): String = throw UnsupportedOperationException()
    override fun getEncodedPath(): String = throw UnsupportedOperationException()
    override fun getQuery(): String = throw UnsupportedOperationException()
    override fun getEncodedQuery(): String = throw UnsupportedOperationException()
    override fun getFragment(): String = throw UnsupportedOperationException()
    override fun getEncodedFragment(): String = throw UnsupportedOperationException()
    override fun getPathSegments(): List<String> = throw UnsupportedOperationException()
    override fun getLastPathSegment(): String = throw UnsupportedOperationException()
    override fun toString() = "fake://test-only-uri"
    override fun buildUpon(): Builder = throw UnsupportedOperationException()
    override fun describeContents() = 0
    override fun writeToParcel(dest: Parcel, flags: Int) = throw UnsupportedOperationException()
}
