#!/bin/bash
# 运行: ./run.sh <命令> [参数]
cd "$(dirname "$0")"
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}
exec "$JAVA_HOME/bin/java" -cp "out/weibo-client.jar:libs/gson-2.11.0.jar" \
     com.cx.weibo.cli.MainKt "$@"
