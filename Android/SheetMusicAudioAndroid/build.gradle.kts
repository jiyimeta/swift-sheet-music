plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
    id("io.github.jiyimeta.wirelet") version "0.1.0-alpha.2"
}

android {
    namespace = "io.github.jiyimeta.sheetmusic.audio"
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
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

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
        unitTests.all {
            // Default 512m is tight with coroutines-test; bump to 1g.
            it.jvmArgs("-Xmx1g")
        }
    }
}

group = "io.github.jiyimeta"
version = (project.findProperty("version") as String?)
    ?.takeIf { it != "unspecified" }
    ?: "0.0.0-SNAPSHOT"

val syncGoldenBinaries by tasks.registering(Copy::class) {
    from(rootProject.file("../Tests/SheetMusicTests/Resources/Golden/Audio"))
    into(file("src/test/resources/golden"))
    include("*.bin")
}

// Wire syncGoldenBinaries before the AGP tasks that stage test resources
// (debug + release unit-test variants) so the .bin files are on the classpath.
afterEvaluate {
    tasks.matching {
        it.name == "processDebugUnitTestJavaRes" || it.name == "processReleaseUnitTestJavaRes"
    }.configureEach {
        dependsOn(syncGoldenBinaries)
    }
}

dependencies {
    api(project(":SheetMusicAndroid"))

    // FluidSynth (LGPL-2.1 dynamic-link). Vetted in Task 1; see
    // docs/superpowers/notes/2026-05-19-fluidsynth-android-vetting.md
    api("net.volcanomobile.fluidsynth-android:fluidsynth-android:2.4.6")

    // Oboe (Apache-2.0) — low-latency PCM output
    api("com.google.oboe:oboe:1.9.0")

    api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")

    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test:runner:1.5.2")
}

val packageRoot: File = rootProject.projectDir.resolve("..").canonicalFile

wirelet {
    // Single source of truth via SwiftPM's Package.resolved — see
    // Android/SheetMusicAndroid/build.gradle.kts for context.
    swiftPackagePath.set(File(packageRoot, ".build/checkouts/swift-wirelet"))
    sources {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Sources/SheetMusicAndroidJNI/Audio"))
            codecPackage.set("io.github.jiyimeta.sheetmusic.audio.serialization")
            modelPackage.set("io.github.jiyimeta.sheetmusic.audio.model")
            stripNameSuffix.set("Wire")
            // emitModels intentionally NOT set (default false) — hand-written model
            // classes already exist under audio/model/ (Frame.kt, MetronomeBeat.kt,
            // ScoreCursor.kt, etc.). The codec output references them by name (the
            // "Wire" suffix is stripped via stripNameSuffix).
        }
    }
}

// Wire the wirelet-generated source directory into the Android source set
// and make every Kotlin compile task depend on codegen. The wirelet plugin
// v1 only hooks into kotlin.jvm; kotlin.android needs the same wiring added
// manually here.
val generateWireletCodecsMain = tasks.named("generateWireletCodecsMain")

android {
    sourceSets["main"].kotlin.srcDir(
        generateWireletCodecsMain.flatMap {
            (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletCodecs).outputDir
        }
    )
}

tasks.matching { it.name.startsWith("compile") && it.name.endsWith("Kotlin") }
    .configureEach { dependsOn(generateWireletCodecsMain) }

afterEvaluate {
    publishing {
        publications {
            register<MavenPublication>("release") {
                from(components["release"])
                groupId = "io.github.jiyimeta"
                artifactId = "sheet-music-audio-android"
                pom {
                    name.set("SheetMusic Audio Android")
                    description.set(
                        "FluidSynth-backed audio playback for swift-sheet-music on Android."
                    )
                    url.set("https://github.com/jiyimeta/swift-sheet-music")
                    licenses {
                        license {
                            name.set("MIT")
                            url.set("https://opensource.org/licenses/MIT")
                        }
                    }
                }
            }
        }
        repositories {
            maven {
                name = "GithubPackages"
                url = uri("https://maven.pkg.github.com/jiyimeta/swift-sheet-music")
                credentials {
                    username = System.getenv("GITHUB_ACTOR")
                        ?: project.findProperty("gpr.user") as String?
                    password = System.getenv("GITHUB_TOKEN")
                        ?: project.findProperty("gpr.token") as String?
                }
            }
        }
    }
}
