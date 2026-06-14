plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

repositories {
    mavenLocal()   // peat-btle 0.4.0 AAR published via `gradlew publishToMavenLocal`
    google()
    mavenCentral()
}

android {
    namespace = "com.defenseunicorns.peat_flutter_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.defenseunicorns.peat_flutter_example"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // peat-btle requires API 26+ (BLE mesh); raise from flutter.minSdkVersion.
        minSdk = maxOf(26, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // Disable R8/shrinking for release. `flutter build apk --release`
            // enables it by default, but it breaks this app's native stack:
            //   * it removes peat-ffi JNI methods (PeatJni) that are only called
            //     via dart:ffi, so the .so's bulk RegisterNatives aborts; and
            //   * it strips/renames com.sun.jna.** + the peat-btle uniffi
            //     bindings, which JNA resolves reflectively — killing the BLE
            //     transport entirely (no advertise/scan, no peers).
            // This is the demo example app; shrinking buys nothing here and the
            // keep-rule surface for JNA + uniffi is large and brittle, so turn
            // it off and let release behave like the (working) debug build.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // peat-btle Android: BLE mesh transport (scan/advertise/GATT + uniffi.peat_btle
    // core). Used as an opaque encrypted carrier — BleBridge pipes peat-ffi mesh
    // frames through PeatBtle.broadcastBytes / onDecryptedData. Transitive deps
    // (jna, kotlinx-coroutines, androidx.core) come via the AAR's POM.
    implementation("com.defenseunicorns:peat-btle:0.4.0")
}
