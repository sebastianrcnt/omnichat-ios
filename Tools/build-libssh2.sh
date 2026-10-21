#!/bin/bash
# Builds Vendor/CLibSSH2.xcframework: libssh2 with OpenSSL's libcrypto, static, for iOS (arm64), the iOS simulator
# (arm64) and macOS (arm64). Each slice is one static library (libssh2 + libcrypto merged) with the libssh2 headers
# and a module map, so Swift imports it as `CLibSSH2`.
#
# Pinned sources, checked against the SHA-256 below. Needs Xcode, cmake and perl.
#   Tools/build-libssh2.sh            # downloads into Tools/.build-libssh2 (ignored), builds, replaces the xcframework
set -euo pipefail

LIBSSH2_VERSION=1.11.1
LIBSSH2_SHA256=d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7
OPENSSL_VERSION=3.5.9 # LTS
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
IOS_MIN=17.0
MACOS_MIN=14.0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/Tools/.build-libssh2"
OUT="$ROOT/Vendor/CLibSSH2.xcframework"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p "$WORK/src"

fetch() { # url sha256 file
    local file="$WORK/src/$3"
    [ -f "$file" ] || curl -fL --retry 3 -o "$file" "$1"
    echo "$2  $file" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: $3" >&2; rm -f "$file"; exit 1; }
}
fetch "https://libssh2.org/download/libssh2-$LIBSSH2_VERSION.tar.gz" "$LIBSSH2_SHA256" "libssh2-$LIBSSH2_VERSION.tar.gz"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
    "$OPENSSL_SHA256" "openssl-$OPENSSL_VERSION.tar.gz"

# slice: name, OpenSSL target, SDK, clang min-version flag, cmake system name
build_slice() {
    local name=$1 target=$2 sdk=$3 minflag=$4 system=$5
    local dir="$WORK/$name" prefix="$WORK/$name/prefix"
    rm -rf "$dir" && mkdir -p "$dir" "$prefix"
    local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

    tar -xzf "$WORK/src/openssl-$OPENSSL_VERSION.tar.gz" -C "$dir"
    (cd "$dir/openssl-$OPENSSL_VERSION" &&
        CC="$(xcrun --sdk "$sdk" -f clang)" CFLAGS="-isysroot $sysroot $minflag -Os" \
        ./Configure "$target" no-shared no-tests no-apps no-docs no-ui-console no-engine no-dso no-async \
            no-comp no-ssl3 no-tls no-dtls no-sock no-srp no-psk no-legacy no-module \
            --prefix="$prefix" --libdir=lib >/dev/null &&
        make -j"$JOBS" build_libs >/dev/null && make install_dev >/dev/null)

    tar -xzf "$WORK/src/libssh2-$LIBSSH2_VERSION.tar.gz" -C "$dir"
    cmake -S "$dir/libssh2-$LIBSSH2_VERSION" -B "$dir/libssh2-build" -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_SYSTEM_NAME="$system" -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_C_FLAGS="$minflag" -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCRYPTO_BACKEND=OpenSSL -DOPENSSL_ROOT_DIR="$prefix" -DOPENSSL_USE_STATIC_LIBS=ON \
        -DOPENSSL_INCLUDE_DIR="$prefix/include" -DOPENSSL_CRYPTO_LIBRARY="$prefix/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="$prefix/lib/libssl.a" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
        -DENABLE_ZLIB_COMPRESSION=OFF -DLIBSSH2_BUILD_DOCS=OFF >/dev/null
    cmake --build "$dir/libssh2-build" -j"$JOBS" >/dev/null
    cmake --install "$dir/libssh2-build" >/dev/null

    mkdir -p "$dir/lib" "$dir/include"
    libtool -static -no_warning_for_no_symbols -o "$dir/lib/libCLibSSH2.a" "$prefix/lib/libssh2.a" "$prefix/lib/libcrypto.a"
    strip -S "$dir/lib/libCLibSSH2.a" 2>/dev/null
    cp "$prefix/include/libssh2.h" "$prefix/include/libssh2_sftp.h" "$prefix/include/libssh2_publickey.h" "$dir/include/"
    cat > "$dir/include/module.modulemap" <<'EOF'
module CLibSSH2 {
    header "libssh2.h"
    header "libssh2_sftp.h"
    export *
}
EOF
}

build_slice ios-arm64 ios64-xcrun iphoneos "-mios-version-min=$IOS_MIN" iOS
build_slice ios-arm64-simulator iossimulator-arm64-xcrun iphonesimulator "-mios-simulator-version-min=$IOS_MIN" iOS
build_slice macos-arm64 darwin64-arm64-cc macosx "-mmacosx-version-min=$MACOS_MIN" Darwin

rm -rf "$OUT" && mkdir -p "$ROOT/Vendor"
xcodebuild -create-xcframework \
    -library "$WORK/ios-arm64/lib/libCLibSSH2.a" -headers "$WORK/ios-arm64/include" \
    -library "$WORK/ios-arm64-simulator/lib/libCLibSSH2.a" -headers "$WORK/ios-arm64-simulator/include" \
    -library "$WORK/macos-arm64/lib/libCLibSSH2.a" -headers "$WORK/macos-arm64/include" \
    -output "$OUT" >/dev/null
cp "$WORK/ios-arm64/libssh2-$LIBSSH2_VERSION/COPYING" "$ROOT/Vendor/LICENSE-libssh2.txt"
cp "$WORK/ios-arm64/openssl-$OPENSSL_VERSION/LICENSE.txt" "$ROOT/Vendor/LICENSE-OpenSSL.txt"
echo "libssh2 $LIBSSH2_VERSION + OpenSSL $OPENSSL_VERSION" > "$ROOT/Vendor/CLibSSH2.VERSION"
du -sh "$OUT"/*/libCLibSSH2.a
