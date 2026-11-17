#!/bin/bash
#
# 公共构建设置：集中管理源码路径、产物布局、版本映射、工具探测与日志工具。
# 各平台脚本只负责编译器/目标配置，其余逻辑复用这里，便于后续替换版本复用。
#
# 依赖顺序（每个平台、每个模式都一致）：
#   OpenSSL -> libssh2 -> curl
# 说明：
#   - curl 8.23 硬要求 OpenSSL 3.0+，libssh2 也基于 3.5.9 编；1.1.1w 只出 OpenSSL 库。
#   - mode: static 只出静态库；shared 出动态库（同时带 import lib / 符号链接）。
#
# 本文件由其他脚本 source，不单独执行；这里不设 set -e，由调用者决定错误策略。
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

CHECKOUT_DIR="$REPO_ROOT/checkouts"
BUILD_ROOT="$REPO_ROOT/build"

OPENSSL_111W_DIR="$CHECKOUT_DIR/openssl-1.1.1w"
OPENSSL_350_DIR="$CHECKOUT_DIR/openssl-3.5.9"
CURL_DIR="$CHECKOUT_DIR/curl-8.23.0"
LIBSSH2_DIR="$CHECKOUT_DIR/libssh2-1.11.1"

# 默认参与编译的 OpenSSL 版本：1.1.1w 给 Qt5 老工程，3.5.9 LTS 给 Qt6.8 及 ssh2/curl
OPENSSL_VERSIONS_DEFAULT="1.1.1w 3.5.9"
CURL_VERSION="8.23.0"
LIBSSH2_VERSION="1.11.1"

# 老版本 OpenSSL：不编 libssh2 / curl（curl 8.23 要求 OpenSSL 3.0+）
isLegacyOpenssl() {
    [[ "$1" == 1.1.1* ]]
}

# 并行编译任务数；MinGW 等宿主可在平台脚本里覆盖上限
getCores() {
    if [[ -n "${JOBS:-}" ]]; then
        echo "$JOBS"
    elif command -v nproc >/dev/null 2>&1; then
        echo $(( $(nproc) + 1 ))
    else
        echo 4
    fi
}

# 版本号 -> 源码目录
getOpensslSourceDir() {
    local version="$1"
    case "$version" in
        1.1.1w) echo "$OPENSSL_111W_DIR" ;;
        3.5.9)  echo "$OPENSSL_350_DIR" ;;
        *) echo "不支持的 OpenSSL 版本: $version" >&2; return 1 ;;
    esac
}

# 产物布局：build/<平台>/openssl-<版本>-<模式>
getOpensslPrefix() {
    local platform="$1" version="$2" mode="$3"
    echo "$BUILD_ROOT/$platform/openssl-$version-$mode"
}

# build/<平台>/ssh2-<ssh2版本>-openssl-<版本>-<模式>
getSsh2Prefix() {
    local platform="$1" opensslVersion="$2" mode="$3"
    echo "$BUILD_ROOT/$platform/ssh2-$LIBSSH2_VERSION-openssl-$opensslVersion-$mode"
}

# build/<平台>/curl-<curl版本>-openssl-<版本>-<模式>
getCurlPrefix() {
    local platform="$1" opensslVersion="$2" mode="$3"
    echo "$BUILD_ROOT/$platform/curl-$CURL_VERSION-openssl-$opensslVersion-$mode"
}

# out-of-tree 中间目录（源码目录保持干净，同一份源码可编多个平台/模式）
getOpensslBuildDir() {
    local platform="$1" version="$2" mode="$3"
    echo "$BUILD_ROOT/$platform/.build/openssl-$version-$mode"
}

getSsh2BuildDir() {
    local platform="$1" opensslVersion="$2" mode="$3"
    echo "$BUILD_ROOT/$platform/.build/ssh2-$LIBSSH2_VERSION-openssl-$opensslVersion-$mode"
}

getCurlBuildDir() {
    local platform="$1" opensslVersion="$2" mode="$3"
    echo "$BUILD_ROOT/$platform/.build/curl-$CURL_VERSION-openssl-$opensslVersion-$mode"
}

# 安装完成标记：include + lib 都在则视为已安装，跳过重复全量编译
isInstalled() {
    local prefix="$1"
    [[ -d "$prefix/include" && -d "$prefix/lib" ]]
}

# 写入安装时间戳标记；与 isInstalled 配合，重复运行时跳过已装好的产物。
markInstalled() {
    local prefix="$1"
    mkdir -p "$prefix"
    date '+%Y-%m-%d %H:%M:%S' > "$prefix/.install-stamp"
}

# 按模式在 lib 目录里挑出库文件实际路径（后缀由 Configure/CMake 产物决定，脚本不写死）。
# 静态优先 <staticBase>.a/.lib；动态依次匹配 <base>.so.* / .so / .dll.a / .lib。找不到返回空。
# base：动态库名（libcrypto / libssh2）；staticBase：静态库名（libssh2 静态产物带 _static 后缀）。
pickLibFile() {
    local libDir="$1" base="$2" mode="$3"
    local staticBase="${4:-$base}"
    local candidate
    if [[ "$mode" == "static" ]]; then
        # 部分平台静态库带 _static 后缀（Windows），部分平台就是 <base>.a，两种都找
        candidate=$(ls "$libDir/$staticBase.a" "$libDir/$staticBase.lib" \
            "$libDir/$base.a" "$libDir/$base.lib" 2>/dev/null | head -1)
    else
        candidate=$(ls "$libDir/$base.so."* "$libDir/$base.so" \
            "$libDir/$base.dll.a" "$libDir/$base.lib" 2>/dev/null | head -1)
    fi
    echo "$candidate"
}

# 1.1.1 走 install_sw 会连带编 apps/fuzz/test（交叉编译下常缺头文件/链接失败），
# 这里手工装下游真正需要的头文件 + 库文件，跳过程序构建。
installOpensslManual() {
    local srcDir="$1" buildDir="$2" prefix="$3"
    mkdir -p "$prefix/include/openssl" "$prefix/lib"
    cp -r "$srcDir/include/openssl/." "$prefix/include/openssl/"
    cp "$buildDir/include/openssl/opensslconf.h" "$prefix/include/openssl/" 2>/dev/null || true
    cp "$buildDir"/libcrypto.a "$prefix/lib/" 2>/dev/null || true
    cp "$buildDir"/libssl.a "$prefix/lib/" 2>/dev/null || true
    cp "$buildDir"/libcrypto.so* "$prefix/lib/" 2>/dev/null || true
    cp "$buildDir"/libssl.so* "$prefix/lib/" 2>/dev/null || true
    cp "$buildDir"/libcrypto.dll.a "$prefix/lib/" 2>/dev/null || true
    cp "$buildDir"/libssl.dll.a "$prefix/lib/" 2>/dev/null || true
    cp "$buildDir"/libcrypto-*.dll "$prefix/lib/" 2>/dev/null || true
    cp "$buildDir"/libssl-*.dll "$prefix/lib/" 2>/dev/null || true
}

# POSIX 路径转本机格式：Git Bash 下 /e/xxx 传给 Windows 原生工具会被误解析
toNativePath() {
    local path="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$path"
    else
        echo "$path"
    fi
}

# 本机混合写法（E:/xxx）：给需要能 open 又保留正斜杠的 msys/cygwin 版 perl 用
toNativeMixedPath() {
    local path="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$path"
    else
        echo "$path"
    fi
}

# 判断当前是否运行在 Windows 宿主的 MSYS/Cygwin 环境（影响路径格式与工具链选择）。
isWindowsHost() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *)                    return 1 ;;
    esac
}

# Configure 给 perl 用的路径：MSYS2/cygwin perl 用混合路径（E:/...），其余按本机格式
configurePerlPath() {
    local path="$1"
    if isWindowsHost && [[ "${PERL_IS_MSYS:-0}" == "1" ]]; then
        toNativeMixedPath "$path"
    elif isWindowsHost; then
        toNativePath "$path"
    else
        echo "$path"
    fi
}

# 模式 -> CMake 开关：shared 出动态库，static 出静态库
modeCmakeFlags() {
    local mode="$1"
    local -n sharedRef="$2" staticRef="$3"
    if [[ "$mode" == "shared" ]]; then
        sharedRef="ON"; staticRef="OFF"
    else
        sharedRef="OFF"; staticRef="ON"
    fi
}

# 阶段标题日志（>>> 前缀）
logStep() {
    echo ""
    echo ">>> $*"
}

# 缩进信息日志
logInfo() {
    echo "    $*"
}

# 打印错误并以非零码退出（终止整个构建）
die() {
    echo "错误: $*" >&2
    exit 1
}

# 断言文件存在，否则带提示终止
requireFile() {
    local path="$1" tips="$2"
    [[ -e "$path" ]] || die "找不到 $path（$tips）"
}

# 断言命令在 PATH 中可用，否则终止
requireTool() {
    local tool="$1"
    command -v "$tool" >/dev/null 2>&1 || die "缺少工具 $tool，请先安装"
}

# 定位 cmake：先查 PATH，再回退常见安装路径。
# 新开的 Windows 会话 PATH 可能未包含 CMake（perl/make 另有平台兜底），这里集中兜底避免重复。
resolveCMake() {
    local c
    for c in "$(command -v cmake || true)" \
             "/d/Program Files/CMake/bin/cmake.exe" \
             "/c/Program Files/CMake/bin/cmake.exe" \
             "/e/Qt/Tools/CMake_64/bin/cmake.exe"; do
        [[ -n "$c" && -x "$c" ]] && { echo "$c"; return; }
    done
}
