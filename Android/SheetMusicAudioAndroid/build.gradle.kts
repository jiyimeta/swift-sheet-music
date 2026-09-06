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
    androidTestImplementation("androidx.test:runner:1.7.0")
}

val packageRoot: File = rootProject.projectDir.resolve("..").canonicalFile

wirelet {
    // Single source of truth via SwiftPM's Package.resolved — see
    // Android/SheetMusicAndroid/build.gradle.kts for context.
    swiftPackagePath.set(File(packageRoot, ".build/checkouts/swift-wirelet"))
    sources {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Sources/SheetMusicBridgeCore/Audio"))
            codecPackage.set("io.github.jiyimeta.sheetmusic.audio.serialization")
            modelPackage.set("io.github.jiyimeta.sheetmusic.audio.model")
            stripNameSuffix.set("Wire")
            // emitModels intentionally NOT set (default false) — hand-written model
            // classes already exist under audio/model/ (Frame.kt, MetronomeBeat.kt,
            // ScoreCursor.kt, etc.). The codec output references them by name (the
            // "Wire" suffix is stripped via stripNameSuffix).
        }
        // The score-address schema (ScoreItemID / NoteID / RestID / TupletID /
        // VoiceElementID / StaffAddress / ClefAnchor) lives in its own SwiftPM
        // target, SheetMusicEditWire, so ssm and Folino link one declaration of
        // it instead of two mirrors. It used to sit under
        // Sources/SheetMusicAndroidJNI/Audio and so came along for free with the
        // "main" scan above; a schemaPaths entry must resolve to exactly one
        // directory, so the second location needs a second source set rather
        // than a second path here.
        //
        // Same codecPackage/modelPackage as "main" on purpose: these codecs are
        // referenced by the generated ScoreCursorCodec / AudioExportRangeCodec
        // and by AndroidPlaybackEngine, and their model classes are the
        // hand-written ones under audio/model/ (ScoreItemID.kt, NoteID.kt, …).
        // Only SheetMusicEditWire/Path is scanned — Intent/ holds the edit-intent
        // schema, which has no Kotlin model classes here and must not be emitted.
        //
        // The corollary, and the reason `:SheetMusicAudioAndroid:compileDebugKotlin`
        // broke on the reference family (MeasureRef / PartRef / VoiceRef /
        // VoiceElementRange): a new `@WireFormat` mirror under Path/ needs a
        // hand-written model added here in the same change, because the generated
        // codec references it by name and nothing else checks that it exists.
        register("editWire") {
            schemaPaths.from(packageRoot.resolve("Sources/SheetMusicEditWire/Path"))
            codecPackage.set("io.github.jiyimeta.sheetmusic.audio.serialization")
            modelPackage.set("io.github.jiyimeta.sheetmusic.audio.model")
            stripNameSuffix.set("Wire")
        }
        // The two payloads a host exchanges with the editing-geometry JNI entry points:
        // `SelectionTintWire` (what `nativeEncodeDrawProgram` tints with) and
        // `EditCaretFrameWire` (what `nativeEditingCaretFrame` answers). A Kotlin host cannot
        // reach either without a codec, and hand-writing one would put a second spelling of a
        // frozen schema in a second language — the thing one shared wire product exists to
        // prevent. They sit in their own directory rather than beside the edit intent because a
        // schemaPaths entry must resolve to exactly one directory and the intent vocabulary must
        // NOT be emitted here (see the note above).
        //
        // emitModels IS set, unlike the two source sets above: `SelectionTint` and
        // `EditCaretFrame` have no hand-written Kotlin counterparts under audio/model/, so the
        // generator has to supply them. `SelectionTint.items` resolves to the hand-written
        // `ScoreItemID` in the same modelPackage.
        register("editGeometry") {
            schemaPaths.from(packageRoot.resolve("Sources/SheetMusicEditWire/Geometry"))
            codecPackage.set("io.github.jiyimeta.sheetmusic.audio.serialization")
            modelPackage.set("io.github.jiyimeta.sheetmusic.audio.model")
            stripNameSuffix.set("Wire")
            emitModels.set(true)
        }
        // The edit-intent vocabulary itself.
        //
        // This registration used to be deliberately absent, and the note above the "editWire" one
        // said so: "Intent/ holds the edit-intent schema, which has no Kotlin model classes here and
        // must not be emitted." That was true while the intent types had no Kotlin counterparts —
        // emitting codecs that reference models nobody wrote is a build failure, not a feature.
        //
        // `emitModels = true` is what changes the answer. The generator now supplies the models as
        // well as the codecs, so nothing has to be hand-written, and the types the intents reference
        // from Path/ (MeasureRef, NoteID, StaffAddress, …) resolve to the hand-written classes in
        // the same modelPackage — exactly the relationship "editWire" already has.
        //
        // Why it matters: without this, `nativeApplyEditIntent` could only relay opaque bytes
        // authored somewhere else, so an Android host could hit-test, place a caret, undo and redo —
        // and never originate an edit. An Apple host has the whole `EditCommand` set and the browser
        // has a typed `EditIntent` union; Android was the only one of the three that could not
        // author one.
        register("editIntent") {
            schemaPaths.from(packageRoot.resolve("Sources/SheetMusicEditWire/Intent"))
            codecPackage.set("io.github.jiyimeta.sheetmusic.audio.serialization")
            modelPackage.set("io.github.jiyimeta.sheetmusic.audio.model")
            stripNameSuffix.set("Wire")
            emitModels.set(true)
        }
    }
}

// Wire the wirelet-generated source directories into the Android source set
// and make every Kotlin compile task depend on codegen. The wirelet plugin
// v1 only hooks into kotlin.jvm; kotlin.android needs the same wiring added
// manually here. It also only auto-wires a source set literally named "main",
// so "editWire" / "editGeometry" rely on this block entirely.
val generateWireletCodecsMain = tasks.named("generateWireletCodecsMain")
val generateWireletCodecsEditWire = tasks.named("generateWireletCodecsEditWire")
val generateWireletCodecsEditGeometry = tasks.named("generateWireletCodecsEditGeometry")
val generateWireletCodecsEditIntent = tasks.named("generateWireletCodecsEditIntent")
val wireletCodegenTasks = listOf(
    generateWireletCodecsMain,
    generateWireletCodecsEditWire,
    generateWireletCodecsEditGeometry,
    generateWireletCodecsEditIntent,
)

android {
    wireletCodegenTasks.forEach { codegen ->
        sourceSets["main"].kotlin.srcDir(
            codegen.flatMap {
                (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletCodecs).outputDir
            }
        )
    }
}

tasks.matching { it.name.startsWith("compile") && it.name.endsWith("Kotlin") }
    .configureEach { dependsOn(wireletCodegenTasks) }

// The sources jar (withSourcesJar) packs the wirelet-generated source dirs, so it
// must run after codegen. Declare the dependency explicitly to satisfy Gradle's
// task-validation — otherwise publishToMavenLocal fails on sourceReleaseJar.
tasks.matching { it.name == "sourceReleaseJar" }
    .configureEach { dependsOn(wireletCodegenTasks) }

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
