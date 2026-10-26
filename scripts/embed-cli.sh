#!/bin/bash
# Xcode build phase (app/project.yml): builds the dewline command from core/crates/cli for each architecture in ARCHS
# and puts one binary at Dewline.app/Contents/Helpers/dewline, signed with the app's identity when Xcode signs.
# Every configuration but Debug uses cargo's release profile. MACOSX_DEPLOYMENT_TARGET comes from Xcode, so the
# command needs the same macOS as the app.
set -euo pipefail

# Xcode opened from the Dock has launchd's PATH, which holds neither rustup's nor Homebrew's cargo.
export PATH="$PATH:$HOME/.cargo/bin:/opt/homebrew/bin"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/Library/Caches/dev.arkwerx.dewline/target}"

if [[ $CONFIGURATION == Debug ]]; then
    set --
    profile=debug
else
    set -- --release
    profile=release
fi

# rustup takes the toolchain from core/rust-toolchain.toml when cargo runs there.
cd "$SRCROOT/../core"
binaries=()
for arch in $ARCHS; do
    case $arch in
        arm64) target=aarch64-apple-darwin ;;
        x86_64) target=x86_64-apple-darwin ;;
        *) echo "error: embed-cli.sh: no Rust target for $arch" >&2; exit 1 ;;
    esac
    cargo build --locked "$@" -p dewline-cli --target "$target"
    binaries+=("$CARGO_TARGET_DIR/$target/$profile/dewline")
done

helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$helpers"
lipo -create "${binaries[@]}" -output "$helpers/dewline"
if [[ ${CODE_SIGNING_ALLOWED:-NO} == YES && -n ${EXPANDED_CODE_SIGN_IDENTITY:-} ]]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime "$helpers/dewline"
fi
