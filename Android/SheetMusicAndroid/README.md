# SheetMusicAndroid

Kotlin/JNI bindings for [swift-sheet-music](https://github.com/jiyimeta/swift-sheet-music)
covering score parsing, engraving layout, and cursor resolution.

This module ships the prebuilt `libSheetMusicJNI.so` for the supported
ABIs (`arm64-v8a`, `x86_64`) inside the AAR, so consumers do **not** need
a Swift compiler toolchain.

## What you need to consume it

The AAR itself is prebuilt, but it exposes two transitive dependencies
that are not yet on Maven Central, so consuming it is a little more
involved than a single `implementation(...)` line. You need:

1. A **GitHub Personal Access Token** with `read:packages` — GitHub
   Packages requires auth even for public packages. The same token covers
   both `swift-sheet-music` (the AAR) and `swift-wirelet` (the
   `wirelet-runtime` classpath dependency).
2. **`org.swift.swiftkit:swiftkit-core` published to your Maven local**
   (`~/.m2`) — swift-java's Java runtime is not on Maven Central yet, so
   you publish it once from source (a Gradle build, no Swift toolchain).

> These two steps are the friction we're tracking toward removal; a future
> release aims to put the artifacts on Maven Central. For now they are
> required. (The Apple / SwiftPM side has none of this — see the top-level
> README.)

### 1. Repositories (`settings.gradle.kts`)

```kotlin
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // swiftkit-core is published here by step 3 below.
        mavenLocal {
            content {
                includeGroupByRegex("org\\.swift\\.swiftkit.*")
            }
        }
        // The AAR (io.github.jiyimeta:sheet-music-*).
        maven {
            name = "SheetMusicGitHubPackages"
            url = uri("https://maven.pkg.github.com/jiyimeta/swift-sheet-music")
            credentials {
                username = providers.gradleProperty("gpr.user").orNull
                    ?: System.getenv("GITHUB_ACTOR")
                password = providers.gradleProperty("gpr.token").orNull
                    ?: System.getenv("GITHUB_TOKEN")
            }
            content { includeGroupByRegex("io\\.github\\.jiyimeta.*") }
        }
        // wirelet-runtime, a transitive `api` dependency of the AAR.
        maven {
            name = "WireletGitHubPackages"
            url = uri("https://maven.pkg.github.com/jiyimeta/swift-wirelet")
            credentials {
                username = providers.gradleProperty("gpr.user").orNull
                    ?: System.getenv("GITHUB_ACTOR")
                password = providers.gradleProperty("gpr.token").orNull
                    ?: System.getenv("GITHUB_TOKEN")
            }
            content { includeGroupByRegex("io\\.github\\.jiyimeta.*") }
        }
    }
}
```

### 2. Credentials (the PAT)

Set them via `~/.gradle/gradle.properties` (developer-local):

```
gpr.user=<your-github-username>
gpr.token=<your-pat-with-read-packages>
```

or environment variables (CI): `GITHUB_ACTOR=<username>`,
`GITHUB_TOKEN=<pat>`.

### 3. Publish SwiftKitCore to Maven local (one-time)

The AAR's POM declares `org.swift.swiftkit:swiftkit-core:1.0-SNAPSHOT`,
which is not on Maven Central. Publish it once from swift-java (pinned to
the version this release builds against — **0.4.0**):

```bash
git clone --branch 0.4.0 --depth 1 https://github.com/swiftlang/swift-java.git
cd swift-java
./gradlew :SwiftKitCore:publishToMavenLocal
```

This is a Gradle/Java build — no Swift toolchain required. Re-run it only
if you clear `~/.m2` or the pinned swift-java version changes.

### 4. Add the dependency and packaging (`app/build.gradle.kts`)

```kotlin
android {
    defaultConfig {
        minSdk = 28
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    packaging {
        jniLibs {
            // The base and audio AARs each bundle their own libc++_shared.so.
            pickFirsts += setOf("**/libc++_shared.so")
        }
    }
}

dependencies {
    implementation("io.github.jiyimeta:sheet-music-android:1.0.0")
    // Optional: FluidSynth + Oboe playback.
    // implementation("io.github.jiyimeta:sheet-music-audio-android:1.0.0")
}
```

## Usage

```kotlin
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.ScoreHandle
import io.github.jiyimeta.sheetmusic.BravuraMetricsBuilder

// Measure the metrics table and install it before laying anything out.
// Build it with the builder that ships in this AAR rather than caching
// bytes across versions: the format is versioned, and the install returns
// false for an older table rather than engraving off it.
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
