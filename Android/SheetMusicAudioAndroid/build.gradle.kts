plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
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

// ─── Wire-format codec codegen ────────────────────────────────────────
// Runs `swift run emit-kotlin-codecs` to regenerate Kotlin codecs from
// Swift `@WireFormat` types. See
// docs/superpowers/specs/2026-05-23-kotlin-codec-codegen-design.md.
val packageRoot: File = rootProject.projectDir.resolve("..").canonicalFile
val emitKotlinCodecsOutput = layout.buildDirectory.dir("generated/source/wire-format/kotlin")

val emitKotlinCodecs by tasks.registering(Exec::class) {
    workingDir(packageRoot)
    inputs.dir(packageRoot.resolve("Sources/SheetMusicAndroidJNI"))
        .withPropertyName("swiftSources")
    inputs.file(packageRoot.resolve("Sources/SheetMusicAndroidJNI/kotlin-codegen.json"))
        .withPropertyName("codegenConfig")
    outputs.dir(emitKotlinCodecsOutput)
    // Skip if outputs are already populated (pre-flight or prior run).
    onlyIf { !emitKotlinCodecsOutput.get().asFile.walk().any { it.isFile } }
    commandLine(
        "swift", "run", "--package-path", packageRoot.absolutePath,
        "emit-kotlin-codecs",
        "--config", "Sources/SheetMusicAndroidJNI/kotlin-codegen.json",
        "--source", "Sources/SheetMusicAndroidJNI",
        "--output", emitKotlinCodecsOutput.get().asFile.absolutePath,
    )
}

android {
    sourceSets["main"].kotlin.srcDir(emitKotlinCodecsOutput)
}

tasks.matching { it.name.startsWith("compile") && it.name.endsWith("Kotlin") }
    .configureEach { dependsOn(emitKotlinCodecs) }

// Exclude codecs that belong to other modules:
//  - SheetMusicAndroid: non-audio types in the top-level
//    io.github.jiyimeta.sheetmusic package (ScoreMetadata*, SMuFLMetrics*).
//  - Examples/Android app: com/example/sheetmusic draw codecs (they
//    reference the demo's model + BinaryReader/Writer).
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    exclude("io/github/jiyimeta/sheetmusic/ScoreMetadata*")
    exclude("io/github/jiyimeta/sheetmusic/SMuFLMetrics*")
    exclude("com/example/sheetmusic/**")
}

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
