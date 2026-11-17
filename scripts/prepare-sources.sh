#!/bin/bash
#
# 拉取源码：按 tag 浅克隆 OpenSSL（1.1.1w / 3.5.9）、libssh2 1.11.1 与 curl 8.23.0 到 checkouts/
# 已存在的目录会跳过，适合网络不稳定时反复重试（每次只拉单个 tag，失败不会拖垮整库）
#
# 用法：./prepare-sources.sh [--force]
#   MIRROR=1 时优先使用 githubfast 镜像
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# 依次尝试的下载源，某个源失败自动换下一个
getUrls() {
    local path="$1"
    if [[ "${MIRROR:-0}" == "1" ]]; then
        echo "https://githubfast.com/$path https://github.com/$path"
    else
        echo "https://github.com/$path https://githubfast.com/$path"
    fi
}

# 浅克隆单个 tag，失败自动换源
fetchTag() {
    local path="$1"
    local tag="$2"
    local dest="$3"

    if [[ -d "$dest" && $FORCE -eq 0 ]]; then
        logStep "跳过 $(basename "$dest")：已存在"
        return
    fi

    local url
    for url in $(getUrls "$path"); do
        logStep "克隆 $url ($tag)"
        rm -rf "$dest"
        if git clone --depth 1 --branch "$tag" "$url" "$dest"; then
            logInfo "完成: $dest"
            return
        fi
        logInfo "该源失败，尝试下一个"
    done
    die "所有下载源均失败: $path"
}

fetchTag "openssl/openssl" "OpenSSL_1_1_1w" "$OPENSSL_111W_DIR"
fetchTag "openssl/openssl" "openssl-3.5.9"   "$OPENSSL_350_DIR"
fetchTag "libssh2/libssh2" "libssh2-1.11.1"  "$LIBSSH2_DIR"
fetchTag "curl/curl"       "curl-8_23_0"    "$CURL_DIR"

logStep "源码准备完成"
