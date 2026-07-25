plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    `maven-publish`
    id("io.github.jiyimeta.wirelet") version "0.1.0-alpha.2"
}

android {
    namespace = "io.github.jiyimeta.sheetmusic.compose"
    compileSdk = 35

    defaultConfig {
        minSdk = 28
        consumerProguardFiles("proguard-consumer.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures { compose = true }

    publishing {
        singleVariant("release") { withSourcesJar() }
    }
}

group = "io.github.jiyimeta"
version = (project.findProperty("version") as String?)
    ?.takeIf { it != "unspecified" }
    ?: "0.0.0-SNAPSHOT"

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.09.02")
    api(composeBom)
    api("androidx.compose.ui:ui")
    api("androidx.compose.foundation:foundation")
    // ScoreCursor / LoopRange model types referenced by the overlays + their
    // wirelet codecs (ScoreCursorCodec) live in the audio module.
    api(project(":SheetMusicAudioAndroid"))
    testImplementation("junit:junit:4.13.2")
}

val packageRoot: File = rootProject.projectDir.resolve("..").canonicalFile

wirelet {
    swiftPackagePath.set(File(packageRoot, ".build/checkouts/swift-wirelet"))
    sources {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Sources/SheetMusicAndroidJNI/Draw"))
            codecPackage.set("io.github.jiyimeta.sheetmusic.compose.draw")
            modelPackage.set("io.github.jiyimeta.sheetmusic.compose.draw.model")
            // Hand-written model classes are moved into draw/model/ in a later task,
            // matching the example (emitModels stays false / default).
        }
    }
}

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

// The sources jar (withSourcesJar) packs the wirelet-generated source dir, so it
// must run after codegen. Declare the dependency explicitly to satisfy Gradle's
// task-validation — otherwise publishToMavenLocal fails on sourceReleaseJar.
tasks.matching { it.name == "sourceReleaseJar" }
    .configureEach { dependsOn(generateWireletCodecsMain) }

afterEvaluate {
    publishing {
        publications {
            register<MavenPublication>("release") {
                from(components["release"])
                groupId = "io.github.jiyimeta"
                artifactId = "sheet-music-compose-android"
                pom {
                    name.set("SheetMusic Compose Android")
                    description.set(
                        "Jetpack Compose rendering for swift-sheet-music draw programs: " +
                            "score canvas, playback-cursor and loop overlays, bundled SMuFL fonts."
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
