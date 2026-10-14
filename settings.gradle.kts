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

// 核心已迁移到 Rust（见 rust/），Kotlin core / cli 模块已移除。
// CLI 由 Rust 二进制提供：cd rust && cargo run --bin weibo-cli -- <命令>
include(":app")
