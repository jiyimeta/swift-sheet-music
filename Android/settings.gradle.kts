pluginManagement {
    repositories {
        mavenLocal()
        google()
        mavenCentral()
        gradlePluginPortal()
        maven {
            name = "WireletGitHubPackages"
            url = uri("https://maven.pkg.github.com/jiyimeta/swift-wirelet")
            credentials {
                username = System.getenv("GITHUB_ACTOR")
                    ?: providers.gradleProperty("gpr.user").orNull
                password = System.getenv("GITHUB_TOKEN")
                    ?: providers.gradleProperty("gpr.key").orNull
            }
            content {
                includeGroup("io.github.jiyimeta")
            }
        }
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // swift-java's swiftkit-core is not yet on Maven Central
        // (see project_swift_java_strategy.md). Local-publish via
        // `cd swift-java && ./gradlew :SwiftKitCore:publishToMavenLocal`.
        mavenLocal()
        maven {
            name = "WireletGitHubPackages"
            url = uri("https://maven.pkg.github.com/jiyimeta/swift-wirelet")
            credentials {
                username = System.getenv("GITHUB_ACTOR")
                    ?: providers.gradleProperty("gpr.user").orNull
                password = System.getenv("GITHUB_TOKEN")
                    ?: providers.gradleProperty("gpr.key").orNull
            }
            content {
                includeGroup("io.github.jiyimeta")
            }
        }
    }
}

rootProject.name = "swift-sheet-music-android"
include(":SheetMusicAudioAndroid")
include(":SheetMusicAndroid")
