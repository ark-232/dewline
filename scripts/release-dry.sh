#!/bin/bash
# The release path's packaging and feed signing with no secrets, as ci.yml's release-dry job runs it after
# scripts/build-release.sh: a copy of the app carrying a key made for this run, signed inside out ad hoc by
# scripts/sign.sh into its DMG (which also holds the 20 MB budget), an empty feed signed with sign_update the way
# dewline-updates starts, then generate_appcast with release.yml's flags. scripts/verify-feed.sh checks both feeds
# against the run's public key.
# Needs OpenSSL 3 or later.
# Usage: scripts/release-dry.sh <Dewline.app> <work folder>
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
app=${1:?usage: scripts/release-dry.sh <Dewline.app> <work folder>}
work=${2:?usage: scripts/release-dry.sh <Dewline.app> <work folder>}
version=$(awk -F'"' '/^\[workspace.package\]/ { s = 1; next } /^\[/ { s = 0 } s && $1 ~ /^version *= */ { print $2; exit }' "$root/core/Cargo.toml")
archives=$work/archives
mkdir -p "$archives"

"$root/scripts/sparkle-tools.sh" "$work/sparkle"
openssl genpkey -algorithm ed25519 -outform DER -out "$work/run.der"
tail -c 32 "$work/run.der" | base64 > "$work/run.key"
public=$(openssl pkey -inform DER -in "$work/run.der" -pubout -outform DER | tail -c 32 | base64)

# generate_appcast signs an archive only when the app inside carries the signing key's public half, and refuses an
# app whose code signature does not seal its resources, as the linker's ad hoc one does not.
ditto "$app" "$work/Dewline.app"
plutil -replace SUPublicEDKey -string "$public" "$work/Dewline.app/Contents/Info.plist"
SIGN_IDENTITY=- "$root/scripts/sign.sh" "$work/Dewline.app" "$archives/Dewline-$version.dmg"

cat > "$archives/appcast.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Dewline</title>
    </channel>
</rss>
EOF
"$work/sparkle/bin/sign_update" --ed-key-file "$work/run.key" "$archives/appcast.xml"
"$root/scripts/verify-feed.sh" "$archives/appcast.xml" "$public"

awk -v v="$version" '$1 == "##" { if (on) exit; on = ($2 == v) } on' "$root/CHANGELOG.md" | tail -n +2 > "$archives/Dewline-$version.md"
"$work/sparkle/bin/generate_appcast" --ed-key-file "$work/run.key" \
    --download-url-prefix "https://github.com/ark-232/dewline/releases/download/v$version/" \
    --full-release-notes-url https://dewline.dev/changelog --embed-release-notes \
    --maximum-deltas 0 --maximum-versions 26 --phased-rollout-interval 43200 "$archives"
"$root/scripts/verify-feed.sh" "$archives/appcast.xml" "$public"
