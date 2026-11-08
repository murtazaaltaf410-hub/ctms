import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Google Maps keys are never committed. Put them in android/local.properties (gitignored):
//   MAPS_API_KEY_STAGING=...   MAPS_API_KEY_PROD=...   (or one shared MAPS_API_KEY=...)
// or export the same names as environment variables (CI).
val localProperties = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

fun mapsApiKey(flavor: String): String {
    val specific = "MAPS_API_KEY_${flavor.uppercase()}"
    return localProperties.getProperty(specific)
        ?: System.getenv(specific)
        ?: localProperties.getProperty("MAPS_API_KEY")
        ?: System.getenv("MAPS_API_KEY")
        ?: ""
}

android {
    namespace = "in.edu.uok.ctms.ctms"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Production package; the staging flavour adds ".staging" (separate Firebase/Maps apps).
        applicationId = "in.edu.uok.ctms"
        // firebase_*, flutter_secure_storage and geolocator need API 23+.
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "env"
    productFlavors {
        create("staging") {
            dimension = "env"
            applicationIdSuffix = ".staging"
            versionNameSuffix = "-staging"
            manifestPlaceholders["appLabel"] = "CTMS Staging"
            manifestPlaceholders["mapsApiKey"] = mapsApiKey("staging")
        }
        create("prod") {
            dimension = "env"
            manifestPlaceholders["appLabel"] = "CTMS"
            manifestPlaceholders["mapsApiKey"] = mapsApiKey("prod")
        }
    }

    buildTypes {
        release {
            // TODO(P9): release signing config per flavour (key.properties, never committed).
            signingConfig = signingConfigs.getByName("debug")
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
