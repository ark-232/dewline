#!/usr/bin/env bash
# Builds Packages/MdCore/DewlineFFI.xcframework and the Swift bindings for it. The engine is a dynamic framework, so
# the app and its Quick Look preview share one copy from Dewline.app/Contents/Frameworks.
# Usage: scripts/build-xcframework.sh [--universal]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
package="$root/Packages/MdCore"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/Library/Caches/dev.arkwerx.dewline/target}"
# The app's deployment target, which C code in dependencies (BLAKE3's) otherwise takes from the build Mac.
export MACOSX_DEPLOYMENT_TARGET=26.0

case "${1:-}" in
  "") targets=("$(rustc --print host-tuple)") ;;
  --universal) targets=(aarch64-apple-darwin x86_64-apple-darwin) ;;
  *) echo "usage: $0 [--universal]" >&2; exit 64 ;;
esac

cd "$root/core"
libs=()
for target in "${targets[@]}"; do
  cargo build --release --locked -p dewline-ffi --lib --target "$target"
  libs+=("$CARGO_TARGET_DIR/$target/release/libdewline_ffi.dylib")
done

work="$CARGO_TARGET_DIR/xcframework"
framework="$work/DewlineFFI.framework"
rm -rf "$work"
mkdir -p "$framework/Versions/A/Headers" "$framework/Versions/A/Modules" "$framework/Versions/A/Resources"
lipo -create "${libs[@]}" -output "$framework/Versions/A/DewlineFFI"
install_name_tool -id @rpath/DewlineFFI.framework/Versions/A/DewlineFFI "$framework/Versions/A/DewlineFFI"

cargo run --locked -p dewline-ffi --features bindgen --bin uniffi-bindgen -- \
  generate --library "${libs[0]}" --language swift --out-dir "$work/swift"
mv "$work/swift/DewlineFFI.h" "$framework/Versions/A/Headers/"
sed 's/^module /framework module /' "$work/swift/DewlineFFI.modulemap" > "$framework/Versions/A/Modules/module.modulemap"
version=$(cargo pkgid -p dewline-ffi | sed 's/.*@//')
cat > "$framework/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DewlineFFI</string>
  <key>CFBundleIdentifier</key><string>dev.arkwerx.dewline.ffi</string>
  <key>CFBundleName</key><string>DewlineFFI</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
</dict>
</plist>
EOF
ln -s A "$framework/Versions/Current"
for link in DewlineFFI Headers Modules Resources; do ln -s "Versions/Current/$link" "$framework/$link"; done

rm -rf "$package/DewlineFFI.xcframework" "$package/Sources/DewlineFFIBindings"
xcodebuild -create-xcframework -framework "$framework" -output "$package/DewlineFFI.xcframework"
mkdir -p "$package/Sources/DewlineFFIBindings"
cp "$work/swift/dewline_ffi.swift" "$package/Sources/DewlineFFIBindings/"
