# This module contributes no consumer keep rules, and that is a statement
# about it rather than an omission.
#
# Everything here is ordinary Kotlin and Compose: the score canvas, the
# playback-cursor and loop overlays, and the wirelet-generated draw-program
# codecs. Nothing is reached by name at runtime — no reflection, no JNI
# registration against a class in this module, no Service / Parcelable /
# Serializable entry point, no resource-driven class lookup. R8 can rename or
# remove anything it can prove unreachable and the module still works.
#
# The rules that DO matter for a consumer of this library live elsewhere and
# stay there:
#
#   * `sheet-music-android` keeps `SheetMusicJNI`, whose members the native
#     library resolves by name through System.loadLibrary. That is the module
#     that owns the JNI boundary, so that is where the keep rule belongs.
#   * The app keeps whatever ITS own entry points need.
#
# Until this release the module was never published, so its keep-rule story was
# private. It is consumer-facing now, which is why the answer is written down
# instead of being inferred from an empty file.
