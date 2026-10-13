#!/bin/bash
# 编译 CLI 发行版（Gradle wrapper 固定 8.12.1）
set -e
cd "$(dirname "$0")"
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}
./gradlew :cli:installDist
echo "✓ 构建完成: cli/build/install/cli/bin/cli"
