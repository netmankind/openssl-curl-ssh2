#!/bin/bash
#
# Android armeabi-v7a 构建入口：OpenSSL 1.1.1w/3.5.9 + libssh2 1.11.1 + curl 8.23.0
#
# 用法（先后顺序：先 openssl，再 ssh2，最后 curl）：
#   ./build-android-armeabi-v7a-openssl.sh # 第1步：OpenSSL
#   ./build-android-armeabi-v7a-ssh2.sh    # 第2步：libssh2（依赖 OpenSSL 3.5.9）
#   ./build-android-armeabi-v7a-curl.sh    # 第3步：curl（依赖前两步产物）
#   ./build-android-armeabi-v7a.sh          # 一把梭：自动按 openssl -> ssh2 -> curl 顺序
# 可选：--versions 3.5.9 只编某一版 OpenSSL；MODES=static 只出静态库
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ABI="armeabi-v7a"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/lib/android.sh"
runAndroidMain "$@"
