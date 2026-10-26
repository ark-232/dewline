#!/bin/bash
# Writes THIRD_PARTY_NOTICES.md from what ships in Dewline.app: the Rust crates the app and the CLI link (normal
# dependencies in core/Cargo.lock, without build scripts' or proc macros' own trees), the Swift packages pinned in
# Package.resolved, and the bundled fonts. Run it after any dependency change; release builds bundle its output.
# Usage: scripts/notices.sh [Swift package checkouts, default: the release build's DerivedData]
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
checkouts=${1:-$HOME/Library/Caches/dev.arkwerx.dewline/DerivedData-build-release/SourcePackages/checkouts}
cargo metadata --manifest-path "$root/core/Cargo.toml" --format-version 1 --locked --filter-platform aarch64-apple-darwin \
    > "${TMPDIR:-/tmp}/dewline-metadata.json"
python3 -I - "$root" "$checkouts" "${TMPDIR:-/tmp}/dewline-metadata.json" > "$root/THIRD_PARTY_NOTICES.md" <<'PY'
import json, pathlib, re, sys

root, checkouts, metadata = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), json.load(open(sys.argv[3]))
packages = {p["id"]: p for p in metadata["packages"]}
nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}
members = set(metadata["workspace_members"])
shipped = [i for i in members if packages[i]["name"] in ("dewline-ffi", "dewline-cli")]

def proc_macro(package):
    return any("proc-macro" in t["kind"] for t in package["targets"])

seen, stack = set(), list(shipped)
while stack:
    for dep in nodes[stack.pop()]["deps"]:
        if any(k["kind"] is None for k in dep["dep_kinds"]) and dep["pkg"] not in seen and not proc_macro(packages[dep["pkg"]]):
            seen.add(dep["pkg"])
            stack.append(dep["pkg"])
crates = sorted((packages[i] for i in seen - members), key=lambda p: (p["name"], p["version"]))

def license_files(folder):
    return [f for f in sorted(folder.iterdir()) if re.match(r"(?i)^(licen[cs]e|copying|notice|unlicense)", f.name) and f.is_file()]

# Crates whose packages carry no license file: the upstream repository's license text.
upstream = {"https://github.com/erweixin/RaTeX": root / "docs/licenses/RaTeX-LICENSE",
            "https://github.com/mozilla/uniffi-rs": root / "docs/licenses/MPL-2.0.txt"}
rows, texts = [], {}
def add(name, version, license, source, files):
    rows.append((name, version, license, source))
    for f in files:
        texts.setdefault(f.read_text(errors="replace").strip(), []).append(f"{name} {version} ({f.name})")
    if not files:
        texts.setdefault(f"No license file ships in the package; its manifest declares {license}.", []).append(f"{name} {version}")

for p in crates:
    folder = pathlib.Path(p["manifest_path"]).parent
    license = "MIT AND OFL-1.1" if p["name"] == "ratex-katex-fonts" else (p["license"] or "see the license file")
    source = p.get("repository") or f"https://crates.io/crates/{p['name']}"
    files = license_files(folder) or [f for f in [upstream.get(source)] if f]
    if p["name"] == "ratex-katex-fonts":
        files.append(folder / "fonts/OFL.txt")
    add(p["name"], p["version"], license, source, files)

resolved = json.load(open(root / "app/Dewline.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
for pin in resolved["pins"]:
    folder = checkouts / pathlib.Path(pin["location"]).name
    version = pin["state"].get("version") or pin["state"]["revision"][:12]
    if not folder.is_dir():
        sys.exit(f"notices.sh: no checkout at {folder}; run scripts/build-release.sh first")
    if pin["identity"] == "swiftmath":
        fonts = folder / "Sources/SwiftMath/mathFonts.bundle"
        add("SwiftMath", version, "MIT", pin["location"], license_files(folder))
        add("SwiftMath math fonts (Latin Modern, TeX Gyre Termes, XITS, KpMath and others)", version,
            "GUST Font License, OFL-1.1", pin["location"], license_files(fonts) + [fonts / "GUST-FONT-LICENSE.txt", fonts / "OFL.txt"])
    else:
        add(folder.name, version, "MIT and the notices in its LICENSE", pin["location"], license_files(folder))
add("JetBrains Mono", "2.304", "OFL-1.1", "https://github.com/JetBrains/JetBrainsMono", [root / "app/Dewline/Fonts/JetBrainsMono-OFL.txt"])

uniffi = sorted({f"{p['name']} {p['version']}" for p in crates if p["name"].startswith("uniffi")})
print("# Third-party notices\n")
print("Dewline.app contains the software below. `scripts/notices.sh` writes this file from `core/Cargo.lock`,")
print("`Package.resolved` and the bundled fonts; edit the script, not this file.\n")
print("## MPL-2.0: UniFFI\n")
print(f"The UniFFI runtime ({', '.join(uniffi)}) is under the Mozilla Public License 2.0 and ships in the app")
print("unmodified. Its source is at https://github.com/mozilla/uniffi-rs and on crates.io under the versions named here.\n")
print("## Components\n")
print("| Component | Version | License | Source |\n|---|---|---|---|")
for name, version, license, source in rows:
    print(f"| {name} | {version} | {license} | {source} |")
print("\n## License texts\n")
for text, users in texts.items():
    print(f"### {', '.join(users)}\n")
    print("```text")
    print(text.replace("```", "'''"))
    print("```\n")
PY
echo "notices.sh: wrote THIRD_PARTY_NOTICES.md ($(grep -c '^| ' "$root/THIRD_PARTY_NOTICES.md") table rows)"
