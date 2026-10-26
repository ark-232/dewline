#!/bin/bash
# Builds the universal Release app the way release.yml does, with no secrets: the Rust library for arm64 and x86_64,
# then Dewline.app from the pinned Swift packages only, with the version from core/Cargo.toml and the build number
# from the commit count, Sparkle's XPC services removed, and scripts/check-app.sh run on the result. Prints the app's
# path. Signing and the disk image are scripts/sign.sh.
# Needs rustc with both macOS targets (rustup reads them from core/rust-toolchain.toml).
# Usage: scripts/build-release.sh [output folder, default ~/Library/Caches/dev.arkwerx.dewline/release]
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
caches=$HOME/Library/Caches/dev.arkwerx.dewline
out=${1:-$caches/release}
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$caches/target-release}
export MACOSX_DEPLOYMENT_TARGET=26.0
derived=$caches/DerivedData-build-release

for target in aarch64-apple-darwin x86_64-apple-darwin; do
    [[ -d $(rustc --print sysroot)/lib/rustlib/$target/lib ]] \
        || { echo "build-release.sh: $(rustc -V) has no $target standard library; use rustup's toolchain" >&2; exit 1; }
done

version=$(awk -F'"' '/^\[workspace.package\]/ { section = 1; next } /^\[/ { section = 0 } section && $1 ~ /^version *= */ { print $2; exit }' "$root/core/Cargo.toml")
build=$(git -C "$root" rev-list --count HEAD)
[[ -n $version && $build -gt 1 ]] || { echo "build-release.sh: no workspace version, or a shallow clone (build $build)" >&2; exit 1; }

"$root/scripts/build-xcframework.sh" --universal
xcodegen generate --spec "$root/app/project.yml" --quiet
rm -rf "$out"
mkdir -p "$out"
xcodebuild archive -project "$root/app/Dewline.xcodeproj" -scheme Dewline -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" -archivePath "$out/Dewline.xcarchive" \
    -disableAutomaticPackageResolution -packageAuthorizationProvider netrc \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="${version%%-*}" CURRENT_PROJECT_VERSION="$build" -quiet

app=$out/Dewline.app
ditto "$out/Dewline.xcarchive/Products/Applications/Dewline.app" "$app"
# The app is not sandboxed, so Sparkle runs in process; its XPC services only widen the attack surface.
rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
"$root/scripts/check-app.sh" "$app" >&2
if [[ -z $(plutil -extract SUPublicEDKey raw "$app/Contents/Info.plist") ]]; then
    echo "build-release.sh: SUPublicEDKey is empty, so this build's updater refuses to start (docs/release.md)" >&2
fi
echo "$app"
