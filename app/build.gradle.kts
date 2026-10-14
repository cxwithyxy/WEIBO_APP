plugins {
    id("com.android.application")
    kotlin("android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// ===========================================================================
// Rust 核心构建集成
//
//   rust/                         Rust crate（微博核心，UniFFI 导出）
//   rust/build/uniffi/            自动生成的 Kotlin 绑定（编译进 app）
//   app/src/main/jniLibs/<abi>/   cargo-ndk 交叉编译出的 .so
//
// 用 -PskipRust 可跳过 Rust 构建（复用已有产物，便于快速改 UI）。
// ===========================================================================

val rustDir = rootProject.layout.projectDirectory.dir("rust").asFile
val uniffiOutDir = File(rustDir, "build/uniffi")
val jniLibsDir = File(projectDir, "src/main/jniLibs")
val skipRust = providers.gradleProperty("skipRust").isPresent

// cargo / cargo-ndk 需要在 PATH 上；Gradle 继承启动它的 shell，这里显式兜底
//
// 注意：Java 的 ProcessBuilder 解析不带路径的命令时用的是**父进程**的 PATH，
// 不认 Exec task 里设置的 environment —— 所以这里必须用 cargo 的绝对路径。
val cargoExe: String = run {
    val p = File(System.getProperty("user.home"), ".cargo/bin/cargo")
    if (p.canExecute()) p.absolutePath else "cargo"
}

val execEnv: Map<String, String> = run {
    val cargoBin = File(System.getProperty("user.home"), ".cargo/bin")
    val ndk = System.getenv("ANDROID_NDK_HOME")
        ?: runCatching { android.ndkDirectory.absolutePath }.getOrNull()
        ?: ""
    buildMap {
        put("PATH", "${cargoBin.absolutePath}:${System.getenv("PATH") ?: ""}")
        if (ndk.isNotEmpty()) {
            put("ANDROID_NDK_HOME", ndk)
            put("ANDROID_NDK_ROOT", ndk)
        }
        // 首次拉依赖需要网络；沿用当前 shell 的代理设置（如有）
        listOf("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "no_proxy")
            .forEach { k -> System.getenv(k)?.let { put(k, it) } }
    }
}

/** 主机平台上的 cdylib 文件名（uniffi-bindgen 需要它来读取元数据） */
val hostLibName: String = when {
    System.getProperty("os.name").startsWith("Mac") -> "libweibo_core.dylib"
    System.getProperty("os.name").startsWith("Windows") -> "weibo_core.dll"
    else -> "libweibo_core.so"
}

val buildRustHost by tasks.registering(Exec::class) {
    group = "rust"
    description = "构建 Rust 核心（host，供生成绑定）"
    workingDir = rustDir
    environment(execEnv)
    commandLine(cargoExe, "build", "--lib", "--release")
    inputs.dir(File(rustDir, "src"))
    inputs.file(File(rustDir, "Cargo.toml"))
    outputs.dir(File(rustDir, "target/release"))
}

val genUniffiBindings by tasks.registering(Exec::class) {
    group = "rust"
    description = "生成 Kotlin 绑定到 rust/build/uniffi"
    dependsOn(buildRustHost)
    workingDir = rustDir
    environment(execEnv)
    commandLine(
        cargoExe, "run", "--quiet", "--bin", "uniffi-bindgen", "--",
        "generate",
        "--library", File(File(rustDir, "target/release"), hostLibName).absolutePath,
        "--language", "kotlin",
        "--out-dir", uniffiOutDir.absolutePath,
        "--no-format",
    )
    inputs.dir(File(rustDir, "src"))
    outputs.dir(uniffiOutDir)
}

val buildRustAndroid by tasks.registering(Exec::class) {
    group = "rust"
    description = "交叉编译 Rust 核心到 Android（arm64-v8a / armeabi-v7a / x86_64）"
    workingDir = rustDir
    environment(execEnv)
    commandLine(
        cargoExe, "ndk",
        "-t", "arm64-v8a",
        "-t", "armeabi-v7a",
        "-t", "x86_64",
        "-o", jniLibsDir.absolutePath,
        "build", "--release",
    )
    inputs.dir(File(rustDir, "src"))
    outputs.dir(jniLibsDir)
}

android {
    namespace = "com.cx.weibo.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.cx.weibo.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }

    sourceSets {
        getByName("main") {
            // 自动生成的 UniFFI 绑定
            kotlin.srcDir(uniffiOutDir)
        }
    }

    buildFeatures {
        compose = true
    }

    signingConfigs {
        // 复用 debug 密钥签 release，方便直接安装体验
        getByName("debug")
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
        // .so 保持独立文件，运行时解压到 nativeLibraryDir，便于 JNA 按路径加载
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

kotlin {
    jvmToolchain(17)
}

if (!skipRust) {
    tasks.named("preBuild") {
        dependsOn(genUniffiBindings, buildRustAndroid)
    }
}

dependencies {
    // UniFFI 生成的绑定通过 JNA 调用 Rust cdylib（Android 需 aar 变体）
    implementation("net.java.dev.jna:jna:5.15.0@aar")

    // 本地缓存层用 Gson
    implementation("com.google.code.gson:gson:2.11.0")

    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    val composeBom = platform("androidx.compose:compose-bom:2024.09.00")
    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // 图片加载（头像 / 微博配图）
    implementation("io.coil-kt.coil3:coil-compose:3.0.4")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.0.4")
}
