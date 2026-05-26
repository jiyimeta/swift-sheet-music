pluginManagement {
    repositories {
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
                // Plugin marker POM lives under io.github.jiyimeta.wirelet;
                // plugin artifact lives under io.github.jiyimeta — cover both.
                includeGroupByRegex("io\\.github\\.jiyimeta.*")
            }
        }
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // swift-java's swiftkit-core is not yet on Maven Central — propagated
        // via SheetMusicAndroid's `api` dep. Locally-published via
        // `cd .build/checkouts/swift-java && ./gradlew :SwiftKitCore:publishToMavenLocal`.
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
rootProject.name = "SheetMusicAndroidExample"
include(":app")

// Composite build: resolves SheetMusicAndroid and SheetMusicAudioAndroid from
// the sibling Android/ Gradle project instead of Maven Central.
includeBuild("../../Android") {
    dependencySubstitution {
        substitute(module("io.github.jiyimeta:sheet-music-audio-android"))
            .using(project(":SheetMusicAudioAndroid"))
        substitute(module("io.github.jiyimeta:sheet-music-android"))
            .using(project(":SheetMusicAndroid"))
    }
}
