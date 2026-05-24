plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
}

android {
    namespace = "io.github.jiyimeta.sheetmusic"
    compileSdk = 35

    defaultConfig {
        minSdk = 28
        consumerProguardFiles("proguard-consumer.pro")
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = "17" }

    // Prebuilt libSheetMusicJNI.so + libSheetMusicJNISwiftJava.so +
    // Swift runtime live here. They are staged by
    // Scripts/android-build-libs.sh before any Gradle task that
    // consumes them (assembleRelease / publish).
    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")

    // swift-java jextract output (Java bindings) is copied here by
    // Scripts/android-build-libs.sh from the SwiftPM plugin output
    // directory. The directory is gitignored — regenerate via the
    // script before any Gradle invocation that compiles sources.
    sourceSets["main"].java.srcDirs("src/main/java-generated")

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

group = "io.github.jiyimeta"
version = (project.findProperty("version") as String?)
    ?.takeIf { it != "unspecified" }
    ?: "0.0.0-SNAPSHOT"

dependencies {
    // Runtime support for swift-java-generated Java bindings under
    // src/main/java-generated/ (PoC adoption). `api` so downstream
    // modules using the generated `SheetMusicAndroidJNISwiftJava`
    // class get `org.swift.swiftkit.core.*` on their classpath.
    // Locally-published from the swift-java repo until it ships to
    // Maven Central — see project_swift_java_strategy.md.
    api("org.swift.swiftkit:swiftkit-core:1.0-SNAPSHOT")
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
    // This module owns the top-level io.github.jiyimeta.sheetmusic codecs
    // (ScoreMetadata + SMuFLMetrics) and the shared wireformat runtime —
    // wireformat itself is hand-written, so we don't ask the generator
    // for it. Audio + Examples-app codecs are emitted by their own
    // modules' :emitKotlinCodecs tasks.
    commandLine(
        "swift", "run", "--package-path", packageRoot.absolutePath,
        "emit-kotlin-codecs",
        "--config", "Sources/SheetMusicAndroidJNI/kotlin-codegen.json",
        "--source", "Sources/SheetMusicAndroidJNI",
        "--output", emitKotlinCodecsOutput.get().asFile.absolutePath,
        "--include-package", "io.github.jiyimeta.sheetmusic",
    )
}

android {
    sourceSets["main"].kotlin.srcDir(emitKotlinCodecsOutput)
}

tasks.matching { it.name.startsWith("compile") && it.name.endsWith("Kotlin") }
    .configureEach { dependsOn(emitKotlinCodecs) }


afterEvaluate {
    publishing {
        publications {
            register<MavenPublication>("release") {
                from(components["release"])
                groupId = "io.github.jiyimeta"
                artifactId = "sheet-music-android"
                // Version comes from the top-level `version = …` declaration.
                pom {
                    name.set("SheetMusic Android")
                    description.set(
                        "Kotlin/JNI bindings for swift-sheet-music: " +
                            "score parsing, engraving layout, cursor resolution."
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
