# Development

This document guides you through building, signing, shipping, and testing Clawdi.

## Building it

You need macOS 14+, Xcode with Swift 6, [xcodegen](https://github.com/yonaskolb/XcodeGen), and ideally [just](https://github.com/casey/just):

```sh
just dev       # build Debug, kill the running app, launch the fresh build
just install   # build Release and install to /Applications
just demo      # fire all one-shot reactions on the running app
just gen-assets
just ship      # Developer ID signed, notarized, stapled Clawdi.zip
```

Or by hand:

```sh
xcodegen generate
xcodebuild -project Clawdi.xcodeproj -scheme Clawdi -configuration Debug build
xcodebuild -project Clawdi.xcodeproj -scheme Clawdi -destination 'platform=macOS' test
```

### Code signing

macOS keys the Accessibility/Input Monitoring/Screen Recording grants to the bundle ID plus a stable code signature, so builds are signed with an `Apple Development` identity (team `VTLHGQC72S`, configured in `project.yml`) — otherwise you'd re-grant everything after every rebuild. Building needs a certificate for that team in your keychain (`security find-identity -v -p codesigning`); building under your own account is just a `DEVELOPMENT_TEAM` swap. Check a build with:

```sh
codesign --verify --deep --strict --verbose=2 DerivedData/Build/Products/Debug/Clawdi.app
```

### Shipping to other people

Dev-signed builds only run on registered machines. `just ship` makes the real thing — Developer ID signed, hardened runtime, notarized, stapled `Clawdi.zip` that opens on a normal double-click anywhere. Needs a paid-program `Developer ID Application` certificate and a one-time notary credential:

```sh
xcrun notarytool store-credentials clawdi-notary \
  --apple-id <you@example.com> --team-id VTLHGQC72S --password <app-specific-password>
```

(`just dist` is the signed build without notarization.) Both override signing on the command line only, so your dev identity and TCC grants stay put. Sanity check:

```sh
spctl --assess --type execute --verbose=2 DerivedData/Build/Products/Release/Clawdi.app
# accepted   source=Notarized Developer ID
```

### GitHub releases

Pushing a version tag creates a GitHub Release containing the signed, notarized, universal `Clawdi-macos-universal.zip`. The tag must match `CFBundleShortVersionString` in `Sources/Clawdi/App/Info.plist`, prefixed with `v`; for the current version:

```sh
git tag v0.1.37
git push origin v0.1.37
```

Before the first release, add these repository **Actions secrets** under **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | Base64-encoded Developer ID Application `.p12` certificate |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting that `.p12` |
| `APPLE_API_KEY_ID` | App Store Connect API key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect API issuer UUID |
| `APPLE_API_KEY` | Base64-encoded App Store Connect `.p8` private key |

Create the inputs once:

- **Developer ID certificate:** In **Keychain Access**, right-click the `Developer ID Application` identity that expands to a certificate **and** private key; choose **Export…**, save it as `.p12`, and set a password.
- **Notarization API key:** In **App Store Connect → Users and Access → Integrations → App Store Connect API**, create a key, note its Key ID and the page's Issuer ID, then download `AuthKey_<KEYID>.p8`. Apple permits that `.p8` download only once; create a replacement key if it was lost.

Place these files in `~/clawdi-signing/`:

```text
DeveloperID.p12
p12-password.txt
AuthKey_<KEYID>.p8
issuer-id.txt
```

`Tools/release/upload-secrets.sh` validates the certificate and private key, then streams all five values directly to GitHub without printing them, placing them in command arguments, or saving them in shell history:

```sh
Tools/release/upload-secrets.sh ~/clawdi-signing --dry-run
Tools/release/upload-secrets.sh ~/clawdi-signing
```

The workflow imports the certificate into a temporary keychain, builds a hardened-runtime universal app, notarizes and staples it, then deletes the temporary keychain and credentials.

## Kicking the tires

One pass over everything user-facing, after a fresh build:

- Pet's on the desktop, tracking the cursor; Size menu rescales crisply.
- Hands off for ~4 minutes: it curls up asleep. Move the mouse — wake-up stretch.
- Add/edit/delete a reminder; toggle the outside clock button.
- Start Pomodoro, pause/resume from the bubble, let a focus→break flip happen.
- Pattern editor: apply a preset, paint a spot, save a custom preset, import/export one.
- Share cat: the crop overlay follows the pet; save or cancel a recording.
- `just demo all` for the agent reactions.
- Quit, relaunch: settings and position survived.
- **Pet → Launch at login** off/on shows up in System Settings → Login Items.

