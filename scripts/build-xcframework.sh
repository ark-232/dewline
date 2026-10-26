#!/usr/bin/env bash
# Builds Packages/MdCore/DewlineFFI.xcframework and the Swift bindings for it.
# Usage: scripts/build-xcframework.sh [--universal]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
package="$root/Packages/MdCore"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/Library/Caches/dev.arkwerx.dewline/target}"

case "${1:-}" in
  "") targets=("$(rustc --print host-tuple)") ;;
  --universal) targets=(aarch64-apple-darwin x86_64-apple-darwin) ;;
  *) echo "usage: $0 [--universal]" >&2; exit 64 ;;
esac

cd "$root/core"
libs=()
for target in "${targets[@]}"; do
  cargo build --release --locked -p dewline-ffi --lib --target "$target"
  libs+=("$CARGO_TARGET_DIR/$target/release/libdewline_ffi.a")
done

work="$CARGO_TARGET_DIR/xcframework"
rm -rf "$work"
mkdir -p "$work/headers"
lipo -create "${libs[@]}" -output "$work/libdewline_ffi.a"

cargo run --locked -p dewline-ffi --features bindgen --bin uniffi-bindgen -- \
  generate --library "$CARGO_TARGET_DIR/${targets[0]}/release/libdewline_ffi.dylib" \
  --language swift --out-dir "$work/swift"
mv "$work/swift/dewline_ffiFFI.h" "$work/headers/"
mv "$work/swift/dewline_ffiFFI.modulemap" "$work/headers/module.modulemap"

rm -rf "$package/DewlineFFI.xcframework" "$package/Sources/DewlineFFIBindings"
xcodebuild -create-xcframework -library "$work/libdewline_ffi.a" -headers "$work/headers" \
  -output "$package/DewlineFFI.xcframework"
mkdir -p "$package/Sources/DewlineFFIBindings"
cp "$work/swift/dewline_ffi.swift" "$package/Sources/DewlineFFIBindings/"
