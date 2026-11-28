import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load release signing config from `android/key.properties` if it exists.
// That file (and the keystore it points at) are gitignored — never commit them.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.cps_emulator"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "ble.make.bike.gotta"
        // Pinned, not Flutter's defaults, so a Flutter upgrade can't silently
        // change which phones can install the app or how Android treats it.
        // minSdk 24 (Android 7.0): BLE advertising works there, and old
        // spare phones are a common choice for a sensor on a trainer.
        // targetSdk 36 (Android 16): what Google Play requires for new apps
        // and updates since 2026-08-31. Raise it deliberately each year and
        // re-test (Android 17 / API 37 drops the large-screen orientation
        // and resizability opt-outs). See store/release-checklist.md.
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // Populated only when key.properties is present; otherwise the
            // release build falls back to debug signing (see buildTypes below).
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Use the real release keystore when configured; otherwise sign with
            // the debug keys so `flutter build apk --release` still works locally
            // and in CI without the secret keystore.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
