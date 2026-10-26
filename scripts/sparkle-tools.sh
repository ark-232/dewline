#!/bin/bash
# Downloads Sparkle's command-line tools (generate_appcast, sign_update) at the version app/project.yml pins and checks
# the tarball against its SHA-256. A Sparkle bump changes the version and the SHA-256 here and the exactVersion in
# app/project.yml together.
# Usage: scripts/sparkle-tools.sh <folder>; the tools land in <folder>/bin.
set -euo pipefail

version=2.10.0
sha256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: scripts/sparkle-tools.sh <folder>}

grep -qx "    exactVersion: $version" "$root/app/project.yml" \
    || { echo "sparkle-tools.sh: app/project.yml does not pin Sparkle $version" >&2; exit 1; }
mkdir -p "$out"
curl -fsSL -A "dewline-build (https://github.com/ark-232/dewline)" -o "$out/Sparkle-$version.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz"
echo "$sha256  $out/Sparkle-$version.tar.xz" | shasum -a 256 -c - > /dev/null
tar -xf "$out/Sparkle-$version.tar.xz" -C "$out"
rm "$out/Sparkle-$version.tar.xz"
