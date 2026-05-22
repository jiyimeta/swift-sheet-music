pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
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
    }
}

rootProject.name = "swift-sheet-music-android"
include(":SheetMusicAudioAndroid")
include(":SheetMusicAndroid")
