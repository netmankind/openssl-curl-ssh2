#!/bin/bash
#
# 手动初始化源码子模块的兜底入口。正常情况下无需单独执行：各编译脚本 source common.sh 时
# 会自动校验并拉取缺失/不完整的子模块；仅在想提前把源码拉下来时跑本脚本。
#
# 用法：./prepare-sources.sh
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"

echo "源码子模块准备完成"
