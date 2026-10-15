pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "weibo-client"

// 核心在 rust/；UI 已统一到 flutter-app/（Flutter）。
// 早先的 Kotlin core / cli 模块，以及 Jetpack Compose UI（app/）均已移除。
// 需要旧 UI 可从 git 历史取回：git checkout <删除前的提交> -- app/
//   （删除前的提交为 5ab483a）
// CLI 由 Rust 二进制提供：cd rust && cargo run --bin weibo-cli -- <命令>
//
// 本文件目前不再 include 任何子项目（保留作占位，日后要加 Gradle 模块时再用）。
