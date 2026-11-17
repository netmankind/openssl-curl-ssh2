#!/bin/bash
#
# MinGW 构建公共逻辑：由 build-mingw-qt5.sh / build-mingw-qt6.sh source。
# 调用前必须设置 PLATFORM 与 MINGW_BIN。依赖顺序：OpenSSL -> libssh2 -> curl。
#
set -euo pipefail

# 版本/模式/阶段开关均可被同名环境变量覆盖。
OPENSSL_VERSIONS="${OPENSSL_VERSIONS:-$OPENSSL_VERSIONS_DEFAULT}"
MODES="${MODES:-static shared}"
BUILD_STAGE="${BUILD_STAGE:-all}"

# MinGW gcc 并行过高会同时拉起多个 cc1 顶满提交内存（cc1 out of memory）；
# 默认 2，可用 JOBS 环境变量覆盖。
CORES="${JOBS:-2}"

# 老版本 MinGW-w64（gcc 8.1）头文件默认 _WIN32_WINNT=0x502（Server 2003），
# 而 curl 8.23 要求 Vista(0x0600)+；显式抬到 Win7(0x0601)，ssh2/curl 的 CMake 编译都带上。
MINGW_C_FLAGS="-D_WIN32_WINNT=0x0601"

# 把 MinGW bin 目录前置到 PATH，并导出裸名工具链（gcc/g++/ar/...）；
# 每次进入某一阶段前调用，确保命令解析到对应 Qt 套件的 MinGW。
setupMingwEnv() {
    requireFile "$MINGW_BIN/gcc.exe" "MinGW 编译器缺失: $MINGW_BIN"
    export PATH="$MINGW_BIN:$PATH"
    export CC="gcc" CXX="g++" AR="ar" RANLIB="ranlib" STRIP="strip"
    logInfo "编译器  : $("$MINGW_BIN/gcc.exe" --version | head -1)"
}

# ---- OpenSSL ----

# 编译并安装某一版本/模式的 OpenSSL（mingw64 目标）。
# 参数：$1=版本(1.1.1w/3.5.9)，$2=模式(static/shared)；已安装则跳过。
buildOpenssl() {
    local version="$1" mode="$2"
    local srcDir prefix buildDir sharedFlag
    srcDir=$(getOpensslSourceDir "$version")
    prefix=$(getOpensslPrefix "$PLATFORM" "$version" "$mode")
    buildDir=$(getOpensslBuildDir "$PLATFORM" "$version" "$mode")

    if isInstalled "$prefix"; then
        logStep "跳过 OpenSSL $version / $mode：已安装"; return
    fi

    logStep "编译 OpenSSL $version / $mode ($PLATFORM)"
    setupMingwEnv
    requireFile "$srcDir/Configure" "源码缺失，请先执行 prepare-sources.sh"

    sharedFlag="no-shared"; [[ "$mode" == "shared" ]] && sharedFlag="shared"
    mkdir -p "$buildDir"; cd "$buildDir"

    local perlNative prefixNative
    perlNative=$(toNativePath "$PERL_CMD" | tr '\\' '/')
    # 传给 Configure 的安装路径必须用正斜杠混合路径：反斜杠会进入 C 字符串宏
    # OPENSSLDIR/CTLOG_FILE，被 gcc 当成 \o/\m 等非法转义。
    prefixNative=$(toNativeMixedPath "$prefix")
    "$PERL_CMD" "$(toNativeMixedPath "$srcDir")/Configure" mingw64 \
        "$sharedFlag" \
        --prefix="$prefixNative" \
        --libdir=lib \
        --openssldir="$prefixNative/ssl" \
        PERL="$perlNative"

    if [[ "$version" == 1.1.1* ]]; then
        # 1.1.1 的 Makefile 规则并行不安全：dll 链接后向 apps/test/fuzz 复制的 recipe 会被
        # .dll/.dll.a 两个目标重复触发，-j>1 时 cp 竞争 File exists。旧版本固定串行。
        "$MAKE_CMD" -j1 build_generated
        local sharedLibs shlibExt
        sharedLibs=$(sed -n 's/^SHLIBS=//p' "$buildDir/Makefile")
        shlibExt=$(sed -n 's/^SHLIB_EXT=//p' "$buildDir/Makefile")
        # 命令行目标名不会展开 Makefile 内的 $(SHLIB_EXT)，先替换成实际后缀（.dll/.so）
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

    logStep "编译 libssh2 $LIBSSH2_VERSION / $mode (OpenSSL $opensslVersion)"
    setupMingwEnv
    rm -rf "$buildDir"; mkdir -p "$buildDir"

    local shared static sslCrypto sslSsl
    modeCmakeFlags "$mode" shared static
    sslCrypto=$(pickLibFile "$sslPrefix/lib" libcrypto "$mode")
    sslSsl=$(pickLibFile "$sslPrefix/lib" libssl "$mode")

    "$CMAKE_CMD" -S "$(toNativePath "$LIBSSH2_DIR")" -B "$(toNativePath "$buildDir")" \
        -G "MinGW Makefiles" \
        -DCMAKE_MAKE_PROGRAM="$(toNativePath "$MAKE_CMD")" \
        -DCMAKE_C_COMPILER="$(toNativeMixedPath "$MINGW_BIN")/gcc.exe" \
        -DCMAKE_RC_COMPILER="$(toNativeMixedPath "$MINGW_BIN")/windres.exe" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$(toNativePath "$prefix")" \
        -DCMAKE_C_FLAGS="$MINGW_C_FLAGS" \
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

    logStep "编译 curl $CURL_VERSION / $mode (OpenSSL $opensslVersion + libssh2)"
    setupMingwEnv
    rm -rf "$buildDir"; mkdir -p "$buildDir"

    local shared static sslCrypto sslSsl ssh2Lib
    modeCmakeFlags "$mode" shared static
    sslCrypto=$(pickLibFile "$sslPrefix/lib" libcrypto "$mode")
    sslSsl=$(pickLibFile "$sslPrefix/lib" libssl "$mode")
    ssh2Lib=$(pickLibFile "$ssh2Prefix/lib" libssh2 "$mode" libssh2_static)

    # 显式关闭可选压缩后端（brotli/zstd/zlib），各平台产物口径一致，不携带额外系统依赖。
    "$CMAKE_CMD" -S "$(toNativePath "$CURL_DIR")" -B "$(toNativePath "$buildDir")" \
        -G "MinGW Makefiles" \
        -DCMAKE_MAKE_PROGRAM="$(toNativePath "$MAKE_CMD")" \
        -DCMAKE_C_COMPILER="$(toNativeMixedPath "$MINGW_BIN")/gcc.exe" \
        -DCMAKE_RC_COMPILER="$(toNativeMixedPath "$MINGW_BIN")/windres.exe" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$(toNativePath "$prefix")" \
        -DCMAKE_C_FLAGS="$MINGW_C_FLAGS" \
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

# 入口主流程：解析参数 -> 探测 perl/make/cmake -> 按 版本×模式 依次跑
# openssl -> ssh2 -> curl；BUILD_STAGE 控制只跑某一阶段（分步包装脚本用）。
runMingwMain() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --versions) OPENSSL_VERSIONS="$2"; shift 2 ;;
            -h|--help)  sed -n '2,11p' "$0";    exit 0 ;;
            *)          die "未知参数: $1" ;;
        esac
    done

    PERL_CMD="${PERL_CMD:-}"
    PERL_IS_MSYS=0
    if [[ -z "$PERL_CMD" ]]; then
        for p in "/d/msys64/usr/bin/perl.exe" "/c/msys64/usr/bin/perl.exe"; do
            [[ -x "$p" ]] && PERL_CMD="$p" && break
        done
    fi
    [[ -n "$PERL_CMD" ]] || PERL_CMD=$(command -v perl || true)
    case "$PERL_CMD" in *msys64*|*cygwin*) PERL_IS_MSYS=1 ;; esac

    MAKE_CMD="${MAKE_CMD:-}"
    if [[ -z "$MAKE_CMD" && -x "$MINGW_BIN/mingw32-make.exe" ]]; then
        MAKE_CMD="$MINGW_BIN/mingw32-make.exe"
    fi
    [[ -n "$MAKE_CMD" ]] || MAKE_CMD=$(command -v make || true)
    CMAKE_CMD="${CMAKE_CMD:-$(resolveCMake)}"
    [[ -n "$PERL_CMD" && -n "$MAKE_CMD" && -n "$CMAKE_CMD" ]] || die "缺少 perl / make / cmake"

    logInfo "平台    : $PLATFORM"
    logInfo "工具链  : $MINGW_BIN"
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
