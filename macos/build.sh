#!/bin/sh
set -eu
cd "$(dirname "$0")"
python3 ../scripts/prepare-sparkle.py
APP="build/CoolSync.app"
FRAMEWORK="Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
xcrun swiftc -module-cache-path build/ModuleCache -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" Sources/*.swift Sources/VendorQRCode/*.swift -o "$APP/Contents/MacOS/CoolSync" -F "$FRAMEWORK" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -framework AppKit -framework CoreBluetooth -framework CryptoKit -framework Security
ditto "$FRAMEWORK/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
if [ -f AppIcon.icns ]; then cp AppIcon.icns "$APP/Contents/Resources/"; fi
install -m 644 Sources/VendorQRCode/LICENSE "$APP/Contents/Resources/QRCode-LICENSE.txt"
install -m 644 Vendor/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE.txt"
cp Info.plist "$APP/Contents/Info.plist"
if [ -n "${COOLSYNC_BUILD:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $COOLSYNC_BUILD" "$APP/Contents/Info.plist"; fi
# Preserve Sparkle's embedded signatures; sign only the enclosing personal app.
codesign --force --sign "${COOLSYNC_SIGN_IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Created: $APP"
