#!/bin/bash
# Signs Dewline.app inside out, notarizes and staples it, packs it into a ULMO disk image, then signs, notarizes and
# staples that, so the app inside passes Gatekeeper offline and syspolicy_check distribution. Each
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
entitlements=$(mktemp -d)
trap 'rm -rf "$work" "$entitlements"' EXIT

sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }
notarize() { # file result.json
    xcrun notarytool submit "$1" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
        --wait --output-format json > "$2"
    if [[ $(jq -r .status "$2") != Accepted ]]; then
        xcrun notarytool log "$(jq -r .id "$2")" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" >&2 || true
        echo "sign.sh: notarization of $1 ended $(jq -r .status "$2")" >&2
        exit 1
    fi
}
notary=0
if [[ -n $identity && -n ${ASC_KEY_PATH:-} && -n ${ASC_KEY_ID:-} && -n ${ASC_ISSUER_ID:-} ]]; then notary=1; fi

ditto "$app" "$work/Dewline.app"
app=$work/Dewline.app
if [[ -n $identity ]]; then
    sparkle=$app/Contents/Frameworks/Sparkle.framework
    sign "$sparkle/Versions/B/Autoupdate"
    sign "$sparkle/Versions/B/Updater.app"
    sign "$sparkle"
    sign "$app/Contents/Frameworks/DewlineFFI.framework"
    for helper in "$app"/Contents/Helpers/*; do
        if [[ -e $helper ]]; then sign "$helper"; fi
    done
    # The archive is unsigned, so the entitlements are written here: the app group the Quick Look preview reads the
    # app's stylesheet from, and the preview's sandbox.
    group=$(plutil -extract DewlineAppGroup raw "$app/Contents/Info.plist")
    plutil -create xml1 "$entitlements/app.plist"
    plutil -insert 'com\.apple\.security\.application-groups' -json "[\"$group\"]" "$entitlements/app.plist"
    cp "$entitlements/app.plist" "$entitlements/preview.plist"
    plutil -insert 'com\.apple\.security\.app-sandbox' -bool YES "$entitlements/preview.plist"
    sign --entitlements "$entitlements/preview.plist" "$app/Contents/PlugIns/DewlinePreview.appex"
    sign --entitlements "$entitlements/app.plist" "$app"
    codesign --verify --strict --deep -vv "$app"
    if ((notary)); then
        ditto -c -k --keepParent "$app" "$entitlements/Dewline.zip"
        notarize "$entitlements/Dewline.zip" "$entitlements/app-notarization.json"
        xcrun stapler staple "$app"
        rm "$entitlements/Dewline.zip"
    fi
else
    echo "sign.sh: skipped code signing: SIGN_IDENTITY is not set, so the app and the DMG stay unsigned"
fi

ln -s /Applications "$work/Applications"
rm -f "$dmg"
hdiutil create -quiet -format ULMO -volname Dewline -srcfolder "$work" "$dmg"

if [[ -z $identity ]]; then
    echo "sign.sh: skipped notarization and stapling: the DMG is unsigned"
elif ((!notary)); then
    codesign --force --timestamp --sign "$identity" "$dmg"
    echo "sign.sh: skipped notarization and stapling: ASC_KEY_PATH, ASC_KEY_ID or ASC_ISSUER_ID is not set"
else
    codesign --force --timestamp --sign "$identity" "$dmg"
    result=${dmg%.dmg}.notarization.json
    notarize "$dmg" "$result"
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
