#!/usr/bin/env bash
# ==============================================================================
# build_stockfish_ios.sh
# Cross-compile Stockfish cho arm64 iOS và xuất ra $(PROJECT_DIR)/stockfish-arm64
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STOCKFISH_TAG="${STOCKFISH_TAG:-sf_17}"
BUILD_DIR="${PROJECT_DIR}/build_stockfish_tmp"
OUTPUT_BIN="${PROJECT_DIR}/stockfish-arm64"

echo "=== [1/5] Kiểm tra môi trường macOS & Xcode ==="
IPHONEOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
if [[ -z "${IPHONEOS_SDK}" || ! -d "${IPHONEOS_SDK}" ]]; then
    echo "❌ Không tìm thấy iPhoneOS SDK từ xcrun. Cần cài đặt Xcode đầy đủ."
    exit 1
fi
echo "  iPhoneOS SDK: ${IPHONEOS_SDK}"

echo "=== [2/5] Clone Stockfish (${STOCKFISH_TAG}) ==="
mkdir -p "${BUILD_DIR}"
if [[ ! -d "${BUILD_DIR}/Stockfish/.git" ]]; then
    git clone --depth 1 --branch "${STOCKFISH_TAG}" https://github.com/official-stockfish/Stockfish.git "${BUILD_DIR}/Stockfish"
else
    echo "  Đã có repo Stockfish trong cache"
fi

cd "${BUILD_DIR}/Stockfish/src"

echo "=== [3/5] Cross-compiling Stockfish cho iOS arm64 ==="
make clean || true

CXX_COMPILER="$(xcrun --sdk iphoneos --find clang++)"
TARGET_FLAGS="-target arm64-apple-ios15.0 -isysroot ${IPHONEOS_SDK} -miphoneos-version-min=15.0"

make -j$(sysctl -n hw.ncpu || echo 4) \
    build \
    ARCH=arm64-modern \
    COMP=clang \
    CXX="${CXX_COMPILER}" \
    CXXFLAGS="${TARGET_FLAGS} -O3 -fno-exceptions -DNDEBUG" \
    LDFLAGS="${TARGET_FLAGS}"

echo "=== [4/5] Kiểm tra binary và Sign ==="
if [[ ! -f stockfish ]]; then
    echo "❌ Build thất bại: không tìm thấy binary stockfish"
    exit 1
fi

file stockfish

# FIX OFFLINE: ad-hoc codesign thường bị AMFI kill khi spawn từ tmp trên máy jailbreak.
# Ưu tiên ldid -S (chuẩn jailbreak), fallback codesign -s -.
if command -v ldid >/dev/null 2>&1; then
    echo "  Signing với ldid -S ..."
    ldid -S stockfish
elif command -v codesign >/dev/null 2>&1; then
    echo "  ldid không có — fallback codesign -s - (có thể bị kill 9 khi spawn, nên cài ldid) ..."
    codesign -s - --force --timestamp=none stockfish || true
else
    echo "⚠️  Không có ldid/codesign — binary chưa được sign, rất dễ bị kill khi spawn."
fi
chmod 0755 stockfish

# Fail sớm thay vì để runtime timeout 10s mới biết binary lỗi.
SIZE="$(stat -f %z stockfish 2>/dev/null || stat -c %s stockfish)"
if [[ "${SIZE}" -lt 500000 ]]; then
    echo "❌ Binary quá nhỏ (${SIZE} bytes) — có thể build lỗi / bị strip sai."
    exit 1
fi
# Kiểm tra Mach-O arm64 (CF FA ED FE).
xxd -l 4 -p stockfish | grep -q "cffaedfe" || {
    echo "❌ Binary không bắt đầu bằng MH_MAGIC_64 — LoadStockfishFromEmbeddedSection sẽ bỏ qua nó."
    exit 1
}

echo "=== [5/5] Copy output -> ${OUTPUT_BIN} ==="
cp -f stockfish "${OUTPUT_BIN}"
chmod 0755 "${OUTPUT_BIN}"

echo "✅ Thành công! Binary đã sẵn sàng tại: ${OUTPUT_BIN}"
file "${OUTPUT_BIN}"
ls -lh "${OUTPUT_BIN}"