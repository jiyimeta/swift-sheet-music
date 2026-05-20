# SheetMusicAndroid

Kotlin/JNI bindings for [swift-sheet-music](https://github.com/jiyimeta/swift-sheet-music)
covering score parsing, engraving layout, and cursor resolution.

This module ships the prebuilt `libSheetMusicJNI.so` for the supported
ABIs (`arm64-v8a`, `x86_64`) inside the AAR, so consumers do not need
a Swift toolchain.

## Consuming from a Kotlin / Compose app

Add the GitHub Packages Maven repository (see "Authentication" below for
the credentials block) and the dependency:

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven {
            name = "SheetMusicGithubPackages"
            url = uri("https://maven.pkg.github.com/jiyimeta/swift-sheet-music")
            credentials {
                username = providers.gradleProperty("gpr.user").orNull
                    ?: System.getenv("GITHUB_ACTOR")
                password = providers.gradleProperty("gpr.token").orNull
                    ?: System.getenv("GITHUB_TOKEN")
            }
        }
    }
}

// app/build.gradle.kts
dependencies {
    implementation("io.github.jiyimeta:sheet-music-android:<version>")
}
```

## Authentication

GitHub Packages requires authentication even for downloads from public
packages, so every consumer needs a Personal Access Token (PAT) with
the `read:packages` scope.

Set the credentials via either:

- `~/.gradle/gradle.properties` (developer-local):
  ```
  gpr.user=<your-github-username>
  gpr.token=<your-pat-with-read-packages>
  ```
- Environment variables (CI):
  ```
  GITHUB_ACTOR=<github-username>
  GITHUB_TOKEN=<pat>
  ```

## Usage

```kotlin
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.ScoreHandle
import io.github.jiyimeta.sheetmusic.BravuraMetricsBuilder

val table = BravuraMetricsBuilder.buildTable(context.assets)
SheetMusicJNI.nativeInstallSMuFLMetrics(table)

val bytes = context.assets.open("score.mscz").use { it.readBytes() }
val handle = ScoreHandle.load(bytes)
    ?: error("Failed to parse score")

val layout = SheetMusicJNI.nativeComputeLayout(
    scoreHandle = handle.raw,
    pageWidthMM = 210.0,
    pageHeightMM = 297.0,
)
// Decode `layout` with the DrawProgram wire format and render to Canvas.
```

See `Examples/Android/` in this repository for a complete Jetpack
Compose integration.

## ABI matrix

| ABI         | Status |
|-------------|--------|
| arm64-v8a   | Supported (primary) |
| x86_64      | Supported (emulator) |
| armv7       | Not supported |

Minimum SDK: 28 (Android 9).

## License

MIT. Includes a prebuilt `libSheetMusicJNI.so` produced from the
MIT-licensed Swift sources in this repository.
