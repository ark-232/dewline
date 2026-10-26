#!/bin/bash
# Verifies a signed appcast the way Dewline's updater reads it, with only the public key. The EdDSA signature that
# generate_appcast and sign_update append must cover every byte before the last "<!-- sparkle-signatures:" block, the
# range Sparkle 2.10.0 verifies (SPUExtractAppcastContent), and its length line must match. Then, in the signed bytes:
#   - every enclosure is https, the DMG of its own tag's GitHub release (never "latest"), with an EdDSA signature;
#   - sparkle:version is an integer that falls strictly down the feed, and shortVersionString never rises, so no build
#     is offered over a newer-numbered one; every minimumUpdateVersion names an item in the feed;
#   - every item's minimumSystemVersion is 26.0.0;
#   - an item carries sparkle:channel beta exactly when its tag has a prerelease suffix, and no other channel.
# With a SHA-256, the feed must also be that exact file: the live check that the host serves what was deployed.
# Needs OpenSSL 3 or later and python3.
# Usage: scripts/verify-feed.sh <appcast.xml or https URL> <base64 EdDSA public key> [<SHA-256>]
set -euo pipefail

usage="usage: scripts/verify-feed.sh <appcast.xml or https URL> <base64 EdDSA public key> [<SHA-256>]"
feed=${1:?$usage}
key=${2:?$usage}
expected=${3:-}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "verify-feed.sh: $*" >&2; exit 1; }

[[ $(openssl version) == "OpenSSL "[3-9]* ]] || fail "needs OpenSSL 3 or later for Ed25519; $(command -v openssl) is $(openssl version)"
if [[ $feed == https://* ]]; then
    curl -fsSL --proto =https -A "dewline-build (https://github.com/ark-232/dewline)" -o "$work/feed" "$feed" \
        || fail "cannot fetch $feed"
elif [[ -f $feed ]]; then
    cp "$feed" "$work/feed"
else
    fail "$feed is neither a file nor an https URL"
fi
if [[ -n $expected ]]; then
    actual=$(openssl dgst -sha256 -r "$work/feed" | cut -d' ' -f1)
    [[ $actual == "$expected" ]] || fail "$feed has SHA-256 $actual, not $expected"
fi

python3 -I - "$work" "$key" "$feed" <<'EOF'
import base64, binascii, re, subprocess, sys, xml.etree.ElementTree as ET

work, key, name = sys.argv[1:]
def fail(message):
    sys.exit(f"verify-feed.sh: {name}: {message}")

def decode(text, size, what):
    try:
        value = base64.b64decode(text, validate=True)
    except binascii.Error:
        value = b""
    if len(value) != size:
        fail(f"{what} is not {size} bytes of base64")
    return value

data = open(f"{work}/feed", "rb").read()
prefix = b"<!-- sparkle-signatures:\n"
start = data.rfind(prefix)
if start < 0:
    fail("has no sparkle-signatures block, so a signed-feed build rejects it")
end = data.find(b"-->", start + len(prefix))
if end < 0 or data[end + 3:].strip():
    fail("the sparkle-signatures block is unterminated or is not the end of the file")
content = data[:start]
fields = dict(line.split(":", 1) for line in data[start + len(prefix):end].decode(errors="replace").splitlines() if ":" in line)
signature = decode(fields.get("edSignature", "").strip(), 64, "the edSignature")
if fields.get("length", "").strip() != str(len(content)):
    fail(f"the signed length is {fields.get('length', '').strip()!r}, the content is {len(content)} bytes")
open(f"{work}/content", "wb").write(content)
open(f"{work}/signature", "wb").write(signature)
# The 32-byte Ed25519 key in an X.509 SubjectPublicKeyInfo, which OpenSSL reads as DER.
open(f"{work}/key.der", "wb").write(bytes.fromhex("302a300506032b6570032100") + decode(key, 32, "the public key"))
verified = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", f"{work}/key.der",
                           "-rawin", "-in", f"{work}/content", "-sigfile", f"{work}/signature"], capture_output=True)
if verified.returncode != 0:
    fail("the EdDSA signature does not verify with the public key")

S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
def numbers(version, what):
    if not re.fullmatch(r"\d+(\.\d+)*", version or ""):
        fail(f"{what} is {version!r}, not dotted numbers")
    parts = [int(p) for p in version.split(".")]
    return parts + [0] * (3 - len(parts))

channel = ET.fromstring(content).find("channel")
if channel is None:
    fail("has no channel element")
items, builds = [], set()
for item in channel.findall("item"):
    build = item.findtext(S + "version") or ""
    if not re.fullmatch(r"[0-9]+", build):
        fail(f"an item has sparkle:version {build!r}, not an integer build number")
    short = item.findtext(S + "shortVersionString")
    what = f"build {build}"
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        fail(f"{what} has {len(enclosures)} enclosures")
    url = enclosures[0].get("url", "")
    pinned = re.fullmatch(r"https://github\.com/[^/]+/dewline/releases/download/v([^/]+)/Dewline-\1\.dmg", url)
    if not pinned:
        fail(f"{what}'s enclosure {url!r} is not the https DMG of its own release")
    tag = pinned.group(1)
    base, _, prerelease = tag.partition("-")
    if numbers(base, f"{what}'s tag") != numbers(short, f"{what}'s shortVersionString"):
        fail(f"{what}'s tag v{tag} does not match its shortVersionString {short}")
    decode(enclosures[0].get(S + "edSignature", ""), 64, f"{what}'s enclosure edSignature")
    if not re.fullmatch(r"[0-9]+", enclosures[0].get("length", "")):
        fail(f"{what}'s enclosure has no byte length")
    minimum = item.findtext(S + "minimumSystemVersion")
    if numbers(minimum, f"{what}'s minimumSystemVersion") != [26, 0, 0]:
        fail(f"{what} has minimumSystemVersion {minimum}, not 26.0.0")
    channels = [c.text for c in item.findall(S + "channel")]
    if channels != (["beta"] if prerelease else []):
        fail(f"{what} (v{tag}) has channels {channels}; a prerelease tag is beta, any other tag has none")
    items.append((int(build), numbers(short, what), tag, item.findtext(S + "minimumUpdateVersion")))
    builds.add(build)

for (build, short, tag, _), (older, older_short, older_tag, _) in zip(items, items[1:]):
    if build <= older:
        fail(f"build {build} (v{tag}) is above build {older} (v{older_tag}) in the feed; builds must fall")
    if short < older_short:
        fail(f"v{tag} (build {build}) has a lower version than v{older_tag} (build {older})")
for build, _, tag, minimum in items:
    if minimum is not None and minimum not in builds:
        fail(f"v{tag} needs build {minimum} first (minimumUpdateVersion), which is not in the feed")

newest = f", newest v{items[0][2]} (build {items[0][0]})" if items else ""
print(f"verify-feed.sh: {name} is signed by the key and holds {len(items)} items{newest}")
EOF
