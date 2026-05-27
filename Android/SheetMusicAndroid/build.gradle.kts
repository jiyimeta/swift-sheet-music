plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
    id("io.github.jiyimeta.wirelet") version "0.1.0-alpha.2"
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
    // wirelet-runtime provides BinaryReader/BinaryWriter used by
    // wirelet-generated codecs. `api` so downstream modules
    // (SheetMusicAudioAndroid, Examples/Android) see the classes
    // on their compile classpath.
    api("io.github.jiyimeta:wirelet-runtime:0.1.0-alpha.2")
}

val packageRoot: File = rootProject.projectDir.resolve("..").canonicalFile

wirelet {
    swiftPackagePath.set(File(packageRoot, "wirelet-checkout"))
    sources {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Sources/SheetMusicAndroidJNI/Metadata"))
            codecPackage.set("io.github.jiyimeta.sheetmusic")
            modelPackage.set("io.github.jiyimeta.sheetmusic")
            emitModels.set(true)
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
