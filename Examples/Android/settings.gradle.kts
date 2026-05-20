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
    }
}
rootProject.name = "SheetMusicAndroidExample"
include(":app")

// Composite build: resolves SheetMusicAudioAndroid from the sibling
// Android/ Gradle project instead of Maven Central.
includeBuild("../../Android") {
    dependencySubstitution {
        substitute(module("io.github.kiichiio:sheet-music-audio-android"))
            .using(project(":SheetMusicAudioAndroid"))
    }
}
