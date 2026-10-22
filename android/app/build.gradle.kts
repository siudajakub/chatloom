import java.util.Properties
import java.io.FileInputStream
import java.nio.file.Files

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Frame benchmarks (docs/performance-benchmarks.md) install a
// separate app, pl.personal.chat.perf, next to the real one and never over it:
// `flutter drive` uninstalls an app whose signature differs, which would delete
// the real app's data. Set by scripts/perf/run-benchmarks.sh; no push.
val perfBenchmark = project.findProperty("chatloomPerfBenchmark")?.toString() == "true"

val googleServicesFile = file("google-services.json")
if (perfBenchmark) {
    logger.warn("Performance benchmark build: applicationId pl.personal.chat.perf, no Firebase.")
} else if (googleServicesFile.exists()) {
    apply(plugin = "com.google.gms.google-services")
} else {
    // Without the Firebase configuration the APK builds and starts, but FCM
    // can never issue a token, so push notifications silently never work.
    // A symlink to a missing file (a Mac path on the Linux devbox) counts as
    // missing. Release builds stop here; pass -Pchatloom.allowNoFirebase=true
    // only for a deliberate build without push.
    val reason = if (Files.isSymbolicLink(googleServicesFile.toPath())) {
        "android/app/google-services.json is a symlink to a missing file"
    } else {
        "android/app/google-services.json is missing"
    }
    val allowNoFirebase = project.findProperty("chatloom.allowNoFirebase")?.toString() == "true"
    logger.warn("WARNING: $reason; this build cannot receive push notifications.")
    tasks.matching { it.name == "preReleaseBuild" }.configureEach {
        doFirst {
            if (!allowNoFirebase) {
                throw GradleException(
                    "$reason: a release APK without Firebase cannot receive push " +
                        "notifications. Restore the private Firebase config (see " +
                        "push-gateway/README.md) or pass -Pchatloom.allowNoFirebase=true.",
                )
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4") // For flutter_local_notifications // Workaround for: https://github.com/MaikuB/flutter_local_notifications/issues/2286
    implementation("androidx.core:core-ktx:1.17.0") // For Android Auto
    testImplementation("junit:junit:4.12") // Pure-Kotlin round capture geometry tests (src/test)
}


// Workaround for https://pub.dev/packages/unifiedpush#the-build-fails-because-of-duplicate-classes
configurations.all {
    // Use the latest version published: https://central.sonatype.com/artifact/com.google.crypto.tink/tink-android
    val tink = "com.google.crypto.tink:tink-android:1.23.0"
    // You can also use the library declaration catalog
    // val tink = libs.google.tink
    resolutionStrategy {
        force(tink)
        dependencySubstitution {
            substitute(module("com.google.crypto.tink:tink")).using(module(tink))
        }
    }
}


android {
    namespace = "pl.personal.chatloom"
    // Workaround for https://github.com/juliansteenbakker/flutter_secure_storage/issues/1224
    compileSdk = 37 //flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    signingConfigs {
       create("release") {}
    }

    val keystoreProperties = Properties()
    val keystorePropertiesFile = rootProject.file("key.properties")
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
        signingConfigs.getByName("release").apply {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

    defaultConfig {
        applicationId = "pl.personal.chat"
        if (perfBenchmark) {
            applicationIdSuffix = ".perf"
        }
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // Filter plugin libraries as well as Flutter's arm64 release output.
            abiFilters.clear()
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            // R8 optimisation on (the non-optimize file adds -dontoptimize);
            // keep rules for reflection-based plugins are in proguard-rules.pro.
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
    }
}


flutter {
    source = "../.."
}
