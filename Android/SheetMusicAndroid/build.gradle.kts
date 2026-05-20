plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
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
