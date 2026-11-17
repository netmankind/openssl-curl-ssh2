#
# MSVC 构建脚本（Windows 桌面 x64）：OpenSSL 1.1.1w/3.5.9 + libssh2 1.11.1 + curl 8.23.0
# 依赖顺序：OpenSSL -> libssh2 -> curl；默认 static + shared 两套都出。
#
# 用法（PowerShell）：
#   .\scripts\build-msvc.ps1                          # 全部版本、静态+动态
#   .\scripts\build-msvc.ps1 -Versions 3.5.9 -Modes static
#   .\scripts\build-msvc.ps1 -VsInstall "D:\Program Files\Microsoft Visual Studio\2022\Enterprise"
#
# 说明：OpenSSL 的 nmake 构建只能在源码目录内进行，每个版本/模式复制一份独立副本
#       到 build\trees\，子模块原始源码保持干净。
#
param(
    [string[]]$Versions = @("1.1.1w", "3.5.9"),
    [string[]]$Modes = @("static", "shared"),
    # 留空则用脚本顶部 $DefaultVsInstall 指定的实例；命令行可传其他 VS 安装目录临时覆盖。
    [string]$VsInstall = "",
    [string]$PerlCmd = "D:\Strawberry\perl\bin\perl.exe",
    [string]$CurlVersion = "8.23.0",
    [string]$Ssh2Version = "1.11.1"
)

$ErrorActionPreference = "Stop"

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $script:RepoRoot "build"
$treeRoot  = Join-Path $buildRoot "trees"
$platform  = "msvc-x64"

# 默认使用的 VS 实例安装目录；要切换到其他 VS 版本/实例，只改这一处即可。
# 命令行传 -VsInstall 可临时覆盖此默认值。
$script:DefaultVsInstall = "D:\Program Files\Microsoft Visual Studio\2022\Enterprise"
if (-not $VsInstall) { $VsInstall = $script:DefaultVsInstall }

# 版本号 -> 源码目录
function Get-OpensslSourceDir([string]$version) {
    switch ($version) {
        "1.1.1w" { Join-Path $script:RepoRoot "openssl-1.1.1w" }
        "3.5.9"  { Join-Path $script:RepoRoot "openssl-3.5.9" }
        default  { throw "不支持的 OpenSSL 版本: $version" }
    }
}

# 老版本 OpenSSL 不编 libssh2 / curl（curl 8.23 要求 OpenSSL 3.0+）
function Test-LegacyOpenssl([string]$version) { $version -like "1.1.1*" }

# 产物布局：build/<平台>/openssl-<版本>-<模式>
function Get-OpensslPrefix([string]$version, [string]$mode) {
    Join-Path $buildRoot "$platform\openssl-$version-$mode"
}
# build/<平台>/ssh2-<ssh2版本>-openssl-<版本>-<模式>
function Get-Ssh2Prefix([string]$opensslVersion, [string]$mode) {
    Join-Path $buildRoot "$platform\ssh2-$Ssh2Version-openssl-$opensslVersion-$mode"
}
# build/<平台>/curl-<curl版本>-openssl-<版本>-<模式>
function Get-CurlPrefix([string]$opensslVersion, [string]$mode) {
    Join-Path $buildRoot "$platform\curl-$CurlVersion-openssl-$opensslVersion-$mode"
}

# include + lib 都在则视为已安装，重复运行时跳过
function Test-Installed([string]$prefix) {
    (Test-Path (Join-Path $prefix "include")) -and (Test-Path (Join-Path $prefix "lib"))
}

# 校验子模块目录是否完整：目录存在、非空、git HEAD 可解析（元数据有效）
function Test-SubmoduleComplete([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return $false }
    if (-not (Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1)) { return $false }
    git -C $dir rev-parse HEAD 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# 确保 .gitmodules 登记的子模块已拉取且完整；缺失/不完整的才拉取，已完整的跳过
function Ensure-Submodules {
    $gitmodules = Join-Path $script:RepoRoot ".gitmodules"
    if (-not (Test-Path -LiteralPath $gitmodules)) { return }
    $subs = git -C $script:RepoRoot config --file $gitmodules --get-regexp '^submodule\..*\.path$' |
        ForEach-Object { ($_ -split '\s+')[1] }
    if (-not $subs) { return }
    foreach ($sub in $subs) {
        $dir = Join-Path $script:RepoRoot $sub
        if (Test-SubmoduleComplete $dir) {
            Write-Host ">>> 子模块 $sub 已就绪，跳过"
            continue
        }
        Write-Host ">>> 子模块 $sub 缺失或不完整，拉取中..."
        git -C $script:RepoRoot submodule update --init --recursive -- $sub
        if (-not (Test-SubmoduleComplete $dir)) {
            throw "子模块 $sub 拉取后仍不完整，请检查网络后重试"
        }
    }
}

# MSVC 下静态/动态都用 .lib（动态为导入库），OpenSSL 按名取即可
function Get-Lib([string]$prefix, [string]$name) {
    Join-Path $prefix "lib\$name.lib"
}

# libssh2 静态库默认就是 libssh2.lib，只有同时编静态+动态时才会带 _static 后缀，
# 这里按文件是否实际存在来挑，避免写死后缀导致找不到库
function Get-Ssh2Lib([string]$prefix, [string]$mode) {
    $names = if ($mode -eq "static") { @("libssh2_static.lib", "libssh2.lib") } else { @("libssh2.lib") }
    foreach ($name in $names) {
        $path = Join-Path $prefix "lib\$name"
        if (Test-Path $path) { return $path }
    }
    return Join-Path $prefix "lib\$($names[0])"
}

# 解析 vcvars64.bat 路径：$VsInstall 已由顶部 $DefaultVsInstall 或命令行 -VsInstall 填充；
# 仅当两者都为空时回退 vswhere 找最新带 VC 工具链的实例。
function Resolve-Vcvars64 {
    if (-not $VsInstall) {
        $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        if (Test-Path $vswhere) {
            $VsInstall = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        }
    }
    $vcvars = Join-Path $VsInstall "VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path $vcvars)) { throw "找不到 vcvars64.bat，请用 -VsInstall 指定 VS 安装目录" }
    return $vcvars
}

# 按 $VsInstall 路径映射 CMake 生成器名；不同 VS 大版本对应不同生成器字符串，
# 不能写死（如 VS2026 对应 "Visual Studio 18 2026"，VS2022 对应 "Visual Studio 17 2022"）。
function Resolve-VsGenerator {
    $vsPath = $VsInstall
    if (-not $vsPath) {
        $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }
    switch -Regex ($vsPath) {
        "2019" { return "Visual Studio 16 2019" }
        "2022" { return "Visual Studio 17 2022" }
        "2026" { return "Visual Studio 18 2026" }
        default { throw "无法从 VS 路径识别版本: $vsPath，请在 Resolve-VsGenerator 补充生成器映射" }
    }
}

# 在 cmd 里先加载 VS 环境，再执行一串命令（nmake/编译必须在 vcvars 环境里跑）
function Invoke-VsCmd([string]$vcvars, [string]$commands) {
    $bat = Join-Path $env:TEMP ("openssl-build-" + [Guid]::NewGuid().ToString("N") + ".cmd")
    try {
        "@echo off`r`ncall `"$vcvars`"`r`n$commands`r`nexit /b %ERRORLEVEL%" |
            Set-Content -LiteralPath $bat -Encoding ascii
        & cmd /c $bat
        if ($LASTEXITCODE -ne 0) { throw "命令失败(exit=$LASTEXITCODE)" }
    } finally {
        Remove-Item -LiteralPath $bat -Force -ErrorAction SilentlyContinue
    }
}

# 编译并安装某一版本/模式的 OpenSSL（VC-WIN64A，nmake）。已安装则跳过。
function Build-Openssl([string]$version, [string]$mode) {
    $srcDir  = Get-OpensslSourceDir $version
    $prefix  = Get-OpensslPrefix $version $mode
    $treeDir = Join-Path $treeRoot "openssl-$version-$mode"

    if (Test-Installed $prefix) { Write-Host ">>> 跳过 OpenSSL $version / $mode：已安装"; return }
    Write-Host ">>> 编译 OpenSSL $version / $mode (MSVC x64)"
    if (-not (Test-Path (Join-Path $srcDir "Configure"))) { throw "源码缺失: $srcDir" }

    # 独立副本：nmake 构建只能在源码目录内进行
    if (Test-Path $treeDir) { Remove-Item -LiteralPath $treeDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $treeDir | Out-Null
    & robocopy $srcDir $treeDir /MIR /XD .git /NFL /NDL /NJH /NJS /NC /NS | Out-Null

    $shared = if ($mode -eq "shared") { "shared" } else { "no-shared" }
    $vcvars = Resolve-Vcvars64
    $cmds = @"
cd /d "$treeDir"
"$PerlCmd" Configure VC-WIN64A $shared no-tests --prefix="$prefix"
if errorlevel 1 exit /b 1
nmake
if errorlevel 1 exit /b 1
nmake install_sw
if errorlevel 1 exit /b 1
"@
    Invoke-VsCmd $vcvars $cmds
}

# 基于指定 OpenSSL 版本/模式编译 libssh2（VS 生成器，Release）；1.1.1 老版本跳过。
function Build-Ssh2([string]$opensslVersion, [string]$mode) {
    if (Test-LegacyOpenssl $opensslVersion) { Write-Host ">>> 跳过 libssh2（OpenSSL $opensslVersion）：基于 3.5.9"; return }

    $sslPrefix = Get-OpensslPrefix $opensslVersion $mode
    $prefix    = Get-Ssh2Prefix $opensslVersion $mode
    $buildDir  = Join-Path $buildRoot "$platform\.build\ssh2-$Ssh2Version-openssl-$opensslVersion-$mode"
    $srcDir    = Join-Path $script:RepoRoot "libssh2-$Ssh2Version"

    if (Test-Installed $prefix) { Write-Host ">>> 跳过 libssh2 $Ssh2Version / $mode：已安装"; return }
    Write-Host ">>> 编译 libssh2 $Ssh2Version / $mode (OpenSSL $opensslVersion)"
    if (Test-Path $buildDir) { Remove-Item -LiteralPath $buildDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

    $shared = if ($mode -eq "shared") { "ON" } else { "OFF" }
    $static = if ($mode -eq "shared") { "OFF" } else { "ON" }
    # 显式统一 CRT：静态库配 /MT，动态库配 /MD；否则 CMake 默认 /MD，与 OpenSSL nmake 的 /MT 混连导致 __imp_ CRT 符号无法解析。
    $runtime = if ($mode -eq "shared") { "MultiThreadedDLL" } else { "MultiThreaded" }
    $cmake = (Get-Command cmake).Source
    $generator = Resolve-VsGenerator
    & $cmake -S $srcDir -B $buildDir -G $generator -A x64 `
        "-DCMAKE_INSTALL_PREFIX=$prefix" `
        "-DBUILD_SHARED_LIBS=$shared" "-DBUILD_STATIC_LIBS=$static" `
        "-DBUILD_EXAMPLES=OFF" "-DBUILD_TESTING=OFF" `
        "-DCRYPTO_BACKEND=OpenSSL" `
        "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW" `
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=$runtime" `
        "-DOPENSSL_ROOT_DIR=$sslPrefix" `
        "-DOPENSSL_INCLUDE_DIR=$($sslPrefix)\include" `
        "-DOPENSSL_CRYPTO_LIBRARY=$(Get-Lib $sslPrefix libcrypto)" `
        "-DOPENSSL_SSL_LIBRARY=$(Get-Lib $sslPrefix libssl)"
    if ($LASTEXITCODE -ne 0) { throw "libssh2 cmake configure 失败" }
    & $cmake --build $buildDir --config Release
    if ($LASTEXITCODE -ne 0) { throw "libssh2 build 失败" }
    & $cmake --install $buildDir --config Release
    if ($LASTEXITCODE -ne 0) { throw "libssh2 install 失败" }
}

# 基于指定 OpenSSL + libssh2 编译 curl；1.1.1 老版本跳过（curl 8.23 要求 OpenSSL 3.0+）。
function Build-Curl([string]$opensslVersion, [string]$mode) {
    if (Test-LegacyOpenssl $opensslVersion) { Write-Host ">>> 跳过 curl（OpenSSL $opensslVersion）：curl 8.23 要求 3.0+"; return }

    $sslPrefix  = Get-OpensslPrefix $opensslVersion $mode
    $ssh2Prefix = Get-Ssh2Prefix $opensslVersion $mode
    $prefix     = Get-CurlPrefix $opensslVersion $mode
    $buildDir   = Join-Path $buildRoot "$platform\.build\curl-$CurlVersion-openssl-$opensslVersion-$mode"
    $srcDir     = Join-Path $script:RepoRoot "curl-$CurlVersion"

    if (Test-Installed $prefix) { Write-Host ">>> 跳过 curl $CurlVersion / $mode：已安装"; return }
    Write-Host ">>> 编译 curl $CurlVersion / $mode (OpenSSL $opensslVersion + libssh2)"
    if (Test-Path $buildDir) { Remove-Item -LiteralPath $buildDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

    $shared = if ($mode -eq "shared") { "ON" } else { "OFF" }
    $static = if ($mode -eq "shared") { "OFF" } else { "ON" }
    $runtime = if ($mode -eq "shared") { "MultiThreadedDLL" } else { "MultiThreaded" }
    $cmake = (Get-Command cmake).Source
    $generator = Resolve-VsGenerator
    # 显式关闭可选压缩后端（brotli/zstd/zlib），各平台产物口径一致，不携带额外系统依赖。
    & $cmake -S $srcDir -B $buildDir -G $generator -A x64 `
        "-DCMAKE_INSTALL_PREFIX=$prefix" `
        "-DBUILD_SHARED_LIBS=$shared" "-DBUILD_STATIC_LIBS=$static" `
        "-DBUILD_CURL_EXE=OFF" "-DCURL_ENABLE_SSL=ON" "-DCURL_USE_OPENSSL=ON" `
        "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW" `
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=$runtime" `
        "-DOPENSSL_ROOT_DIR=$sslPrefix" `
        "-DOPENSSL_INCLUDE_DIR=$($sslPrefix)\include" `
        "-DOPENSSL_CRYPTO_LIBRARY=$(Get-Lib $sslPrefix libcrypto)" `
        "-DOPENSSL_SSL_LIBRARY=$(Get-Lib $sslPrefix libssl)" `
        "-DCURL_USE_LIBSSH2=ON" `
        "-DLIBSSH2_INCLUDE_DIR=$($ssh2Prefix)\include" `
        "-DLIBSSH2_LIBRARY=$(Get-Ssh2Lib $ssh2Prefix $mode)" `
        "-DCURL_USE_LIBSSH=OFF" "-DCURL_USE_LIBPSL=OFF" "-DCURL_ZLIB=OFF" `
        "-DCURL_BROTLI=OFF" "-DCURL_ZSTD=OFF" "-DCURL_DISABLE_LDAP=ON"
    if ($LASTEXITCODE -ne 0) { throw "curl cmake configure 失败" }
    & $cmake --build $buildDir --config Release
    if ($LASTEXITCODE -ne 0) { throw "curl build 失败" }
    & $cmake --install $buildDir --config Release
    if ($LASTEXITCODE -ne 0) { throw "curl install 失败" }
}

Ensure-Submodules

New-Item -ItemType Directory -Force -Path $treeRoot | Out-Null
foreach ($v in $Versions) {
    foreach ($m in $Modes) {
        Build-Openssl $v $m
        Build-Ssh2 $v $m
        Build-Curl $v $m
    }
}
Write-Host "MSVC 构建完成，产物位于 $buildRoot\$platform"
