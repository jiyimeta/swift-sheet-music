plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.example.sheetmusic"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.example.sheetmusic"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures { compose = true }

    // SheetMusicAndroid (Swift JNI runtime) and SheetMusicAudioAndroid
    // (CMake-built FluidSynth wrapper) both ship libc++_shared.so from
    // the NDK. Pick first to resolve the merge collision — both copies
    // are byte-identical NDK artefacts.
    packaging {
        jniLibs {
            pickFirsts += setOf("**/libc++_shared.so")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.09.02")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("androidx.media3:media3-session:1.5.0")
    implementation("androidx.media3:media3-common:1.5.0")
    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")

    // JNI bridge + audio backend — resolved from the Android/ composite build.
    // Versions must match the corresponding build.gradle.kts files in Android/.
    implementation("io.github.jiyimeta:sheet-music-android:0.0.0-SNAPSHOT")
    implementation("io.github.jiyimeta:sheet-music-audio-android:0.0.0-SNAPSHOT")
}
