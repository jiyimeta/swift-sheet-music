plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.github.kiichiio.sheetmusic.audio"
    compileSdk = 35

    defaultConfig {
        minSdk = 28
        consumerProguardFiles("proguard-consumer.pro")
    }

    buildFeatures {
        buildConfig = false
        prefab = true   // For finding fluidsynth headers from the .aar
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = "17" }

    // TODO Phase 9: enable externalNativeBuild + CMakeLists.txt so
    // libsheetmusicaudio.so wraps libfluidsynth.so via the Prefab
    // package above. Until then, this module ships pure-Kotlin code.

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

group = "io.github.kiichiio"
version = "0.0.0-SNAPSHOT"

val syncGoldenBinaries by tasks.registering(Copy::class) {
    from(rootProject.file("../Tests/SheetMusicTests/Resources/Golden/Audio"))
    into(file("src/test/resources/golden"))
    include("*.bin")
}

// Wire syncGoldenBinaries into the debug unit-test compile graph.
// processDebugUnitTestJavaRes is the AGP task that stages test resources
// for the debug unit-test variant; testDebugUnitTest depends on it.
afterEvaluate {
    tasks.matching { it.name == "testDebugUnitTest" }.configureEach {
        dependsOn(syncGoldenBinaries)
    }
}

dependencies {
    // FluidSynth (LGPL-2.1 dynamic-link). Vetted in Task 1; see
    // docs/superpowers/notes/2026-05-19-fluidsynth-android-vetting.md
    api("net.volcanomobile.fluidsynth-android:fluidsynth-android:2.4.6")

    // Oboe (Apache-2.0) — low-latency PCM output
    api("com.google.oboe:oboe:1.9.0")

    api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
}
