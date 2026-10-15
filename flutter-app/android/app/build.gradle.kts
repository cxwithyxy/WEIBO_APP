import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 固定签名（2026-10-15）────────────────────────────────────────────────
// key.properties 与 keys/weibo-release.jks 都是**故意公开**的。
// 目的：任何人 clone 后编出来的 APK 与原版签名一致 → 可以互相覆盖安装，
// 包括 GitHub Actions 自动发的版本。详见 android/keys/README.md
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}
val hasReleaseKey =
    keystorePropertiesFile.exists() && keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.cx.weibo.android"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.cx.weibo.android"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 有 key.properties 就用固定 key（公开，可互相覆盖安装）；
            // 没有就退回 debug key，保证 `flutter run --release` 仍能用。
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    // ⚠️ 体积相关的关键开关（2026-10-15 测出：不加这个，26.5MB 里 25.6MB 是原生库
    // 且**全部以 STORE 存储（0% 压缩）**）。
    //
    // AGP 对 minSdk≥23 默认 extractNativeLibs=false → .so 不压缩、页对齐（启动快，
    // 但 APK 大）。打开 useLegacyPackaging 后 .so 会被 deflate 压缩，
    // **下载体积大幅下降**（代价：安装时解压，安装足迹与首次启动略增）。
    packaging {
        jniLibs {
            useLegacyPackaging = true
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
