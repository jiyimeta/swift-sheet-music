package io.github.kiichiio.sheetmusic.audio

import android.net.Uri

/** Resolves SoundFont file URIs for the Android audio backend. */
interface SoundfontResolver {
    fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri?
    val defaultGmSoundfontUri: Uri?
}
