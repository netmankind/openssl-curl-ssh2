# openssl-curl-ssh2

## 项目简介

本项目是一套**从源码编译** OpenSSL、libssh2、curl 三库的跨平台脚本集合，面向需要在自己的
Qt / C++ 工程里内嵌 HTTPS 与 SFTP/SCP 网络能力的场景。脚本在一台开发机上按统一流程产出各
目标平台的预编译库；每个平台、每种链接方式都出 **static（静态）** 与 **shared（动态）** 两套
标准 prefix（`include/` + `lib/`）。

- **目标平台**：Android arm64-v8a / armeabi-v7a、Windows MinGW64（Qt 5.15 / Qt 6.8）、Windows MSVC x64（VS2022）、Ubuntu 22.04 x64。
- **宿主环境**：Windows（Git Bash / PowerShell）或 Ubuntu 22.04。
- **版本固定**：OpenSSL `1.1.1w`（供 Qt 5.15 老工程）/ `3.5.9` LTS、libssh2 `1.11.1`、curl `8.23.0`。
- **构建方式**：out-of-tree 影子构建，源码目录保持干净；重复执行自动跳过已装好的版本/模式。
- **依赖收敛**：curl 显式关闭 brotli/zstd/zlib 等可选压缩后端，静态产物不额外链接系统压缩库。
- **部署选择**：静态产物适合 Qt 单文件部署（无需随附第三方库）；动态产物体积更小，可按需更新。

本项目最初 fork 自 [robertying/openssl-curl-android](https://github.com/robertying/openssl-curl-android)，
现已改为按平台、按库分阶段的可复用构建脚本，源码以子模块放在根目录，产物放在 `build/`，源码目录保持干净（out-of-tree）。

## 依赖顺序

每个平台、每种模式都严格按 **OpenSSL → libssh2 → curl** 的顺序构建：

- `libssh2` 用 OpenSSL 做加密后端（`CRYPTO_BACKEND=OpenSSL`）；
- `curl` 用 OpenSSL 做 TLS、用 libssh2 做 SFTP/SCP（`CURL_USE_LIBSSH2=ON`）。

版本固定为 OpenSSL `1.1.1w` / `3.5.9`、libssh2 `1.11.1`、curl `8.23.0`。

> **两个硬约束**
> 1. curl 8.23 源码要求 OpenSSL 3.0+，所以 **1.1.1w 只产出 OpenSSL 库**，不参与 libssh2/curl 构建（1.1.1w 是给 Qt 5.15 老工程用的）。
> 2. Android 上用 NDK `r22.1.7171670`（Qt 5.15 与 Qt 6.8 都能兼容），API 级别默认 23。

## 上游源码与版本

三库源码以 **git 子模块**登记在仓库根目录，目录名带版本号；主仓库只记录各子模块指向的
commit，不随主仓库分发源码文件。各编译脚本启动时会自动校验并拉取缺失/不完整的子模块；
也可手动初始化：

```bash
bash scripts/prepare-sources.sh
# 等价于 git submodule update --init --recursive
```

| 子模块目录 | 库 | 版本 | 上游仓库 | tag |
|---|---|---|---|---|
| `openssl-1.1.1w/` | OpenSSL | 1.1.1w | https://github.com/openssl/openssl | `OpenSSL_1_1_1w` |
| `openssl-3.5.9/` | OpenSSL | 3.5.9 | https://github.com/openssl/openssl | `openssl-3.5.9` |
| `libssh2-1.11.1/` | libssh2 | 1.11.1 | https://github.com/libssh2/libssh2 | `libssh2-1.11.1` |
| `curl-8.23.0/` | curl | 8.23.0 | https://github.com/curl/curl | `curl-8_23_0` |

> 子模块钉的是 tag 对应的 commit；`prepare-sources.sh` 会跳过已存在的源码目录，可反复重试。

## 目录结构

```
openssl-1.1.1w/             子模块：OpenSSL 1.1.1w（gitlink，commit 由主仓库记录）
openssl-3.5.9/              子模块：OpenSSL 3.5.9
libssh2-1.11.1/             子模块：libssh2 1.11.1
curl-8.23.0/                子模块：curl 8.23.0
build/<平台>/               产物 prefix（include/lib）与 `.build/` out-of-tree 中间目录
build/trees/                MSVC 构建用的源码工作副本（git 忽略，重编时再生成）
scripts/
  common.sh                 路径、版本、产物布局、通用工具函数
  prepare-sources.sh        子模块初始化兜底入口（编译脚本已自动执行，可手动跑）
  lib/android.sh            Android 公共构建逻辑（被入口脚本 source）
  lib/mingw.sh              MinGW 公共构建逻辑
  build-android-arm64-v8a.sh        入口，内部按 openssl -> ssh2 -> curl
  build-android-armeabi-v7a.sh
  build-mingw-qt5.sh / build-mingw-qt6.sh
  build-ubuntu.sh
  build-msvc.ps1
  build-<平台>-openssl.sh / -ssh2.sh / -curl.sh   分步包装，只跑单个阶段
old_scripts/                上游原始脚本存档（autotools 路线），仅作参考，新流程不调用
```

## 快速开始

`.sh` 脚本用 bash 语法：推荐打开 **Git Bash**，`cd` 到仓库根目录后执行；在 PowerShell 里则显式调用 `bash`。

各编译脚本启动时会自动校验源码子模块：已拉取且完整的跳过，缺失/不完整的才按 `.gitmodules` 拉取，无需单独准备源码。直接构建某平台即可，例如 Android arm64-v8a：

```bash
bash scripts/build-android-arm64-v8a.sh
```

> 想提前把源码拉下来，可手动跑 `bash scripts/prepare-sources.sh`（等价于 `git submodule update --init --recursive`）。

PowerShell 下等价写法（`<仓库根目录>` 换成本机实际路径；Git 的 `bin` 已在 PATH 时可直接用 `bash`）：

```powershell
bash -lc "cd <仓库根目录> && bash scripts/build-android-arm64-v8a.sh"
```

## 各平台用法

### Android（arm64-v8a / armeabi-v7a）

```bash
./scripts/build-android-arm64-v8a-openssl.sh   # 第 1 步：OpenSSL
./scripts/build-android-arm64-v8a-ssh2.sh      # 第 2 步：libssh2（基于 OpenSSL 3.5.9）
./scripts/build-android-arm64-v8a-curl.sh      # 第 3 步：curl

./scripts/build-android-arm64-v8a.sh           # 一把梭，按顺序跑完三步
```

### Windows MinGW（Qt 5.15 / Qt 6.8）

```bash
./scripts/build-mingw-qt5.sh        # mingw810_64 工具链
./scripts/build-mingw-qt6.sh        # mingw1310_64 工具链
# 同样可用 -openssl.sh / -ssh2.sh / -curl.sh 分步跑
```

### Windows MSVC x64

```powershell
.\scripts\build-msvc.ps1                              # 全部版本、静态+动态
.\scripts\build-msvc.ps1 -Versions 3.5.9 -Modes static
```

脚本会自动用 `vswhere` 找 VS2022 的 `vcvars64.bat`，也可用 `-VsInstall` 指定。
OpenSSL 的 nmake 构建只能在源码目录内进行，所以每个版本/模式会复制一份独立副本到 `build/trees/`，不污染子模块源码目录。

### Ubuntu 22.04

```bash
sudo apt install -y build-essential perl cmake
bash scripts/build-ubuntu.sh
```

## 参数与环境变量

| 变量 | 作用 | 默认 |
|---|---|---|
| `OPENSSL_VERSIONS` | 参与编译的 OpenSSL 版本，空格分隔 | `1.1.1w 3.5.9` |
| `MODES` | `static shared` 两套都出，也可只写一个 | `static shared` |
| `JOBS` | 并行任务数 | 自动（MinGW 固定 4） |
| `NDK` | 覆盖 Android NDK 根目录 | `r22.1.7171670` |
| `API_LEVEL` | Android API 级别 | `23` |
| `MINGW_BIN` | MinGW 工具链 bin 目录 | 按 qt5/qt6 脚本各不相同 |

分步脚本还支持 `--versions 3.5.9` 只编某版 OpenSSL。

## 产物布局

```
build/<平台>/openssl-<版本>-<static|shared>/
build/<平台>/ssh2-1.11.1-openssl-<版本>-<static|shared>/
build/<平台>/curl-8.23.0-openssl-<版本>-<static|shared>/
```

`<平台>` 取 `android-arm64-v8a`、`android-armeabi-v7a`、`mingw64-qt5`、`mingw64-qt6`、`msvc-x64`、`ubuntu22.04-x64`。
每个产物目录都是标准 prefix，含 `include/`、`lib/`（Android/MinGW 另有 `lib/cmake`、`lib/pkgconfig`）。
重复执行会自动跳过已安装的版本/模式，中间文件在 `<平台>/.build/` 下。

## 说明

- 静态优先：Qt 单文件部署时用 `-static` 产物即可，无需额外 DLL。
- 动态模式会同时产出 import lib（MinGW 的 `.dll.a` / MSVC 的 `.lib`），脚本按实际文件挑库，不写死后缀。
- curl 显式关闭可选压缩后端：`CURL_ZLIB=OFF`、`CURL_BROTLI=OFF`、`CURL_ZSTD=OFF`，静态产物不额外链接系统 zlib/brotli/zstd；同时关闭 LIBSSH、LIBPSL 与 LDAP。各平台口径一致，产物不携带额外系统压缩库依赖。
- Android 在 Windows 上宿主构建时，OpenSSL 用等价的 `linux-aarch64` / `linux-armv4` 目标配合 NDK clang（官方 `android-arm64` 目标在 Windows 上会因路径匹配失败）。
- 用 HTTPS 时 Android 端需要显式设置 CA：

  ```c
  curl_easy_setopt(curl, CURLOPT_CAINFO, CA_BUNDLE_PATH);
  ```

## CI（GitHub Actions）

`.github/workflows/` 下共有七条 workflow，全部为**纯手动触发**（仅 `workflow_dispatch`，不随 push / PR 自动运行）；推送到 GitHub 后在仓库 **Actions** 标签页选中对应条目点 "Run workflow" 即可：

| workflow | 触发 | 作用 |
|---|---|---|
| `ci.yml` | 手动 | 校验 bash 脚本语法与子模块完整性，不做编译，跑得快 |
| `build-ubuntu.yml` | 手动 | 在 Ubuntu 22.04 runner 上编译三库，产物打包为 Actions 构件下载 |
| `build-msvc.yml` | 手动 | 在 Windows Server 2022 runner（VS2022）上编译 MSVC x64 产物 |
| `build-android-arm64-v8a.yml` | 手动 | Ubuntu 宿主下载 NDK 后交叉编译 Android arm64-v8a |
| `build-android-armeabi-v7a.yml` | 手动 | Ubuntu 宿主下载 NDK 后交叉编译 Android armeabi-v7a |
| `build-mingw-qt5.yml` | 手动（占位） | 绑定本机 Qt 5.15 套件 MinGW 8.1，云端 runner 无对应工具链，仅在本机编译 |
| `build-mingw-qt6.yml` | 手动（占位） | 绑定本机 Qt 6.8 套件 MinGW 13.1，云端 runner 无对应工具链，仅在本机编译 |

> - 除两条 MinGW 占位外，其余五条均在 GitHub 托管 runner 上真实编译；MinGW 两条保留 workflow 结构，编译步骤以注释形式留档，需要时可在本机或改造为 msys2 通用工具链后放开。
> - GitHub Actions 仅在 GitHub 仓库运行；GitCode 镜像不执行这些 workflow。

## License

沿用上游的 MIT License，见 `LICENSE`。
