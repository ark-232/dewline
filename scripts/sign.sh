#!/bin/bash
# Signs Dewline.app inside out, packs it into a ULMO disk image, signs that, notarizes it and staples the ticket. Each
# stage runs only when its inputs exist and otherwise prints a line saying it was skipped, so with no Developer ID the
# result is an unsigned DMG. Signing never uses --deep. Fails when the DMG is over 20 MB.
#   SIGN_IDENTITY                            the Developer ID Application identity, in a keychain on the search list
#   ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID  an App Store Connect API key for notarytool
# Writes notarytool's JSON result beside the DMG as <name>.notarization.json.
# Usage: scripts/sign.sh <Dewline.app> <Dewline.dmg>
set -euo pipefail

app=${1:?usage: scripts/sign.sh <Dewline.app> <Dewline.dmg>}
dmg=${2:?usage: scripts/sign.sh <Dewline.app> <Dewline.dmg>}
identity=${SIGN_IDENTITY:-}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }

ditto "$app" "$work/Dewline.app"
app=$work/Dewline.app
if [[ -n $identity ]]; then
    sparkle=$app/Contents/Frameworks/Sparkle.framework
    sign "$sparkle/Versions/B/Autoupdate"
    sign "$sparkle/Versions/B/Updater.app"
    sign "$sparkle"
    for helper in "$app"/Contents/Helpers/*; do
        if [[ -e $helper ]]; then sign "$helper"; fi
    done
    sign "$app"
    codesign --verify --strict --deep -vv "$app"
else
    echo "sign.sh: skipped code signing: SIGN_IDENTITY is not set, so the app and the DMG stay unsigned"
fi

ln -s /Applications "$work/Applications"
rm -f "$dmg"
hdiutil create -quiet -format ULMO -volname Dewline -srcfolder "$work" "$dmg"

if [[ -z $identity ]]; then
    echo "sign.sh: skipped notarization and stapling: the DMG is unsigned"
elif [[ -z ${ASC_KEY_PATH:-} || -z ${ASC_KEY_ID:-} || -z ${ASC_ISSUER_ID:-} ]]; then
    codesign --force --timestamp --sign "$identity" "$dmg"
    echo "sign.sh: skipped notarization and stapling: ASC_KEY_PATH, ASC_KEY_ID or ASC_ISSUER_ID is not set"
else
    codesign --force --timestamp --sign "$identity" "$dmg"
    result=${dmg%.dmg}.notarization.json
    xcrun notarytool submit "$dmg" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
        --wait --output-format json > "$result"
    if [[ $(jq -r .status "$result") != Accepted ]]; then
        xcrun notarytool log "$(jq -r .id "$result")" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" >&2 || true
        echo "sign.sh: notarization ended $(jq -r .status "$result")" >&2
        exit 1
    fi
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl -a -t open --context context:primary-signature -vv "$dmg"
    echo "sign.sh: notarized and stapled, submission $(jq -r .id "$result")"
fi

bytes=$(stat -f %z "$dmg")
echo "sign.sh: $dmg is $bytes bytes ($(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1048576 }') MB)"
if ((bytes > 20 * 1048576)); then
    echo "sign.sh: the DMG is over the 20 MB budget" >&2
    exit 1
fi
