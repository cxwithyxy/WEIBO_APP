#!/bin/bash
# 运行: ./run.sh <命令> [参数]     例: ./run.sh timeline 20
set -e
cd "$(dirname "$0")"
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}
CLI=cli/build/install/cli/bin/cli
[ -x "$CLI" ] || ./gradlew :cli:installDist -q
exec "$CLI" "$@"
