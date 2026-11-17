#!/bin/bash
# 只编 libssh2，对应主脚本 build-mingw-qt5.sh 的 ssh2 阶段。
# 先后顺序：先 openssl，再 ssh2，最后 curl；已装过的产物自动跳过。
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export BUILD_STAGE=ssh2
exec "$SCRIPT_DIR/build-mingw-qt5.sh" "$@"