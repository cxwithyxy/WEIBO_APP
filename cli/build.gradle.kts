plugins {
    kotlin("jvm")
    application
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(project(":core"))
    implementation("com.google.code.gson:gson:2.11.0")
}

application {
    mainClass.set("com.cx.weibo.cli.MainKt")
    applicationName = "cli"
}
