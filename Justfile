# Build commands for Clacal app

# Default recipe: build the app bundle
default: app

# Build Clacal.app bundle to ./build/
app:
    @mkdir -p build
    xcodebuild -project Clacal.xcodeproj -scheme Clacal -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData -quiet
    @for path in build/Clacal.app; do [ ! -e "$path" ] || trash "$path"; done
    @cp -R build/DerivedData/Build/Products/Debug/Clacal.app build/
    @test -x build/Clacal.app/Contents/MacOS/Clacal
    @test -x build/Clacal.app/Contents/MacOS/clacal-cli

# Build release app bundle
app-release:
    @mkdir -p build
    xcodebuild -project Clacal.xcodeproj -scheme Clacal -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData -quiet
    @for path in build/Clacal.app; do [ ! -e "$path" ] || trash "$path"; done
    @cp -R build/DerivedData/Build/Products/Release/Clacal.app build/
    @test -x build/Clacal.app/Contents/MacOS/Clacal
    @test -x build/Clacal.app/Contents/MacOS/clacal-cli

# Regenerate Xcode project from project.yml
gen:
    xcodegen generate

# Clean build artifacts
clean:
    @for path in build .build; do [ ! -e "$path" ] || trash "$path"; done
    xcodebuild -project Clacal.xcodeproj -scheme Clacal clean -quiet 2>/dev/null || true

# Run the app
run: app
    open build/Clacal.app

# Run tests
test:
    xcodebuild test -project Clacal.xcodeproj -scheme Clacal -destination 'platform=macOS,arch=arm64'

# Fast validation suite
validate-fast:
    mkdir -p .build/validation/fast
    CLACAL_VALIDATION_OUTPUT_DIR=.build/validation/fast swift test --filter ValidationFast

# Exhaustive validation sweep
validate-sweep:
    mkdir -p .build/validation/sweep
    CLACAL_VALIDATION_OUTPUT_DIR=.build/validation/sweep CLACAL_VALIDATION_STRICT=1 swift test --filter ValidationSweep

# Clear all data (legacy SQLite + active JSON store)
clear-db:
    @for path in \
        "$HOME/.config/clacal/history.db" \
        "$HOME/.config/clacal/history-v2.store" \
        "$HOME/.config/clacal/history-v2.store-shm" \
        "$HOME/.config/clacal/history-v2.store-wal" \
        "$HOME/.config/clacal/usage_data.json"; do \
        [ ! -e "$path" ] || trash "$path"; \
    done

# Print version from Info.plist
version:
    @/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist

# Create DMG from release build
dmg: app-release
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    DMG="build/Clacal_${VERSION}.dmg"
    if [ -e "$DMG" ]; then trash "$DMG"; fi
    hdiutil create "$DMG" -volname "Clacal" -srcfolder build/Clacal.app -ov -format UDZO
    echo "$DMG"

# Create GitHub release with DMG
release: dmg
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    DMG="build/Clacal_${VERSION}.dmg"
    SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
    gh release create "v${VERSION}" "$DMG" --title "Clacal v${VERSION}" --notes "See assets to download and install."
    echo ""
    echo "SHA256: ${SHA}"
    echo "Update homebrew-tap/Casks/clacal.rb with version \"${VERSION}\" and sha256 \"${SHA}\""
