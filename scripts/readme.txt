common.sh                      # 路径/版本/产物布局/工具函数/模式开关
prepare-sources.sh             # 一次性拉源码（OpenSSL 1.1.1w·3.5.9、libssh2 1.11.1、curl 8.23.0）
lib/android.sh                 # Android 公共构建逻辑
lib/mingw.sh                   # MinGW 公共构建逻辑
build-android-arm64-v8a.sh     # 入口（薄），下同
build-android-armeabi-v7a.sh
build-mingw-qt5.sh  build-mingw-qt6.sh
build-ubuntu.sh
build-msvc.ps1
readme.txt


# OpenSSL / libssh2 / curl 跨平台编译脚本

依赖顺序（每个平台、每个模式都一致）：**OpenSSL -> libssh2 -> curl**。
curl 8.23 硬要求 OpenSSL 3.0+，因此 **1.1.1w 只出 OpenSSL 库**；libssh2 与 curl 都基于 3.5.9。

## 目录与文件

- `prepare-sources.sh`：一次性拉源码（OpenSSL 1.1.1w / 3.5.9、libssh2 1.11.1、curl 8.23.0），首次没源码时先跑。
- `common.sh`：公共配置（路径、版本、产物布局、工具函数），由各脚本自动 source，不用单独跑。
- `lib/android.sh` / `lib/mingw.sh`：Android / MinGW 的公共构建逻辑，被对应入口脚本 source。
- `build-<平台>.sh`：某平台一把梭，内部自动按 openssl -> ssh2 -> curl 顺序。
- `build-<平台>-openssl.sh` / `-ssh2.sh` / `-curl.sh`：分步包装，只跑对应阶段。

## 首次准备

```bash
bash scripts/prepare-sources.sh
```

## 分步用法（先 openssl，再 ssh2，最后 curl）

### Android arm64-v8a
```bash
./scripts/build-android-arm64-v8a-openssl.sh
./scripts/build-android-arm64-v8a-ssh2.sh
./scripts/build-android-arm64-v8a-curl.sh
```

### Android armeabi-v7a
```bash
./scripts/build-android-armeabi-v7a-openssl.sh
./scripts/build-android-armeabi-v7a-ssh2.sh
./scripts/build-android-armeabi-v7a-curl.sh
```

### Windows MinGW（Qt5.15 / Qt6.8）
```bash
./scripts/build-mingw-qt5-openssl.sh
./scripts/build-mingw-qt5-ssh2.sh
./scripts/build-mingw-qt5-curl.sh

./scripts/build-mingw-qt6-openssl.sh
./scripts/build-mingw-qt6-ssh2.sh
./scripts/build-mingw-qt6-curl.sh
```

### Windows MSVC x64（PowerShell，内部自带顺序）
```powershell
.\scripts\build-msvc.ps1
```

### Ubuntu 22.04（bash，内部自带顺序）
```bash
bash scripts/build-ubuntu.sh
```

## 常用环境变量 / 参数

- `MODES="static shared"`：产物模式，默认两套都出；`MODES=static` 只出静态库，`MODES=shared` 只出动态库。
- `--versions 3.5.9`：只编某一个 OpenSSL 版本。
- `NDK=<NDK 根目录>`：覆盖 Android NDK 路径（默认 22.1.7171670，API 23）。
- `MINGW_BIN=<工具链 bin 目录>`：覆盖 MinGW 编译器路径。
- `JOBS=<并发数>`：覆盖并行任务数。

## 产物布局

```
build/<平台>/openssl-<版本>-<static|shared>/
build/<平台>/ssh2-1.11.1-openssl-<版本>-<static|shared>/
build/<平台>/curl-8.23.0-openssl-<版本>-<static|shared>/
```

已安装过的产物（include + lib 都在）会自动跳过；中间文件在 `<平台>/.build/` 下，源码目录保持干净（out-of-tree）。
