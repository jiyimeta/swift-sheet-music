# The JVM binds SwiftySynthNative.nativeRender to the Swift library's hand-written JNI function by name
# (Java_io_github_jiyimeta_sheetmusic_audio_synth_SwiftySynthNative_nativeRender); renaming either breaks the binding.
-keepclasseswithmembernames class io.github.jiyimeta.sheetmusic.audio.synth.SwiftySynthNative {
    native <methods>;
}
