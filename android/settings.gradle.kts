pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // Order is fine; keep all
        google()
        mavenCentral()
        gradlePluginPortal()
        // Flutter engine/embedding artifacts
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }
}

dependencyResolutionManagement {
    // Prefer central settings-level repos for all modules
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
        // Flutter engine/embedding artifacts
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // AGP (keep as you had it)
    id("com.android.application") version "8.7.0" apply false
    // Kotlin bumped to satisfy modern plugins
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}

include(":app")
