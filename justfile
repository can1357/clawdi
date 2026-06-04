project := "Clawdi.xcodeproj"
scheme := "Clawdi"
app := "Clawdi"
derived := "DerivedData"
team := "VTLHGQC72S"
dist_identity := "Developer ID Application"
notary_profile := "clawdi-notary"

# List available recipes
default:
    @just --list

# Build (Debug|Release), kill the running app, and launch the fresh build
dev config="Debug":
    xcodegen generate
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{config}} -derivedDataPath {{derived}} build
    -killall {{app}} || true
    open {{derived}}/Build/Products/{{config}}/{{app}}.app

# Fire a pet reaction on the running dev build for testing (complete|ask|plan|knead|all)
demo name="all":
    "{{derived}}/Build/Products/Debug/{{app}}.app/Contents/MacOS/{{app}}" --clawdi-demo {{name}}

# Regenerate derived pose assets (sleep-curl) and the flower skin from the cat rig
gen-assets:
    python3 Tools/gen-sleep-pose/gen-sleep-pose.py
    python3 Tools/gen-flower-skin/gen-flower-skin.py

# Build Release and install it to /Applications
install:
    xcodegen generate
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Release -derivedDataPath {{derived}} build
    -killall {{app}} || true
    rm -rf /Applications/{{app}}.app
    cp -R {{derived}}/Build/Products/Release/{{app}}.app /Applications/{{app}}.app
    open /Applications/{{app}}.app

# Build a Developer ID-signed, hardened-runtime Release for distribution (does not touch dev signing)
dist:
    xcodegen generate
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Release -derivedDataPath {{derived}} \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="{{dist_identity}}" \
      DEVELOPMENT_TEAM={{team}} \
      ENABLE_HARDENED_RUNTIME=YES \
      CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
      OTHER_CODE_SIGN_FLAGS="--timestamp" \
      build
    codesign --verify --deep --strict --verbose=2 {{derived}}/Build/Products/Release/{{app}}.app

# Notarize + staple the dist build and emit {{app}}.zip to send (needs `notarytool store-credentials {{notary_profile}}`)
ship: dist
    rm -f {{app}}.zip
    ditto -c -k --keepParent {{derived}}/Build/Products/Release/{{app}}.app {{app}}.zip
    xcrun notarytool submit {{app}}.zip --keychain-profile {{notary_profile}} --wait
    xcrun stapler staple {{derived}}/Build/Products/Release/{{app}}.app
    rm -f {{app}}.zip
    ditto -c -k --keepParent {{derived}}/Build/Products/Release/{{app}}.app {{app}}.zip
    spctl --assess --type execute --verbose=2 {{derived}}/Build/Products/Release/{{app}}.app
    @echo "Ready -> {{app}}.zip (notarized + stapled). Send this file."
