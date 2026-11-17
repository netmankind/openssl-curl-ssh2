#!/bin/bash
#
# Ubuntu 22.04 构建入口：OpenSSL 1.1.1w/3.5.9 + libssh2 1.11.1 + curl 8.23.0（系统 gcc）
# 依赖顺序：OpenSSL -> libssh2 -> curl；默认 static + shared 两套都出。
#
# 用法：
#   bash scripts/prepare-sources.sh          # 首次拉源码
#   bash scripts/build-ubuntu.sh              # 全部版本、静态+动态
#   bash scripts/build-ubuntu.sh --versions 3.5.9
#   MODES=static bash scripts/build-ubuntu.sh  # 只出静态库
#
# 依赖：sudo apt install -y build-essential perl cmake
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"

PLATFORM="ubuntu22.04-x64"
OPENSSL_VERSIONS="${OPENSSL_VERSIONS:-$OPENSSL_VERSIONS_DEFAULT}"
MODES="${MODES:-static shared}"
BUILD_STAGE="${BUILD_STAGE:-all}"

# 解析命令行参数（--versions 覆盖 OpenSSL 版本列表；-h 打印用法）。
parseArgs() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --versions) OPENSSL_VERSIONS="$2"; shift 2 ;;
            -h|--help)  sed -n '2,13p' "$0";   exit 0 ;;
            *)          die "未知参数: $1" ;;
        esac
    done
}

# ---- OpenSSL ----

# 编译并安装某一版本/模式的 OpenSSL（系统 gcc）。
# 参数：$1=版本(1.1.1w/3.5.9)，$2=模式(static/shared)；已安装则跳过。
buildOpenssl() {
    local version="$1" mode="$2"
    local srcDir prefix buildDir sharedOpt opensslTarget shlibVer
    srcDir=$(getOpensslSourceDir "$version")
    prefix=$(getOpensslPrefix "$PLATFORM" "$version" "$mode")
    buildDir=$(getOpensslBuildDir "$PLATFORM" "$version" "$mode")

    if isInstalled "$prefix"; then
        logStep "跳过 OpenSSL $version / $mode：已安装"; return
    fi

    logStep "编译 OpenSSL $version / $mode (Ubuntu 22.04)"
    requireFile "$srcDir/Configure" "源码缺失，请先执行 prepare-sources.sh"

    sharedOpt="no-shared"; [[ "$mode" == "shared" ]] && sharedOpt="shared"
    # OpenSSL 目标按本机架构；1.1.1 必须显式给出平台（否则列出全部平台后退出），
    # 3.x 不传也能自动探测，这里统一传上以保持一致。
    case "$(uname -m)" in
        x86_64)  opensslTarget="linux-x86_64" ;;
        aarch64) opensslTarget="linux-aarch64" ;;
        *)       die "不支持的架构: $(uname -m)" ;;
    esac
    mkdir -p "$buildDir"; cd "$buildDir"

    "$PERL_CMD" "$srcDir/Configure" \
        --prefix="$prefix" --openssldir="$prefix/ssl" --libdir="lib" \
        "$opensslTarget" "$sharedOpt" -fPIC

    if [[ "$version" == 1.1.1* ]]; then
        # 1.1.1 没有 build_sw 目标；install_sw 会连带编 apps/tests，改为只出库文件
        "$MAKE_CMD" -j"$CORES" build_generated
        if [[ "$mode" == "shared" ]]; then
            # make 命令行目标不展开 Makefile 变量，先读 SHLIB_VERSION_NUMBER 拼出真实 .so 文件名。
            shlibVer=$(sed -n 's/^SHLIB_VERSION_NUMBER=//p' "$buildDir/Makefile")
            "$MAKE_CMD" -j"$CORES" libcrypto.a libssl.a \
                "libcrypto.so.$shlibVer" "libssl.so.$shlibVer"
        else
            "$MAKE_CMD" -j"$CORES" libcrypto.a libssl.a
        fi
        installOpensslManual "$srcDir" "$buildDir" "$prefix"
    else
        "$MAKE_CMD" -j"$CORES" build_sw
        "$MAKE_CMD" install_sw
    fi
    markInstalled "$prefix"
    cd "$REPO_ROOT"
}

# ---- libssh2 ----

# 基于指定 OpenSSL 版本/模式编译 libssh2；1.1.1 老版本跳过。
# 参数：$1=OpenSSL 版本，$2=模式(static/shared)。
buildSsh2() {
    local opensslVersion="$1" mode="$2"
    if isLegacyOpenssl "$opensslVersion"; then
        logStep "跳过 libssh2（OpenSSL $opensslVersion）：libssh2/curl 基于 3.5.9"; return
    fi

    local sslPrefix prefix buildDir
    sslPrefix=$(getOpensslPrefix "$PLATFORM" "$opensslVersion" "$mode")
    prefix=$(getSsh2Prefix "$PLATFORM" "$opensslVersion" "$mode")
    buildDir=$(getSsh2BuildDir "$PLATFORM" "$opensslVersion" "$mode")

    if isInstalled "$prefix"; then
        logStep "跳过 libssh2 $LIBSSH2_VERSION / $mode (OpenSSL $opensslVersion)：已安装"; return
    fi

    logStep "编译 libssh2 $LIBSSH2_VERSION / $mode (OpenSSL $opensslVersion)"
    rm -rf "$buildDir"; mkdir -p "$buildDir"

    local shared static sslCrypto sslSsl
    modeCmakeFlags "$mode" shared static
    sslCrypto=$(pickLibFile "$sslPrefix/lib" libcrypto "$mode")
    sslSsl=$(pickLibFile "$sslPrefix/lib" libssl "$mode")

    "$CMAKE_CMD" -S "$LIBSSH2_DIR" -B "$buildDir" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DBUILD_SHARED_LIBS="$shared" -DBUILD_STATIC_LIBS="$static" \
        -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
        -DCRYPTO_BACKEND=OpenSSL \
        -DOPENSSL_ROOT_DIR="$sslPrefix" \
        -DOPENSSL_INCLUDE_DIR="$sslPrefix/include" \
        -DOPENSSL_CRYPTO_LIBRARY="$sslCrypto" \
        -DOPENSSL_SSL_LIBRARY="$sslSsl"

    "$CMAKE_CMD" --build "$buildDir" --parallel "$CORES"
    "$CMAKE_CMD" --install "$buildDir"
    markInstalled "$prefix"
}

# ---- curl ----

# 基于指定 OpenSSL + libssh2 编译 curl；1.1.1 老版本跳过（curl 8.23 要求 OpenSSL 3.0+）。
# 参数：$1=OpenSSL 版本，$2=模式(static/shared)。
buildCurl() {
    local opensslVersion="$1" mode="$2"
    if isLegacyOpenssl "$opensslVersion"; then
        logStep "跳过 curl（OpenSSL $opensslVersion）：curl 8.23 要求 OpenSSL 3.0+"; return
    fi

    local sslPrefix ssh2Prefix prefix buildDir
    sslPrefix=$(getOpensslPrefix "$PLATFORM" "$opensslVersion" "$mode")
    ssh2Prefix=$(getSsh2Prefix "$PLATFORM" "$opensslVersion" "$mode")
    prefix=$(getCurlPrefix "$PLATFORM" "$opensslVersion" "$mode")
    buildDir=$(getCurlBuildDir "$PLATFORM" "$opensslVersion" "$mode")

    if isInstalled "$prefix"; then
        logStep "跳过 curl $CURL_VERSION / $mode (OpenSSL $opensslVersion)：已安装"; return
    fi

    logStep "编译 curl $CURL_VERSION / $mode (OpenSSL $opensslVersion + libssh2)"
    rm -rf "$buildDir"; mkdir -p "$buildDir"

    local shared static sslCrypto sslSsl ssh2Lib
    modeCmakeFlags "$mode" shared static
    sslCrypto=$(pickLibFile "$sslPrefix/lib" libcrypto "$mode")
    sslSsl=$(pickLibFile "$sslPrefix/lib" libssl "$mode")
    ssh2Lib=$(pickLibFile "$ssh2Prefix/lib" libssh2 "$mode" libssh2_static)

    # Linux 常预装 brotli/zstd 开发包，AUTO 会自动启用并让静态产物额外依赖这些系统库；
    # 显式关闭，使 Ubuntu 产物与 Android/MinGW/MSVC 口径一致，不携带可选压缩后端。
    "$CMAKE_CMD" -S "$CURL_DIR" -B "$buildDir" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DBUILD_SHARED_LIBS="$shared" -DBUILD_STATIC_LIBS="$static" \
        -DBUILD_CURL_EXE=OFF -DCURL_ENABLE_SSL=ON -DCURL_USE_OPENSSL=ON \
        -DOPENSSL_ROOT_DIR="$sslPrefix" \
        -DOPENSSL_INCLUDE_DIR="$sslPrefix/include" \
        -DOPENSSL_CRYPTO_LIBRARY="$sslCrypto" \
        -DOPENSSL_SSL_LIBRARY="$sslSsl" \
        -DCURL_USE_LIBSSH2=ON \
        -DLIBSSH2_INCLUDE_DIR="$ssh2Prefix/include" \
        -DLIBSSH2_LIBRARY="$ssh2Lib" \
        -DCURL_USE_LIBSSH=OFF -DCURL_USE_LIBPSL=OFF -DCURL_ZLIB=OFF \
        -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DCURL_DISABLE_LDAP=ON

    "$CMAKE_CMD" --build "$buildDir" --parallel "$CORES"
    "$CMAKE_CMD" --install "$buildDir"
    markInstalled "$prefix"
}

parseArgs "$@"

# 探测本机工具链：Ubuntu 直接用 PATH 里的 perl/make/cmake。
CORES=$(getCores)
PERL_CMD=$(command -v perl || true)
MAKE_CMD=$(command -v make || true)
CMAKE_CMD=$(command -v cmake || true)
[[ -n "$PERL_CMD" && -n "$MAKE_CMD" && -n "$CMAKE_CMD" ]] || die "缺少 perl / make / cmake"

logInfo "系统    : $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
logInfo "编译器  : $(gcc --version | head -1)"
logInfo "版本    : $OPENSSL_VERSIONS"
logInfo "模式    : $MODES"
logInfo "并行    : $CORES"

# 按 版本×模式 编排三阶段；BUILD_STAGE=all 全跑，=openssl/ssh2/curl 只跑单阶段（分步包装用）。
version="" mode=""
for version in $OPENSSL_VERSIONS; do
    for mode in $MODES; do
        [[ "$BUILD_STAGE" != "ssh2" && "$BUILD_STAGE" != "curl" ]] && buildOpenssl "$version" "$mode"
        [[ "$BUILD_STAGE" != "openssl" && "$BUILD_STAGE" != "curl" ]] && buildSsh2 "$version" "$mode"
        [[ "$BUILD_STAGE" != "openssl" && "$BUILD_STAGE" != "ssh2" ]] && buildCurl "$version" "$mode"
    done
done

logStep "Ubuntu ($BUILD_STAGE) 构建完成，产物位于 $BUILD_ROOT/$PLATFORM"
