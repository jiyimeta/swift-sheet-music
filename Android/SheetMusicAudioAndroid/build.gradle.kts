plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.github.kiichiio.sheetmusic.audio"
    compileSdk = 35

    buildFeatures {
        buildConfig = false
        prefab = true   // surfaces fluidsynth headers from the .aar via Prefab
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    defaultConfig {
        minSdk = 28
        consumerProguardFiles("proguard-consumer.pro")

        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++17")
                arguments += listOf(
                    "-DANDROID_STL=c++_shared",
                )
            }
        }
        ndk {
            // Match Phase 4 non-audio's ABI set
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = "17" }

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

// Wire syncGoldenBinaries before the AGP task that stages test resources
// for the debug unit-test variant so the .bin files are on the classpath.
afterEvaluate {
    tasks.matching { it.name == "processDebugUnitTestJavaRes" }.configureEach {
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
