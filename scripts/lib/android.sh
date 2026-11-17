#!/bin/bash
#
# Android 构建公共逻辑：由 build-android-arm64-v8a.sh / build-android-armeabi-v7a.sh source。
# 调用前必须设置 ABI。依赖顺序：OpenSSL -> libssh2 -> curl。
#
# 官方资料：
#   OpenSSL: Configure <target> [shared|no-shared]，make，make install_sw
#   libssh2 / curl: CMake，CRYPTO_BACKEND=OpenSSL，显式指定 OpenSSL/libssh2 路径
#
set -euo pipefail

# 平台名与可被环境变量覆盖的版本/模式/阶段开关（入口或分步脚本先 source 本文件）。
PLATFORM="android-$ABI"
API_LEVEL="${API_LEVEL:-23}"
OPENSSL_VERSIONS="${OPENSSL_VERSIONS:-$OPENSSL_VERSIONS_DEFAULT}"
MODES="${MODES:-static shared}"
BUILD_STAGE="${BUILD_STAGE:-all}"

# ---- NDK 定位与工具链 ----

# 定位 NDK 根目录：优先用环境变量 NDK，否则在常见安装位置中查找。
resolveNdk() {
    if [[ -n "${NDK:-}" ]]; then
        echo "$NDK"; return
    fi
    local dir
    for dir in "/e/AndroidDevelop/SDK/ndk/22.1.7171670" \
               "/d/AndroidDevelop/SDK/ndk/22.1.7171670" \
               "$HOME/Android/Sdk/ndk/22.1.7171670"; do
        [[ -d "$dir/toolchains/llvm/prebuilt" ]] && { echo "$dir"; return; }
    done
    die "未找到 NDK，请用 NDK=<NDK 根目录> 指定"
}

# 按当前主机系统返回 NDK 工具链目录名（prebuilt/<hostTag>）。
getHostTag() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) echo "windows-x86_64" ;;
        Linux)                echo "linux-x86_64"   ;;
        Darwin)               echo "darwin-x86_64"  ;;
        *) die "不支持的主机平台: $(uname -s)" ;;
    esac
}

# 返回交叉编译 triple（去掉 API 级别，API 级别在 setupToolchain 里拼到 --target）。
getTriple() {
    case "$ABI" in
        arm64-v8a)   echo "aarch64-linux-android" ;;
        armeabi-v7a) echo "armv7a-linux-androideabi" ;;
        *) die "不支持的 ABI: $ABI" ;;
    esac
}

# Windows 宿主：15-android.conf 靠 which("clang") 匹配 NDK 路径会失败，
# 改用指令集等价的 linux 目标 + NDK clang；Linux/macOS 用官方 android 目标。
getOpensslTarget() {
    if isWindowsHost; then
        case "$ABI" in
            arm64-v8a)   echo "linux-aarch64" ;;
            armeabi-v7a) echo "linux-armv4"   ;;
        esac
    else
        case "$ABI" in
            arm64-v8a)   echo "android-arm64" ;;
            armeabi-v7a) echo "android-arm"   ;;
        esac
    fi
}

# 导出 NDK 交叉编译环境。不使用无扩展名的 clang 包装脚本（并行下 dirname 偶发解析为空），
# 直接调 clang.exe 并显式 --target/--sysroot。
setupToolchain() {
    local ndkRoot="$1" hostTag triple sysroot toolchain
    hostTag=$(getHostTag)
    triple=$(getTriple)
    toolchain="$ndkRoot/toolchains/llvm/prebuilt/$hostTag"
    sysroot="$toolchain/sysroot"
    if isWindowsHost; then
        toolchain=$(toNativeMixedPath "$toolchain")
        sysroot="$toolchain/sysroot"
    fi

    export PATH="$ndkRoot/toolchains/llvm/prebuilt/$hostTag/bin:$PATH"
    export PERL="$PERL_CMD"
    export CC="$toolchain/bin/clang.exe --target=${triple}${API_LEVEL} --sysroot=$sysroot"
    export CXX="$toolchain/bin/clang++.exe --target=${triple}${API_LEVEL} --sysroot=$sysroot"
    export AS="$CC"
    export AR="$toolchain/bin/llvm-ar"
    export RANLIB="$toolchain/bin/llvm-ranlib"
    export STRIP="$toolchain/bin/llvm-strip"
    # armv7 需显式指定 ARMv7-A / Thumb / softfp；arm64 由 triple 自带，无需追加
    if [[ "$ABI" == "armeabi-v7a" ]]; then
        export CFLAGS="-march=armv7-a -mthumb -mfloat-abi=softfp"
        export CXXFLAGS="$CFLAGS"
    fi
    export ANDROID_NDK_ROOT="$ndkRoot"
    export ANDROID_NDK_HOME="$ndkRoot"
}

# ---- OpenSSL ----

# 编译并安装某一版本/模式的 OpenSSL。
# 参数：$1=版本(1.1.1w/3.5.9)，$2=模式(static/shared)；已安装则跳过。
# 1.1.1 走 build_generated + 手工出库文件；3.x 走 build_sw + install_sw。
buildOpenssl() {
    local version="$1" mode="$2"
    local srcDir prefix buildDir sharedFlag
    srcDir=$(getOpensslSourceDir "$version")
    prefix=$(getOpensslPrefix "$PLATFORM" "$version" "$mode")
    buildDir=$(getOpensslBuildDir "$PLATFORM" "$version" "$mode")

    if isInstalled "$prefix"; then
        logStep "跳过 OpenSSL $version / $mode ($ABI)：已安装"; return
    fi

    logStep "编译 OpenSSL $version / $ABI / $mode (API $API_LEVEL)"
    setupToolchain "$NDK_ROOT"
    requireFile "$srcDir/Configure" "源码缺失，请先执行 prepare-sources.sh"

    sharedFlag="no-shared"; [[ "$mode" == "shared" ]] && sharedFlag="shared"
    mkdir -p "$buildDir"; cd "$buildDir"

    local perlPath archFlags
    perlPath=$(configurePerlPath "$PERL_CMD")
    # linux-armv4 目标默认不带 -march（NDK 退到 armv5te）；armv7 需在 Configure
    # 命令行显式传入架构/浮点 flags（环境 CFLAGS 不被 OpenSSL 采纳）。
    archFlags=""
    [[ "$ABI" == "armeabi-v7a" ]] && archFlags="-march=armv7-a -mthumb -mfloat-abi=softfp"
    "$PERL_CMD" "$(configurePerlPath "$srcDir")/Configure" "$(getOpensslTarget)" \
        "$sharedFlag" $archFlags \
        --prefix="$(configurePerlPath "$prefix")" \
        --openssldir="$(configurePerlPath "$prefix")/ssl" \
        PERL="$perlPath" CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" \
        -D__ANDROID_API__="$API_LEVEL"

    if [[ "$version" == 1.1.1* ]]; then
        # 1.1.1 无 build_sw；共享库目标由 Makefile 的 SHLIBS 决定，不写死后缀。
        # 1.1.1 Makefile 规则并行不安全（dll 复制 recipe 会被重复触发竞争 File exists），固定串行。
        "$MAKE_CMD" -j1 build_generated
        local sharedLibs shlibExt
        sharedLibs=$(sed -n 's/^SHLIBS=//p' "$buildDir/Makefile")
        shlibExt=$(sed -n 's/^SHLIB_EXT=//p' "$buildDir/Makefile")
        # 命令行目标名不会展开 Makefile 内的 $(SHLIB_EXT)，先替换成实际后缀
        sharedLibs=${sharedLibs//\$\(SHLIB_EXT\)/$shlibExt}
        "$MAKE_CMD" -j1 libcrypto.a libssl.a $sharedLibs
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

    logStep "编译 libssh2 $LIBSSH2_VERSION / $ABI / $mode (OpenSSL $opensslVersion)"
    setupToolchain "$NDK_ROOT"
    rm -rf "$buildDir"; mkdir -p "$buildDir"

    local shared static sslCrypto sslSsl
    modeCmakeFlags "$mode" shared static
    sslCrypto=$(pickLibFile "$sslPrefix/lib" libcrypto "$mode")
    sslSsl=$(pickLibFile "$sslPrefix/lib" libssl "$mode")

    "$CMAKE_CMD" -S "$(toNativePath "$LIBSSH2_DIR")" -B "$(toNativePath "$buildDir")" \
        -G "Unix Makefiles" \
        -DCMAKE_MAKE_PROGRAM="$(toNativePath "$MAKE_CMD")" \
        -DCMAKE_TOOLCHAIN_FILE="$(toNativePath "$NDK_ROOT")/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API_LEVEL" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$(toNativePath "$prefix")" \
        -DBUILD_SHARED_LIBS="$shared" -DBUILD_STATIC_LIBS="$static" \
        -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
        -DCRYPTO_BACKEND=OpenSSL \
        -DOPENSSL_ROOT_DIR="$(toNativePath "$sslPrefix")" \
        -DOPENSSL_INCLUDE_DIR="$(toNativePath "$sslPrefix/include")" \
        -DOPENSSL_CRYPTO_LIBRARY="$(toNativePath "$sslCrypto")" \
        -DOPENSSL_SSL_LIBRARY="$(toNativePath "$sslSsl")"

    "$CMAKE_CMD" --build "$(toNativePath "$buildDir")" --parallel "$CORES"
    "$CMAKE_CMD" --install "$(toNativePath "$buildDir")"
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

    logStep "编译 curl $CURL_VERSION / $ABI / $mode (OpenSSL $opensslVersion + libssh2)"
    setupToolchain "$NDK_ROOT"
    rm -rf "$buildDir"; mkdir -p "$buildDir"

    local shared static sslCrypto sslSsl ssh2Lib
    modeCmakeFlags "$mode" shared static
    sslCrypto=$(pickLibFile "$sslPrefix/lib" libcrypto "$mode")
    sslSsl=$(pickLibFile "$sslPrefix/lib" libssl "$mode")
    ssh2Lib=$(pickLibFile "$ssh2Prefix/lib" libssh2 "$mode" libssh2_static)

    # 显式关闭可选压缩后端（brotli/zstd/zlib），各平台产物口径一致，不携带额外系统依赖。
    "$CMAKE_CMD" -S "$(toNativePath "$CURL_DIR")" -B "$(toNativePath "$buildDir")" \
        -G "Unix Makefiles" \
        -DCMAKE_MAKE_PROGRAM="$(toNativePath "$MAKE_CMD")" \
        -DCMAKE_TOOLCHAIN_FILE="$(toNativePath "$NDK_ROOT")/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API_LEVEL" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$(toNativePath "$prefix")" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS="$shared" -DBUILD_STATIC_LIBS="$static" \
        -DBUILD_CURL_EXE=OFF -DCURL_ENABLE_SSL=ON -DCURL_USE_OPENSSL=ON \
        -DOPENSSL_ROOT_DIR="$(toNativePath "$sslPrefix")" \
        -DOPENSSL_INCLUDE_DIR="$(toNativePath "$sslPrefix/include")" \
        -DOPENSSL_CRYPTO_LIBRARY="$(toNativePath "$sslCrypto")" \
        -DOPENSSL_SSL_LIBRARY="$(toNativePath "$sslSsl")" \
        -DCURL_USE_LIBSSH2=ON \
        -DLIBSSH2_INCLUDE_DIR="$(toNativePath "$ssh2Prefix/include")" \
        -DLIBSSH2_LIBRARY="$(toNativePath "$ssh2Lib")" \
        -DCURL_USE_LIBSSH=OFF -DCURL_USE_LIBPSL=OFF -DCURL_ZLIB=OFF \
        -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DCURL_DISABLE_LDAP=ON

    "$CMAKE_CMD" --build "$(toNativePath "$buildDir")" --parallel "$CORES"
    "$CMAKE_CMD" --install "$(toNativePath "$buildDir")"
    markInstalled "$prefix"
}

# ---- 主流程 ----

# 入口主流程：解析命令行参数 -> 探测 NDK/perl/make/cmake -> 按 版本×模式 依次跑
# openssl -> ssh2 -> curl；BUILD_STAGE 控制只跑某一阶段（分步包装脚本用）。
runAndroidMain() {
    local arg
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --versions) OPENSSL_VERSIONS="$2"; shift 2 ;;
            --api)      API_LEVEL="$2";         shift 2 ;;
            -h|--help)  sed -n '2,14p' "$0";    exit 0 ;;
            *)          die "未知参数: $1" ;;
        esac
    done

    CORES=$(getCores); export CORES
    # Windows 宿主下 MSYS sh 的 fork 资源有限（本机常驻内存紧张），并行 ≥2 即触发
    # "fork: Resource temporarily unavailable" 并把 clang 挤崩；未显式指定 JOBS 时默认串行。
    # 显式 JOBS 按用户给的值，不受此限；Linux/macOS 宿主不受此限制。
    if isWindowsHost && [[ -z "${JOBS:-}" && "$CORES" -gt 1 ]]; then
        CORES=1
    fi
    NDK_ROOT=$(resolveNdk)

    # Windows 上 OpenSSL 配置阶段必须用能产出 POSIX 路径的 MSYS2/cygwin perl
    PERL_CMD="${PERL_CMD:-}"
    PERL_IS_MSYS=0
    if [[ -z "$PERL_CMD" ]] && isWindowsHost; then
        for p in "/d/msys64/usr/bin/perl.exe" "/c/msys64/usr/bin/perl.exe"; do
            [[ -x "$p" ]] && PERL_CMD="$p" && break
        done
    fi
    [[ -n "$PERL_CMD" ]] || PERL_CMD=$(command -v perl || true)
    case "$PERL_CMD" in *msys64*|*cygwin*) PERL_IS_MSYS=1 ;; esac
    [[ -n "$PERL_CMD" ]] || die "缺少 perl"

    MAKE_CMD="${MAKE_CMD:-$(command -v make || true)}"
    if [[ -z "$MAKE_CMD" ]]; then
        for p in "/e/Qt/Tools/mingw1310_64/bin/mingw32-make.exe"; do
            [[ -x "$p" ]] && MAKE_CMD="$p" && break
        done
    fi
    CMAKE_CMD="${CMAKE_CMD:-$(resolveCMake)}"
    [[ -n "$MAKE_CMD" && -n "$CMAKE_CMD" ]] || die "缺少 make / cmake"

    logInfo "平台    : $PLATFORM"
    logInfo "NDK     : $NDK_ROOT"
    logInfo "API     : $API_LEVEL"
    logInfo "版本    : $OPENSSL_VERSIONS"
    logInfo "模式    : $MODES"
    logInfo "并行    : $CORES"

    local version mode
    for version in $OPENSSL_VERSIONS; do
        for mode in $MODES; do
            [[ "$BUILD_STAGE" != "ssh2" && "$BUILD_STAGE" != "curl" ]] && buildOpenssl "$version" "$mode"
            [[ "$BUILD_STAGE" != "openssl" && "$BUILD_STAGE" != "curl" ]] && buildSsh2 "$version" "$mode"
            [[ "$BUILD_STAGE" != "openssl" && "$BUILD_STAGE" != "ssh2" ]] && buildCurl "$version" "$mode"
        done
    done
    logStep "$PLATFORM ($BUILD_STAGE) 构建完成，产物位于 $BUILD_ROOT/$PLATFORM"
}
