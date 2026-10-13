#!/bin/bash
# 编译 weibo-client（依赖手工搭的 ~/kotlinc）
set -e
cd "$(dirname "$0")"
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}
KOTLINC=${KOTLINC:-$HOME/kotlinc/kotlinc}
"$KOTLINC" -cp libs/gson-2.11.0.jar src/main/kotlin -include-runtime -d out/weibo-client.jar
echo "✓ 构建完成: out/weibo-client.jar"
