# Releases

`release.yml` builds, signs, notarizes and publishes Dewline when the owner pushes a signed tag: `v1.4.0` releases, `rehearse/v1.4.0` runs everything through the approval and publishes nothing. `pull.yml` takes a release back on every channel when the owner pushes `pull/v1.4.0`. The full design is the updates spec (`~/.claude/plans/dewline/research/updates.md`); this page holds the commands.

## Local builds

```sh
scripts/build-release.sh                 # universal unsigned Dewline.app in ~/Library/Caches/dev.arkwerx.dewline/release
scripts/sign.sh <Dewline.app> <out.dmg>  # signs, makes the ULMO DMG, notarizes and staples when the inputs exist
scripts/notices.sh                       # rewrites THIRD_PARTY_NOTICES.md after a dependency change
scripts/release-dry.sh <Dewline.app> <dir>  # ci.yml's release-dry: ad hoc signed DMG, a feed signed with a key made for the run
scripts/verify-feed.sh <appcast.xml or URL> <public key> [SHA-256]  # checks a signed feed with only the public key
scripts/sparkle-tools.sh <dir>           # Sparkle's generate_appcast and sign_update at the pinned version and SHA-256
scripts/perf.sh                          # measures this Mac; writes perf/<version>.json with each budget's result
```

`sign.sh` reads `SIGN_IDENTITY` (`Developer ID Application: ArkWerx LLC (7W6LLR2DK7)`) and `ASC_KEY_PATH`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, and prints a skip line for each stage whose inputs are missing. Releases are built only in CI.

A release PR sets the version in `core/Cargo.toml`, adds the version's section to `CHANGELOG.md` (`## 1.4.0 (2 Nov 2026)`, or `## 1.4.1 (critical)` for a critical update), and commits `perf/1.4.0.json` from `scripts/perf.sh` on the owner's Mac. `verify` refuses a `v*` tag whose perf file is missing or misses a budget in `perf/budgets.jq` (`scripts/perf-gate.sh`). For a `rehearse/v*` tag the gate is advisory (owner decision D26): verify still judges the file and lists each missed budget in the job summary and as a warning, so signing and notarization can be rehearsed before the budgets hold. The section becomes the appcast notes, the release body and the app's What's New.

## Owner setup

Run these in a terminal on this Mac. Keep every exported key in a new folder under `~` (never `~/Development`, `~/Documents` or `~/Personal`, which sync to Google Drive), and delete it once the secret is set. `gh secret set` without `--body` prompts for the value, so nothing lands in shell history. The environments must exist first:

```fish
for env in release-approval release feed-signing updates tap site; gh api -X PUT repos/ark-232/dewline/environments/$env; end
```

`pull.yml` deploys to `release-approval`, `feed-signing`, `updates` and `site` from `pull/v*` tags and to a `tap-revert` environment that holds the tap App's credentials with no wait timer. Create `tap-revert`, then allow `pull/v*` tags on all five:

```fish
echo '{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}' | gh api -X PUT repos/ark-232/dewline/environments/tap-revert --input -
for env in release-approval feed-signing updates site tap-revert; gh api -X POST repos/ark-232/dewline/environments/$env/deployment-branch-policies -f name='pull/v*' -f type=tag; end
```

**Developer ID certificate.** Confirm it comes from the G2 intermediate, then export it with a new password and store it:

```sh
security find-certificate -c "Developer ID Application: ArkWerx LLC" -p | openssl x509 -noout -issuer
umask 077; mkdir ~/dewline-keys
# Keychain Access > login > My Certificates > "Developer ID Application: ArkWerx LLC (7W6LLR2DK7)"
#   > File > Export Items... > ~/dewline-keys/developer-id.p12, with a new password
base64 -i ~/dewline-keys/developer-id.p12 | gh secret set DEVELOPER_ID_P12 --env release -R ark-232/dewline
gh secret set DEVELOPER_ID_P12_PASSWORD --env release -R ark-232/dewline
rm ~/dewline-keys/developer-id.p12
```

**App Store Connect API key** (`AuthKey_39V9MTV26C.p8`; notarization needs a Team key with the App Manager role). The issuer ID is on App Store Connect > Users and Access > Integrations:

```sh
gh secret set ASC_KEY_P8 --env release -R ark-232/dewline < /path/to/AuthKey_39V9MTV26C.p8
gh secret set ASC_KEY_ID --env release -R ark-232/dewline --body 39V9MTV26C
gh secret set ASC_ISSUER_ID --env release -R ark-232/dewline
xcrun notarytool history --key /path/to/AuthKey_39V9MTV26C.p8 --key-id 39V9MTV26C --issuer <issuer ID>
```

**Sparkle EdDSA key.** `generate_keys` keeps the private key in the login keychain and prints the public key:

```sh
umask 077; mkdir -p ~/dewline-keys; ~/Development/dewline/scripts/sparkle-tools.sh ~/dewline-keys; cd ~/dewline-keys
./bin/generate_keys
./bin/generate_keys -x ed25519.key
gh secret set SPARKLE_ED_PRIVATE_KEY --env feed-signing -R ark-232/dewline < ed25519.key
```

Put the printed public key in `SPARKLE_PUBLIC_ED_KEY` in `app/project.yml` and in `SUPublicEDKey` in `app/updater.golden.json`, in one PR. Until then the updater refuses to start and `release.yml` stops at `build`.

Copy `ed25519.key` onto two encrypted offline volumes kept in different places (`hdiutil create -size 10m -fs APFS -encryption AES-256 -volname dewline-key <volume>/dewline-key.dmg` prompts for the password). A backup counts once it signs a file that the keychain key verifies:

```sh
./bin/sign_update --ed-key-file /Volumes/dewline-key/ed25519.key scratch.txt   # prints sparkle:edSignature="<sig>"
./bin/sign_update --verify scratch.txt <sig>
```

Then `rm ed25519.key`. Losing this key may strand every install, because each build trusts only feeds it signs.

**GitHub Apps for the feed and the tap.** The spec replaces the tap PAT with one-repo GitHub Apps, whose tokens last an hour. In Settings > Developer settings > GitHub Apps, create two Apps with no webhook: `dewline-feed` (Contents read and write) installed only on `ark-232/dewline-updates`, and `dewline-tap` (Contents and Pull requests read and write) installed only on `ark-232/homebrew-tap`. Generate a private key for each, then:

```sh
gh secret set FEED_APP_ID --env updates -R ark-232/dewline --body <dewline-feed App ID>
gh secret set FEED_APP_PRIVATE_KEY --env updates -R ark-232/dewline < ~/dewline-keys/dewline-feed.private-key.pem
gh secret set TAP_APP_ID --env tap -R ark-232/dewline --body <dewline-tap App ID>
gh secret set TAP_APP_PRIVATE_KEY --env tap -R ark-232/dewline < ~/dewline-keys/dewline-tap.private-key.pem
gh secret set TAP_APP_ID --env tap-revert -R ark-232/dewline --body <dewline-tap App ID>
gh secret set TAP_APP_PRIVATE_KEY --env tap-revert -R ark-232/dewline < ~/dewline-keys/dewline-tap.private-key.pem
rm ~/dewline-keys/*.pem
```

**The feed repo.** `ark-232/dewline-updates` is public (`verify` and `feed-sign` read it without a token) and starts with a signed feed that has no items. In a checkout of it, write this `appcast.xml`, sign it with the keychain key (`~/dewline-keys/bin/sign_update appcast.xml`), and check it with `scripts/verify-feed.sh appcast.xml <public key>` before the first push:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Dewline</title>
    </channel>
</rss>
```

The app reads the feed from the site, `https://dewline.arkwerx.com/appcast.xml` (SUFeedURL), so a beta's items reach beta readers before any stable release exists. The release and pull `site` jobs copy the signed feed into `site/appcast.xml` on every channel, deploy, then check the live feed with `scripts/verify-feed.sh`. A deploy from a checkout without that file takes the feed down, so deploy the site only from those jobs. dewline-updates keeps the signed history each new feed is generated from. The site deploys to the Cloudflare Worker `dewline-site` (dewline.arkwerx.com) with `wrangler deploy`, using the `site` environment's `CLOUDFLARE_API_TOKEN` secret, a token that can deploy that Worker and nothing else.

**The tap.** `ark-232/homebrew-tap` holds `Casks/dewline.rb` (spec section 3.6) with exactly one `version` and one `sha256` line, and CI that runs `brew style` and `brew audit --cask`.

**Signed tags.** `verify` checks each tag against `.github/release-allowed-signers` (one line: `ark-232 namespaces="git" <your SSH public key>`). Tag with `git tag -s v1.4.0 -m "Dewline 1.4.0"` after `git config gpg.format ssh` and `git config user.signingkey ~/.ssh/<key>.pub`. A pull's message is its reason, one line, which `pulled.txt` records: `git tag -s pull/v1.4.0 -m "Loses the last line on save"`.
