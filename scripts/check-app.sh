#!/bin/bash
# Checks a built Dewline.app before it ships: every Mach-O has arm64 and x86_64 slices built for macOS 26.0 or lower,
# Sparkle.framework holds no XPC services, and the Sparkle keys in Info.plist equal app/updater.golden.json exactly.
# Usage: scripts/check-app.sh <Dewline.app>
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
app=${1:?usage: scripts/check-app.sh <Dewline.app>}
status=0
fail() { echo "check-app.sh: $*" >&2; status=1; }

machos=0
while IFS= read -r -d '' file; do
    [[ $(file -b "$file") == *Mach-O* ]] || continue
    machos=$((machos + 1))
    name=${file#"$app/"}
    archs=$(lipo -archs "$file")
    [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || fail "$name has slices '$archs', not arm64 and x86_64"
    for arch in $archs; do
        minos=$(vtool -arch "$arch" -show-build "$file" | awk '$1 == "minos" || $1 == "version" { print $2; exit }')
        [[ -n $minos && $(printf '%s\n26.0\n' "$minos" | sort -V | tail -1) == 26.0 ]] \
            || fail "$name ($arch) is built for macOS '${minos:-unknown}', above 26.0"
    done
done < <(find "$app" -type f -print0)
((machos > 0)) || fail "no Mach-O files in $app"

if [[ -n $(find "$app/Contents/Frameworks/Sparkle.framework" -name XPCServices) ]]; then
    fail "Sparkle.framework still holds XPCServices"
fi

if ! diff <(jq -S . "$root/app/updater.golden.json") \
    <(plutil -convert json -o - "$app/Contents/Info.plist" | jq -S 'with_entries(select(.key | startswith("SU")))'); then
    fail "the Sparkle keys in Info.plist differ from app/updater.golden.json (above: golden <, built >)"
fi

((status == 0)) && echo "check-app.sh: $machos Mach-O files are arm64 and x86_64 for macOS 26.0 or lower; no XPC services; Info.plist matches the golden file"
exit "$status"
