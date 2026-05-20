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

    // Prebuilt libSheetMusicJNI.so + Swift runtime live here. They
    // are staged by Scripts/android-build-libs.sh before any Gradle
    // task that consumes them (assembleRelease / publish).
    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

group = "io.github.jiyimeta"
version = "0.0.0-SNAPSHOT"

dependencies {
    // No third-party deps. Pure JNI bindings + a Kotlin façade.
    // AndroidX / Compose live in consumer apps, not here.
}

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
